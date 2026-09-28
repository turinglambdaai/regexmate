#lang racket

(require rackunit
         "../core/regex-engine.rkt")

(define regex-engine-tests
  (test-suite
   "regex engine"

   (test-case "valid-regex?"
     (check-true (valid-regex? "^\\d+$"))
     (check-true (valid-regex? "(a|b)*c"))
     (check-true (valid-regex? "(?=x)"))
     (check-true (valid-regex? "(?<=x)y"))
     (check-true (valid-regex? "[[:alpha:]]+"))
     (check-true (valid-regex? "\\p{L}+"))
     (check-true (valid-regex? "(a)\\1"))
     (check-true (valid-regex? "(?>a+)b"))
     (check-true (valid-regex? "(?i:abc)"))
     (check-false (valid-regex? "("))
     (check-false (valid-regex? "a)"))
     (check-false (valid-regex? "[a"))
     (check-false (valid-regex? "a{"))
     (check-false (valid-regex? "(a)\\2"))          ; backref beyond group count
     (check-false (valid-regex? "(?<name>x)"))      ; pregexp has no named groups
     (check-false (valid-regex? "\\Aabc")))         ; pregexp has no \A

   (test-case "get-regex-error"
     (check-false (get-regex-error "^\\d+$"))
     (define err (get-regex-error "("))
     (check-true (string? err))
     ;; single line: no embedded newline (JSON contract requirement)
     (check-false (string-contains? err "\n"))
     (check-false (string-prefix? err "pregexp:")))

   (test-case "find-all-matches spans"
     (define ms (find-all-matches "\\d+" "abc 123 def 456"))
     (check-equal? (length ms) 2)
     (check-equal? (car (car ms)) (cons 4 7))
     (check-equal? (car (cadr ms)) (cons 12 15)))

   (test-case "find-all-matches capture groups"
     (define ms (find-all-matches "(\\w+)@(\\w+)" "a@b c@d"))
     (check-equal? (length ms) 2)
     (match-define (cons overall groups) (car ms))
     (check-equal? overall (cons 0 3))
     (check-equal? (length groups) 2)
     (check-equal? (car groups) (cons 0 1))
     (check-equal? (cadr groups) (cons 2 3)))

   (test-case "find-all-matches absent group is #f"
     (define ms (find-all-matches "a(x)?b" "ab axb"))
     (check-equal? (length ms) 2)
     (check-equal? (cdr (car ms)) (list #f))          ; "ab": group absent
     (check-equal? (cdr (cadr ms)) (list (cons 4 5)))) ; "axb": group present

   (test-case "find-all-matches empty match never stalls"
     (define ms (find-all-matches "x*" "ab"))
     ;; empties at 0,1,2 — three positions, none repeated
     (check-equal? (length ms) 3)
     (for ([m ms])
       (check-equal? (car (car m)) (cdr (car m)))))

   (test-case "find-all-matches alternation and anchors"
     (check-equal? (length (find-all-matches "^\\d+$" "123")) 1)
     (check-equal? (length (find-all-matches "^\\d+$" "a123")) 0))

   (test-case "replace-regex"
     (define r (replace-regex "(\\w+)@(\\w+)" "mail a@b or c@d" "\\1 AT \\2"))
     (check-equal? (car r) "mail a AT b or c AT d")
     (check-equal? (cdr r) 2)
     (define none (replace-regex "zzz" "abc" "x"))
     (check-equal? (car none) "abc")
     (check-equal? (cdr none) 0))
   ))

(provide regex-engine-tests)
