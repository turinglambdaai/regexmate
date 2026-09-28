#lang racket

(require rackunit
         "../output/json-format.rkt"
         "../core/regex-engine.rkt")

;; The format-* functions return jsexpr hashes; jsexpr->line serializes
;; them for stdout. These tests check the contract fields directly.

(define json-format-tests
  (test-suite
   "json format"

   (test-case "validate valid"
     (define data (format-validate-json "^\\d+$" #t #f))
     (check-equal? (hash-ref data 'schema) "regexmate/v1")
     (check-equal? (hash-ref data 'command) "validate")
     (check-equal? (hash-ref data 'ok) #t)
     (check-equal? (hash-ref data 'valid) #t)
     (check-equal? (hash-ref data 'pattern) "^\\d+$")
     ;; serializes to a single JSON line
     (check-false (string-contains? (jsexpr->line data) "\n")))

   (test-case "validate invalid carries error"
     (define data (format-validate-json "(" #f "missing closing parenthesis"))
     (check-equal? (hash-ref data 'ok) #f)
     (check-equal? (hash-ref data 'valid) #f)
     (check-equal? (hash-ref data 'error) "missing closing parenthesis"))

   (test-case "match envelope with absent group"
     (define text "ab axb")
     (define records (find-all-matches "a(x)?b" text))
     (define data (format-match-json "a(x)?b" text records (hash)))
     (check-equal? (hash-ref data 'schema) "regexmate/v1")
     (check-equal? (hash-ref data 'command) "match")
     (check-equal? (hash-ref data 'count) 2)
     (define first-match (car (hash-ref data 'matches)))
     (check-equal? (hash-ref first-match 'value) "ab")
     (check-equal? (hash-ref first-match 'start) 0)
     (check-equal? (hash-ref first-match 'end) 2)
     (define g (car (hash-ref first-match 'groups)))
     (check-equal? (hash-ref g 'index) 1)
     (check-equal? (hash-ref g 'value) #f)
     (check-equal? (hash-ref g 'start) #f))

   (test-case "match group values and names"
     (define text "a@b c@d")
     (define records (find-all-matches "(\\w+)@(\\w+)" text))
     (define data (format-match-json "(\\w+)@(\\w+)" text records (hash 1 "user" 2 "host")))
     (define groups (hash-ref (car (hash-ref data 'matches)) 'groups))
     (check-equal? (hash-ref (car groups) 'value) "a")
     (check-equal? (hash-ref (car groups) 'name) "user")
     (check-equal? (hash-ref (cadr groups) 'value) "b")
     (check-equal? (hash-ref (cadr groups) 'name) "host"))

   (test-case "replace envelope"
     (define data (format-replace-json "a+" "x" "baaad" "bxd" 1))
     (check-equal? (hash-ref data 'command) "replace")
     (check-equal? (hash-ref data 'count) 1)
     (check-equal? (hash-ref data 'result) "bxd"))

   (test-case "graph envelopes"
     (define svg-data (format-graph-json "a" "<svg/>"))
     (check-equal? (hash-ref svg-data 'command) "graph")
     (check-equal? (hash-ref svg-data 'svg) "<svg/>")
     (define file-data (format-graph-file-json "a" "out.svg" 6))
     (check-equal? (hash-ref file-data 'output) "out.svg")
     (check-equal? (hash-ref file-data 'bytes) 6))

   (test-case "error and version envelopes"
     (define err (format-error-json "match" "boom"))
     (check-equal? (hash-ref err 'ok) #f)
     (check-equal? (hash-ref err 'error) "boom")
     (define ver (format-version-json "9.9.9"))
     (check-equal? (hash-ref ver 'command) "version")
     (check-equal? (hash-ref ver 'version) "9.9.9"))))

(provide json-format-tests)
