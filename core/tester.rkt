#lang racket

;; Batch regex testing: assert a pattern against a list of sample texts.
;; This is the agent iteration loop — write, test, get per-case evidence, refine.
;;
;; Input cases (JSON): {"cases":[{"text": "...", "expect": "match"|"no-match",
;;                                "contains": "..."}]}
;; "contains" additionally asserts that some match value contains the
;; given substring. A bare JSON array of cases is accepted too.

(require "regex-engine.rkt")

;; case -> result object (hash). Pass/fail verdict includes the reason.
;; Malformed cases fail with a reason instead of raising.
(define (run-case pattern case)
  (define text (hash-ref case 'text #f))
  (define expect (hash-ref case 'expect "match"))
  (define contains (hash-ref case 'contains #f))
  (cond
    [(or (not (hash? case)) (not (string? text)))
     (hasheq 'text (if (string? text) text "")
             'expect expect 'matched #f 'count 0 'value #f
             'pass #f 'reason "malformed case: \"text\" (string) is required")]
    [(and (not (string=? expect "match")) (not (string=? expect "no-match")))
     (hasheq 'text text 'expect expect 'matched #f 'count 0 'value #f
             'pass #f 'reason (format "malformed case: expect must be \"match\" or \"no-match\", got ~s" expect))]
    [(and contains (not (string? contains)))
     (hasheq 'text text 'expect expect 'matched #f 'count 0 'value #f
             'pass #f 'reason "malformed case: \"contains\" must be a string")]
    [else
     (define matches (find-all-matches pattern text))
     (define matched? (pair? matches))
     (define first-value
       (and matched?
            (substring text (car (car (car matches))) (cdr (car (car matches))))))
     (define-values (pass? reason)
       (cond
         [(and (string=? expect "match") (not matched?))
          (values #f "expected a match but none was found")]
         [(and (string=? expect "no-match") matched?)
          (values #f (format "expected no match but ~a match(es) were found" (length matches)))]
         [(and contains
               (not (and matched? first-value (string-contains? first-value contains))))
          (values #f (format "match ~s does not contain ~s" first-value contains))]
         [else (values #t #f)]))
     (hasheq 'text text
             'expect expect
             'matched matched?
             'count (length matches)
             'value first-value
             'pass pass?
             'reason reason)]))

;; parse flexible case input: bare array or {"cases": [...]}
(define (parse-cases jsexpr)
  (cond
    [(list? jsexpr) jsexpr]
    [(hash? jsexpr) (hash-ref jsexpr 'cases '())]
    [else '()]))

;; run all cases; returns (list results passed failed)
(define (run-cases pattern cases-jsexpr)
  (define results
    (for/list ([case (parse-cases cases-jsexpr)])
      (run-case pattern case)))
  (define passed (count (lambda (r) (hash-ref r 'pass)) results))
  (values results passed (- (length results) passed)))

(provide run-case run-cases parse-cases)
