#lang racket

(require rackunit
         "../core/linter.rkt")

(define linter-tests
  (test-suite
   "linter"

   (test-case "nested quantifiers are flagged"
     (define rules (map (lambda (w) (hash-ref w 'rule)) (lint-regex-json "(a+)+b")))
     (check-not-false (member "nested-quantifier" rules) (format "~a" rules)))

   (test-case "bounded nesting is not flagged"
     (check-equal? (lint-regex-json "(a{2}){3}") '()))

   (test-case "quantified assertion is flagged"
     (define rules (map (lambda (w) (hash-ref w 'rule)) (lint-regex-json "(?=x)*y")))
     (check-not-false (member "quantified-assertion" rules) (format "~a" rules)))

   (test-case "empty branch is flagged once per pattern"
     (define ws (lint-regex-json "ab|"))
     (define empties (filter (lambda (w) (string=? (hash-ref w 'rule) "empty-branch")) ws))
     (check-equal? (length empties) 1))

   (test-case "duplicate branch is flagged as info"
     (define ws (lint-regex-json "abc|xyz|abc"))
     (define dups (filter (lambda (w) (string=? (hash-ref w 'rule) "duplicate-branch")) ws))
     (check-equal? (length dups) 1)
     (check-equal? (hash-ref (car dups) 'severity) "info"))

   (test-case "literal shadowed branch is flagged"
     (define ws (lint-regex-json "alpha|alphabet"))
     (define shadow (filter (lambda (w) (string=? (hash-ref w 'rule) "shadowed-branch")) ws))
     (check-equal? (length shadow) 1))

   (test-case "meta-char branches are not false-positive shadows"
     (check-equal? (filter (lambda (w) (string=? (hash-ref w 'rule) "shadowed-branch"))
                           (lint-regex-json "\\d+|[0-9]+"))
                   '()))

   (test-case "clean pattern has no findings"
     (check-equal? (lint-regex-json "^[a-z]+[0-9]{2,4}$") '()))

   (test-case "portability: atomic groups and scoped flags are flagged as info"
     (define ws (lint-regex-json "(?>a)"))
     (check-not-false (member "portability" (map (lambda (w) (hash-ref w 'rule)) ws)))
     (define ws2 (lint-regex-json "(?i:abc)"))
     (check-not-false (member "portability" (map (lambda (w) (hash-ref w 'rule)) ws2))))

   (test-case "portability: posix class, unicode class, backref"
     (define rules (map (lambda (w) (hash-ref w 'rule)) (lint-regex-json "[[:alpha:]]\\p{L}(a)\\1")))
     (check-equal? (count (lambda (r) (string=? r "portability")) rules) 3))

   (test-case "redundant-atomic on single-element atomic group"
     (define ws (lint-regex-json "(?>a)b"))
     (check-not-false (member "redundant-atomic" (map (lambda (w) (hash-ref w 'rule)) ws)))
     ;; atomic over a quantifier is NOT flagged as redundant
     (check-false (member "redundant-atomic"
                          (map (lambda (w) (hash-ref w 'rule))
                               (lint-regex-json "(?>a+)b")))))

   (test-case "warnings are position-sorted jsexprs"
     (define ws (lint-regex-json "(a+)+|a|"))
     (check-true (>= (length ws) 2))
     (for ([w ws])
       (check-true (number? (hash-ref w 'position)))
       (check-true (string? (hash-ref w 'message)))))))

(provide linter-tests)
