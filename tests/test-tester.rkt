#lang racket

(require rackunit
         "../core/tester.rkt")

(define tester-tests
  (test-suite
   "tester"

   (test-case "matching case passes"
     (define r (run-case "\\d+" (hasheq 'text "abc 123" 'expect "match")))
     (check-true (hash-ref r 'pass))
     (check-equal? (hash-ref r 'value) "123")
     (check-equal? (hash-ref r 'count) 1)
     (check-false (hash-ref r 'reason)))

   (test-case "no-match case passes"
     (define r (run-case "\\d+" (hasheq 'text "abc" 'expect "no-match")))
     (check-true (hash-ref r 'pass)))

   (test-case "expected match but none fails with reason"
     (define r (run-case "\\d+" (hasheq 'text "abc")))
     (check-false (hash-ref r 'pass))
     (check-true (string-contains? (hash-ref r 'reason) "expected a match")))

   (test-case "expected no-match but matched fails with reason"
     (define r (run-case "\\d+" (hasheq 'text "a1" 'expect "no-match")))
     (check-false (hash-ref r 'pass))
     (check-true (string-contains? (hash-ref r 'reason) "no match")))

   (test-case "contains assertion"
     (check-true (hash-ref (run-case "\\d+" (hasheq 'text "a 123" 'contains "12")) 'pass))
     (define r (run-case "\\d+" (hasheq 'text "a 9" 'contains "12")))
     (check-false (hash-ref r 'pass))
     (check-true (string-contains? (hash-ref r 'reason) "does not contain")))

   (test-case "malformed cases fail without raising"
     (define r1 (run-case "\\d+" (hasheq 'expect "match")))
     (check-false (hash-ref r1 'pass))
     (check-true (string-contains? (hash-ref r1 'reason) "malformed"))
     (define r2 (run-case "\\d+" (hasheq 'text "x" 'expect "sometimes")))
     (check-false (hash-ref r2 'pass))
     (check-true (string-contains? (hash-ref r2 'reason) "expect must be")))

   (test-case "run-cases counts"
     (define-values (results passed failed)
       (run-cases "\\d+" (list (hasheq 'text "1")
                               (hasheq 'text "abc" 'expect "no-match")
                               (hasheq 'text "zzz"))))
     (check-equal? (length results) 3)
     (check-equal? passed 2)
     (check-equal? failed 1))

   (test-case "parse-cases accepts object and bare array"
     (check-equal? (length (parse-cases (hasheq 'cases (list 1 2)))) 2)
     (check-equal? (length (parse-cases (list 1 2 3))) 3)
     (check-equal? (length (parse-cases (hasheq))) 0))))

(provide tester-tests)
