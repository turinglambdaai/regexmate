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
  (let loop ([as args] [pos '()] [json-flag #f] [lang-flag #f] [output-file #f] [bad-flag #f])
    (cond
      [(null? as)
       (values (reverse pos) json-flag lang-flag output-file bad-flag)]
      [(string=? (car as) "--json")
       (loop (cdr as) pos #t lang-flag output-file bad-flag)]
      [(or (string=? (car as) "--help") (string=? (car as) "-h"))
       (loop (cdr as) (cons "--help" pos) json-flag lang-flag output-file bad-flag)]
      [(string=? (car as) "--version")
       (loop (cdr as) (cons "--version" pos) json-flag lang-flag output-file bad-flag)]
      [(string=? (car as) "--strict")
       ;; advisory flag for lint; travels via positionals to the command layer
       (loop (cdr as) (cons "--strict" pos) json-flag lang-flag output-file bad-flag)]
      [(string=? (car as) "--lang")
       (if (or (null? (cdr as)) (string-prefix? (cadr as) "--"))
           (loop '() pos json-flag lang-flag output-file "--lang")
           (loop (cddr as) pos json-flag (cadr as) output-file bad-flag))]
      [(string=? (car as) "-o")
       (if (or (null? (cdr as)) (string-prefix? (cadr as) "--"))
           (loop '() pos json-flag lang-flag output-file "-o")
           (loop (cddr as) pos json-flag lang-flag (cadr as) bad-flag))]
      ;; unknown dash-flag ("-" itself is a positional: stdin marker)
      [(and (> (string-length (car as)) 1)
            (string-prefix? (car as) "-"))
       (loop '() pos json-flag lang-flag output-file (car as))]
      [else
       (loop (cdr as) (cons (car as) pos) json-flag lang-flag output-file bad-flag)])))

(define (die-usage)
  (display (msg 'usage regexmate-version))
  (exit EXIT-USAGE))

;; ---- text input ----------------------------------------------------

(define (read-stdin-text)
  (port->string (current-input-port)))

;; ---- commands ------------------------------------------------------

(define (invalid-pattern-quit pattern command json?)
  (define err (get-regex-error pattern))
  (if json?
      (displayln (jsexpr->line (format-error-json command err)))
      (display (msg 'err-invalid-regex err)))
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
  (if json?
      (displayln (jsexpr->line (format-validate-json pattern valid err)))
      (begin
        (display (msg 'validate-pattern pattern))
        (display (if valid (msg 'validate-ok) (msg 'validate-bad err)))))
  (exit (if valid EXIT-OK EXIT-INVALID)))

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

;; machine-readable self-description: the contract itself, for agent discovery
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
             (hasheq 'name "schema" 'args '())
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
                                  "regexmate_lint")))))
  (exit EXIT-OK))

;; ---- entry ---------------------------------------------------------

(define (main)
  (define args (vector->list (current-command-line-arguments)))
  (define-values (positionals json-flag lang-flag output-file bad-flag)
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
    [("schema") (cmd-schema)]
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
