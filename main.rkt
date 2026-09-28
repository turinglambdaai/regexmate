#lang racket

(require racket/match
         json
         "version.rkt"
         "core/regex-engine.rkt"
         "core/regex-parser.rkt"
         "core/ast.rkt"
         "core/i18n.rkt"
         "output/json-format.rkt"
         "output/highlight.rkt"
         "output/human-format.rkt"
         "output/railroad.rkt")

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
