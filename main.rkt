#lang racket

(require racket/match
         json
         "version.rkt"
         "core/regex-engine.rkt"
         "core/regex-parser.rkt"
         "core/ast.rkt"
         "core/i18n.rkt"
         "core/tester.rkt"
         "core/linter.rkt"
         "core/cookbook.rkt"
         "output/report.rkt"
         "core/updater.rkt"
         "output/json-format.rkt"
         "output/highlight.rkt"
         "output/human-format.rkt"
         "output/railroad.rkt"
         "server/mcp.rkt")

;; RegexMate CLI.
;; Exit codes: 0 ok · 1 invalid regex · 2 usage error · 3 valid pattern,
;; zero matches / zero replacements.

(define EXIT-OK 0)
(define EXIT-INVALID 1)
(define EXIT-USAGE 2)
(define EXIT-NO-MATCH 3)

;; ---- flag parsing -------------------------------------------------

;; flags may appear anywhere; positional args are returned in order.
;; --help / --version are surfaced as pseudo-positionals for the main loop.
(define (parse-args args)
  (let loop ([as args] [pos '()] [json-flag #f] [lang-flag #f] [output-file #f] [cases-file #f] [bad-flag #f])
    (cond
      [(null? as)
       (values (reverse pos) json-flag lang-flag output-file cases-file bad-flag)]
      [(string=? (car as) "--json")
       (loop (cdr as) pos #t lang-flag output-file cases-file bad-flag)]
      [(or (string=? (car as) "--help") (string=? (car as) "-h"))
       (loop (cdr as) (cons "--help" pos) json-flag lang-flag output-file cases-file bad-flag)]
      [(string=? (car as) "--version")
       (loop (cdr as) (cons "--version" pos) json-flag lang-flag output-file cases-file bad-flag)]
      [(string=? (car as) "--strict")
       ;; advisory flag for lint; travels via positionals to the command layer
       (loop (cdr as) (cons "--strict" pos) json-flag lang-flag output-file cases-file bad-flag)]
      [(string=? (car as) "--check")
       ;; check-only flag for update; travels via positionals
       (loop (cdr as) (cons "--check" pos) json-flag lang-flag output-file cases-file bad-flag)]
      [(string=? (car as) "--lang")
       (if (or (null? (cdr as)) (string-prefix? (cadr as) "--"))
           (loop '() pos json-flag lang-flag output-file cases-file "--lang")
           (loop (cddr as) pos json-flag (cadr as) output-file cases-file bad-flag))]
      [(string=? (car as) "-o")
       (if (or (null? (cdr as)) (string-prefix? (cadr as) "--"))
           (loop '() pos json-flag lang-flag output-file cases-file "-o")
           (loop (cddr as) pos json-flag lang-flag (cadr as) cases-file bad-flag))]
      [(string=? (car as) "--cases")
       (if (or (null? (cdr as)) (string-prefix? (cadr as) "--"))
           (loop '() pos json-flag lang-flag output-file "--cases")
           (loop (cddr as) pos json-flag lang-flag (cadr as) output-file bad-flag))]

      ;; unknown dash-flag ("-" itself is a positional: stdin marker)
      [(and (> (string-length (car as)) 1)
            (string-prefix? (car as) "-"))
       (loop '() pos json-flag lang-flag output-file cases-file (car as))]
      [else
       (loop (cdr as) (cons (car as) pos) json-flag lang-flag output-file cases-file bad-flag)])))

(define (die-usage)
  (display (msg 'usage regexmate-version))
  (exit EXIT-USAGE))

;; ---- text input ----------------------------------------------------

(define (read-stdin-text)
  (port->string (current-input-port)))

;; ---- commands ------------------------------------------------------

(define (invalid-pattern-quit pattern command json?)
  (define err (get-regex-error pattern))
  (define hint (hint-for-error err))
  (if json?
      (displayln (jsexpr->line (format-error-json command err hint)))
      (begin
        (display (msg 'err-invalid-regex err))
        (when hint (display (msg 'validate-hint hint)))))
  (exit EXIT-INVALID))

(define (group-names-for pattern)
  (define parsed (parse-regex-safe pattern))
  (define ast (car parsed))
  (if ast
      (let-values ([(_ nm) (collect-groups ast)]) nm)
      (hash)))

(define (cmd-validate pattern json?)
  (define valid (valid-regex? pattern))
  (define err (and (not valid) (get-regex-error pattern)))
  (define hint (hint-for-error err))
  (if json?
      (displayln (jsexpr->line (format-validate-json pattern valid err hint)))
      (begin
        (display (msg 'validate-pattern pattern))
        (if valid
            (display (msg 'validate-ok))
            (begin
              (display (msg 'validate-bad err))
              (when hint (display (msg 'validate-hint hint)))))))
  (exit (if valid EXIT-OK EXIT-INVALID)))

;; cookbook: no argument lists everything; otherwise the argument is a
;; recipe id or a topic, and matching recipes print in full detail
(define (cmd-cookbook arg json?)
  (define lang-zh? (eq? (current-language) 'zh))
  (define (title r)
    (if lang-zh? (recipe-title-zh r) (recipe-title-en r)))
  (cond
    [(not arg)
     (if json?
         (displayln (jsexpr->line
                     (format-cookbook-list-json recipes (map title recipes))))
         (display (format-cookbook-list recipes)))
     (exit EXIT-OK)]
    [else
     (define sym (with-handlers ([exn:fail? (lambda (_) #f)])
                   (and arg (string->symbol arg))))
     (define matches
       (cond
         [(not sym) '()]
         [(recipe-by-id sym) => list]
         [(member sym (recipe-topics)) => (lambda (_) (recipes-in-topic sym))]
         [else '()]))
     (cond
       [(null? matches)
        (if json?
            (displayln (jsexpr->line (format-error-json "cookbook" (format "no recipe or topic '~a'" arg))))
            (displayln (msg 'cookbook-unknown arg)))
        (exit EXIT-USAGE)]
       [else
        (if json?
            (displayln
             (jsexpr->line
              (if (null? (cdr matches))
                  (format-cookbook-json
                   (car matches) (title (car matches))
                   (if lang-zh? (recipe-notes-zh (car matches)) (recipe-notes-en (car matches)))
                   (if lang-zh? (recipe-variants-zh (car matches)) (recipe-variants-en (car matches)))
                   (if lang-zh? (recipe-sample-zh (car matches)) (recipe-sample-en (car matches))))
                  (format-cookbook-list-json matches (map title matches)))))
            (for ([r matches])
              (display (format-cookbook-recipe r))
              (newline)))
        (exit EXIT-OK)])]))

(define (spans-of match-records)
  (for/list ([m match-records]) (car m)))

(define (cmd-match pattern text json?)
  (unless (valid-regex? pattern)
    (invalid-pattern-quit pattern "match" json?))
  (define records (find-all-matches pattern text))
  (define names (group-names-for pattern))
  (if json?
      (displayln (jsexpr->line (format-match-json pattern text records names)))
      (if (color-enabled?)
          (displayln (highlight-matches text (spans-of records)))
          (if (null? records)
              (display (msg 'match-none))
              (begin
                (display (msg 'match-found (length records)))
                (for ([m records])
                  (match-define (cons span _) m)
                  (display (msg 'match-entry
                                (car span) (cdr span)
                                (substring text (car span) (cdr span)))))))))
  (exit (if (null? records) EXIT-NO-MATCH EXIT-OK)))

(define (cmd-explain pattern json?)
  (unless (valid-regex? pattern)
    (invalid-pattern-quit pattern "explain" json?))
  (define parts (explain-regex pattern))
  (if json?
      (displayln (jsexpr->line (format-explain-json pattern parts)))
      (display (format-explain-human pattern parts)))
  (exit EXIT-OK))

(define (cmd-replace pattern replacement text json?)
  (unless (valid-regex? pattern)
    (invalid-pattern-quit pattern "replace" json?))
  (define replaced (replace-regex pattern text replacement))
  (define result (car replaced))
  (define count (cdr replaced))
  (if json?
      (displayln (jsexpr->line (format-replace-json pattern replacement text result count)))
      (begin
        (display (if (zero? count) (msg 'replace-none) (msg 'replace-result count)))
        (display (msg 'replace-text result))))
  (exit (if (zero? count) EXIT-NO-MATCH EXIT-OK)))

(define (cmd-graph pattern output-file json?)
  (unless (valid-regex? pattern)
    (invalid-pattern-quit pattern "graph" json?))
  (define parsed (parse-regex-safe pattern))
  (define ast (car parsed))
  (cond
    ;; pregexp-valid but not modelable — degrade gracefully
    [(not ast)
     (if json?
         (displayln (jsexpr->line
                     (format-error-json "graph"
                                        "pattern uses syntax the visualizer does not support")))
         (display (msg 'explain-unsupported)))
     (exit EXIT-INVALID)]
    [else
     (define svg-bytes (ast->svg ast))
     (cond
       [output-file
        (call-with-output-file output-file
          (lambda (out) (write-bytes svg-bytes out))
          #:exists 'truncate)
        (if json?
            (displayln (jsexpr->line
                        (format-graph-file-json pattern output-file (bytes-length svg-bytes))))
            (display (msg 'graph-saved output-file)))]
       [json?
        (displayln (jsexpr->line (format-graph-json pattern (bytes->string/utf-8 svg-bytes))))]
       [else
        (write-bytes svg-bytes)])
     (exit EXIT-OK)]))

(define (cmd-test pattern cases-file json?)
  (unless (valid-regex? pattern)
    (invalid-pattern-quit pattern "test" json?))
  (define input-text
    (if (or (not cases-file) (string=? cases-file "-"))
        (read-stdin-text)
        (port->string (open-input-file cases-file))))
  (define parsed
    (with-handlers ([exn:fail? (lambda (e) 'invalid-json)])
      (string->jsexpr input-text)))
  (cond
    [(eq? parsed 'invalid-json)
     (if json?
         (displayln (jsexpr->line (format-error-json "test" "cases input is not valid JSON")))
         (display (msg 'test-input-error)))
     (exit EXIT-USAGE)]
    [else
     (define-values (results passed failed) (run-cases pattern parsed))
     (if json?
         (displayln (jsexpr->line
                     (format-test-json pattern results (length results) passed failed)))
         (begin
           (for ([r results])
             (display (if (hash-ref r 'pass)
                          (msg 'test-case-pass (hash-ref r 'text))
                          (msg 'test-case-fail (hash-ref r 'text) (hash-ref r 'reason)))))
           (display (msg 'test-summary passed (length results)))))
     (exit (if (zero? failed) EXIT-OK EXIT-NO-MATCH))]))

(define (cmd-lint pattern strict? json?)
  (unless (valid-regex? pattern)
    (invalid-pattern-quit pattern "lint" json?))
  (define warnings (lint-regex-json pattern))
  (if json?
      (displayln (jsexpr->line (format-lint-json pattern warnings)))
      (if (null? warnings)
          (display (msg 'lint-none))
          (begin
            (display (msg 'lint-header (length warnings)))
            (for ([w warnings])
              (display (msg 'lint-entry
                            (hash-ref w 'severity)
                            (hash-ref w 'rule)
                            (hash-ref w 'position)
                            (hash-ref w 'message)))))))
  (exit (if (and strict? (not (null? warnings))) EXIT-NO-MATCH EXIT-OK)))

(define (update-envelope action current latest asset)
  (hasheq 'schema SCHEMA
          'command "update"
          'ok #t
          'current current
          'latest latest
          'updateAvailable (version<? current latest)
          'action action
          'asset asset))

(define (cmd-update check-only? json?)
  (unless (installed-mode?)
    (if json?
        (displayln (jsexpr->line (format-error-json
                                  "update" "not a standalone install; self-update unavailable")))
        (display (msg 'update-source)))
    (exit EXIT-USAGE))
  (with-handlers
      ([exn:fail?
        (lambda (e)
          (define m (exn-message e))
          (if json?
              (displayln (jsexpr->line (format-error-json "update" m)))
              (display (msg 'update-failed m)))
          (exit EXIT-INVALID))])
    (unless json? (display (msg 'update-checking)))
    (define latest (fetch-latest-release))
    (define tag (hash-ref latest 'tag))
    (define current regexmate-version)
    (cond
      [check-only?
       (if json?
           (displayln (jsexpr->line (update-envelope "checked" current tag #f)))
           (display (msg 'update-check-result tag current)))
       (exit EXIT-OK)]
      [(not (version<? current tag))
       (if json?
           (displayln (jsexpr->line (update-envelope "none" current tag #f)))
           (display (msg 'update-up-to-date current)))
       (exit EXIT-OK)]
      [else
       (define asset-name (asset-name tag))
       (define asset-def
         (for/first ([a (in-list (hash-ref latest 'assets))]
                     #:when (string=? (hash-ref a 'name) asset-name))
           a))
       (unless asset-def
         (error 'update (format "release asset ~a not found" asset-name)))
       (define sha-name (string-append asset-name ".sha256"))
       (define sha-def
         (for/first ([a (in-list (hash-ref latest 'assets))]
                     #:when (string=? (hash-ref a 'name) sha-name))
           a))
       (define stage (build-path (install-dir)
                                 (string-append "regexmate-update-"
                                                (number->string (current-milliseconds)))))
       (make-directory* stage)
       (define archive (build-path stage asset-name))
       (unless json? (display (msg 'update-downloading asset-name)))
       (download-to-file
        (hash-ref asset-def 'url) archive
        (and (not json?)
             (lambda (done)
               (when (number? done)
                 (fprintf (current-error-port) "  ~a MB\r"
                          (quotient done 1048576))))))
       (when sha-def
         (unless json? (display (msg 'update-verifying)))
         (define sha-file (build-path stage sha-name))
         (download-to-file (hash-ref sha-def 'url) sha-file #f)
         (define want
           (first (string-split (string-trim (port->string (open-input-file sha-file))))))
         (define got (sha256-file archive))
         (unless (string-ci=? want got)
           (error 'update (format "checksum mismatch: want ~a, got ~a" want got))))
       (unless json? (display (msg 'update-installing)))
       (define extract-dir (build-path stage "unpacked"))
       (extract-archive archive extract-dir)
       ;; windows archives are flat (regexmate.exe + lib/); unix ones use
       ;; bin/ layout (bin/regexmate + lib/)
       (define flat-exe (build-path extract-dir (exe-name)))
       (define bin-exe (build-path extract-dir "bin" (exe-name)))
       (define-values (new-exe new-lib)
         (cond
           [(file-exists? flat-exe)
            (values flat-exe
                    (let ([l (build-path extract-dir "lib")])
                      (and (directory-exists? l) l)))]
           [(file-exists? bin-exe)
            (values bin-exe
                    (let ([l (build-path extract-dir "lib")])
                      (and (directory-exists? l) l)))]
           [else (error 'update "unexpected archive layout")]))
       (swap-install new-exe new-lib)
       (if json?
           (displayln (jsexpr->line (update-envelope "updated" current tag asset-name)))
           (display (msg 'update-done tag)))
       (exit EXIT-OK)])))

(define (cmd-report pattern text-file cases-file out-file json?)
  (unless (valid-regex? pattern)
    (invalid-pattern-quit pattern "report" json?))
  (define text
    (cond
      [(or (not text-file) (string=? text-file "-")) (read-stdin-text)]
      [(string=? text-file "@") ""]
      [else (port->string (open-input-file text-file))]))
  (define test-results
    (and cases-file
         (let ()
           (define input-text
             (if (string=? cases-file "-")
                 (read-stdin-text)
                 (port->string (open-input-file cases-file))))
           (define-values (results passed failed)
             (run-cases pattern (string->jsexpr input-text)))
           results)))
  (define rows
    (for/list ([m (in-list (find-all-matches pattern text))])
      (match-define (cons span groups) m)
      (list (substring text (car span) (cdr span))
            (number->string (car span))
            (number->string (cdr span))
            (number->string (length groups)))))
  (define explain
    (format-explain-human pattern (explain-regex pattern)))
  (define lint-rows (lint-regex-json pattern))
  (define parsed (parse-regex-safe pattern))
  (define diagram-svg
    (and (car parsed) (bytes->string/utf-8 (ast->svg (car parsed)))))
  (define html (report-html pattern text rows explain lint-rows
                            test-results diagram-svg regexmate-version))
  (if out-file
      (begin
        (call-with-output-file out-file
          (lambda (out) (display html out))
          #:exists 'truncate)
        (if json?
            (displayln (jsexpr->line
                        (hasheq 'schema SCHEMA 'command "report" 'ok #t
                                'pattern pattern 'output out-file
                                'bytes (string-length html))))
            (displayln (msg 'report-saved out-file))))
      (begin
        (display html)
        (when json?
          (displayln (jsexpr->line
                      (hasheq 'schema SCHEMA 'command "report" 'ok #t
                              'pattern pattern 'bytes (string-length html)))))))
  (exit EXIT-OK))

;; machine-readable self-description: the contract itself, for agent discovery
(define (cmd-schema)
  (displayln
   (jsexpr->line
    (hasheq 'schema SCHEMA
            'command "schema"
            'ok #t
            'version regexmate-version
            'commands
            (list
             (hasheq 'name "validate" 'args '("pattern")
                     'exit "0 valid / 1 invalid")
             (hasheq 'name "match" 'args '("pattern" "text-or--")
                     'exit "0 matches / 3 none / 1 invalid")
             (hasheq 'name "explain" 'args '("pattern"))
             (hasheq 'name "replace" 'args '("pattern" "replacement" "text-or--")
                     'exit "0 replaced / 3 none / 1 invalid")
             (hasheq 'name "graph" 'args '("pattern")
                     'flags '("-o FILE")
                     'exit "0 ok / 1 unmodelable")
             (hasheq 'name "test" 'args '("pattern" "cases-file-or--")
                     'exit "0 all pass / 3 failures / 1 invalid")
             (hasheq 'name "lint" 'args '("pattern")
                     'flags '("--strict")
                     'exit "0 clean / 3 findings with --strict")
             (hasheq 'name "cookbook" 'args '("[id-or-topic]")
                     'exit "0 ok / 2 unknown id")
             (hasheq 'name "completions" 'args '("bash|zsh|pwsh"))
             (hasheq 'name "schema" 'args '())
             (hasheq 'name "update" 'args '()
                     'flags '("--check")
                     'exit "0 ok / 1 failed / 2 not a standalone install")
             (hasheq 'name "mcp" 'desc "stdio MCP server (JSON-RPC 2.0, newline-delimited)"))
            'flags '("--json" "--lang en|zh" "-o FILE" "--version" "--help")
            'envelope (hasheq 'fields '("schema" "command" "ok")
                              'spans "absolute [start,end)"
                              'groups "1-based; null when absent")
            'exit-codes (list
                             (hasheq 'code "0" 'meaning "ok")
                             (hasheq 'code "1" 'meaning "invalid regex")
                             (hasheq 'code "2" 'meaning "usage error")
                             (hasheq 'code "3" 'meaning "valid pattern, no match/zero replacements/findings"))
            'mcp (hasheq 'transport "stdio (newline-delimited JSON-RPC 2.0)"
                         'tools '("regexmate_validate" "regexmate_match" "regexmate_explain"
                                  "regexmate_replace" "regexmate_graph" "regexmate_test"
                                  "regexmate_lint" "regexmate_cookbook")))))
  (exit EXIT-OK))

;; ---- shell completions ----------------------------------------------

(define (completions-script shell)
  (cond
    [(string=? shell "bash")
     #<<EOF
# bash completion for regexmate
_regexmate() {
  local cur prev commands flags
  COMPREPLY=()
  cur="${COMP_WORDS[COMP_CWORD]}"
  prev="${COMP_WORDS[COMP_CWORD-1]}"
  commands="match validate explain replace graph test lint cookbook report schema update mcp help"
  flags="--json --lang --strict --check --cases -o --version --help"
  if [[ "$prev" == "--lang" ]]; then
    COMPREPLY=( $(compgen -W "en zh" -- "$cur") )
  elif [[ "$prev" == "--generate-completions" ]]; then
    COMPREPLY=( $(compgen -W "bash zsh pwsh" -- "$cur") )
  elif [[ "$cur" == --* ]]; then
    COMPREPLY=( $(compgen -W "$flags" -- "$cur") )
  else
    COMPREPLY=( $(compgen -W "$commands" -- "$cur") )
  fi
  return 0
}
complete -F _regexmate regexmate
EOF
    ]
    [(string=? shell "zsh")
     #<<EOF
#compdef regexmate
_regexmate() {
  local -a commands flags
  commands=(match validate explain replace graph test lint cookbook report schema update mcp help)
  flags=(--json --lang --strict --check --cases -o --version --help)
  if (( CURRENT == 2 )); then
    _describe 'command' commands
  else
    _describe 'option' flags
  fi
}
_regexmate "$@"
EOF
    ]
    [(string=? shell "pwsh")
     #<<EOF
# PowerShell completion for regexmate
Register-ArgumentCompleter -Native -CommandName regexmate -ScriptBlock {
  param($wordToComplete, $commandAst, $cursorPosition)
  $commands = 'match','validate','explain','replace','graph','test','lint','cookbook','report','schema','update','mcp','help'
  $flags = '--json','--lang','--strict','--check','--cases','-o','--version','--help'
  if ($wordToComplete -like '--*') {
    $flags | Where-Object { $_ -like "$wordToComplete*" } | ForEach-Object { [System.Management.Automation.CompletionResult]::new($_) }
  } else {
    $commands | Where-Object { $_ -like "$wordToComplete*" } | ForEach-Object { [System.Management.Automation.CompletionResult]::new($_) }
  }
}
EOF
    ]
    [else
     (error 'completions "unsupported shell: ~a (use bash, zsh or pwsh)" shell)]))

(define (cmd-completions shell)
  (unless (member shell '("bash" "zsh" "pwsh"))
    (displayln (format "unsupported shell: ~a (use bash, zsh or pwsh)" shell))
    (exit EXIT-USAGE))
  (display (completions-script shell))
  (exit EXIT-OK))

;; ---- entry ---------------------------------------------------------

(define (main)
  ;; finish a previous update's cleanup quietly (stale .old runtime files)
  (with-handlers ([exn:fail? (lambda (e) (void))])
    (cleanup-stale-updates))
  (define args (vector->list (current-command-line-arguments)))
  (define-values (positionals json-flag lang-flag output-file cases-file bad-flag)
    (parse-args args))

  (when bad-flag
    (displayln (msg 'err-unknown-flag bad-flag))
    (exit EXIT-USAGE))

  (when (member "--help" positionals)
    (display (msg 'usage regexmate-version))
    (exit EXIT-OK))

  (when (member "--version" positionals)
    (if json-flag
        (displayln (jsexpr->line (format-version-json regexmate-version)))
        (displayln (msg 'usage-version regexmate-version)))
    (exit EXIT-OK))

  (define lang (resolve-language lang-flag))
  (unless (or (not lang-flag) lang)
    (displayln (msg 'err-unknown-flag (format "--lang ~a" lang-flag)))
    (exit EXIT-USAGE))
  (when lang (current-language lang))

  (define command (and (not (null? positionals)) (car positionals)))
  (define rest (if command (cdr positionals) '()))

  (case command
    [("match")
     (match rest
       [(list pattern text)
        (cmd-match pattern (if (string=? text "-") (read-stdin-text) text) json-flag)]
       [(list pattern)
        (cmd-match pattern (read-stdin-text) json-flag)]
       [_ (die-usage)])]
    [("validate")
     (match rest
       [(list pattern) (cmd-validate pattern json-flag)]
       [_ (die-usage)])]
    [("explain")
     (match rest
       [(list pattern) (cmd-explain pattern json-flag)]
       [_ (die-usage)])]
    [("replace")
     (match rest
       [(list pattern replacement text)
        (cmd-replace pattern replacement
                     (if (string=? text "-") (read-stdin-text) text)
                     json-flag)]
       [(list pattern replacement)
        (cmd-replace pattern replacement (read-stdin-text) json-flag)]
       [_ (die-usage)])]
    [("graph")
     (match rest
       [(list pattern) (cmd-graph pattern output-file json-flag)]
       [_ (die-usage)])]
    [("test")
     (match rest
       [(list pattern file) (cmd-test pattern file json-flag)]
       [(list pattern) (cmd-test pattern "-" json-flag)]
       [_ (die-usage)])]
    [("lint")
     (define strict? (member "--strict" positionals))
     (define rest* (remove "--strict" rest))
     (match rest*
       [(list pattern) (cmd-lint pattern strict? json-flag)]
       [_ (die-usage)])]
    [("report")
     (match rest
       [(list pattern) (cmd-report pattern "-" cases-file output-file json-flag)]
       [(list pattern text-file) (cmd-report pattern text-file cases-file output-file json-flag)]
       [(list pattern text-file out-file) (cmd-report pattern text-file cases-file out-file json-flag)]
       [_ (die-usage)])]
    [("completions")
     (match rest
       [(list shell) (cmd-completions shell)]
       [_ (die-usage)])]
    [("cookbook")
     (match rest
       [(list) (cmd-cookbook #f json-flag)]
       [(list arg) (cmd-cookbook arg json-flag)]
       [_ (die-usage)])]
    [("schema") (cmd-schema)]
    [("update")
     (define check-only? (member "--check" positionals))
     (define rest* (remove "--check" rest))
     (match rest*
       [(list) (cmd-update check-only? json-flag)]
       [_ (die-usage)])]
    [("mcp") (mcp-main) (exit EXIT-OK)]
    [("help")
     (display (msg 'usage regexmate-version))
     (exit EXIT-OK)]
    [(#f)
     (display (msg 'usage regexmate-version))
     (exit EXIT-USAGE)]
    [else
     (displayln (msg 'err-unknown-command command))
     (exit EXIT-USAGE)]))

(main)
