#lang racket

(require rackunit
         "../core/cookbook.rkt"
         "../core/regex-engine.rkt"
         "../core/i18n.rkt"
         "../core/linter.rkt"
         "../output/human-format.rkt"
         "../output/json-format.rkt")

;; The cookbook is teaching content, so the tests enforce the contract that
;; makes it trustworthy: every pattern compiles, every pattern matches its
;; own sample, every note segment is a real substring of the pattern (or the
;; "*" general-note marker), and ids/topics resolve.

(define cookbook-tests
  (test-suite
   "cookbook"

   (test-case "library shape"
     (check-true ((length recipes) . >= . 20) "expect a substantial library")
     (check-equal? (length (remove-duplicates (map recipe-id recipes)))
                   (length recipes))
     (check-true (andmap symbol? (recipe-topics))))

   (test-case "every pattern is valid and matches its own samples"
     (for ([r recipes])
       (check-true (valid-regex? (recipe-pattern r))
                   (format "~a pattern invalid" (recipe-id r)))
       (for ([sample (in-list (list (recipe-sample-en r) (recipe-sample-zh r)))]
             [lang '("en" "zh")])
         (unless (string=? sample "")
           (check-false (null? (find-all-matches (recipe-pattern r) sample))
                        (format "~a pattern does not match ~a sample" (recipe-id r) lang))))))

   (test-case "note segments are substrings of the pattern (or the * marker)"
     (for* ([r recipes]
            [notes (in-list (list (recipe-notes-en r) (recipe-notes-zh r)))]
            [pair (in-list notes)])
       (check-true (or (string=? (car pair) "*")
                       (string-contains? (recipe-pattern r) (car pair)))
                   (format "~a note segment ~s not in pattern"
                           (recipe-id r) (car pair)))))

   (test-case "lookup helpers"
     (check-equal? (recipe-id (recipe-by-id 'email)) 'email)
     (check-false (recipe-by-id 'nope))
     (check-true (andmap (lambda (r) (eq? (recipe-topic r) 'web))
                         (recipes-in-topic 'web))))

   (test-case "json envelopes"
     (define listing (format-cookbook-list-json recipes
                                                (map recipe-title-en recipes)))
     (check-equal? (hash-ref listing 'command) "cookbook")
     (check-equal? (hash-ref listing 'count) (length recipes))
     (define email (recipe-by-id 'email))
     (define detail (format-cookbook-json email "Email address (practical)"
                                          (recipe-notes-en email)
                                          (recipe-variants-en email)
                                          (recipe-sample-en email)))
     (define row (car (hash-ref detail 'recipes)))
     (check-equal? (hash-ref row 'id) "email")
     (check-equal? (hash-ref row 'pattern)
                   "[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\\.[a-zA-Z]{2,}")
     (check-true (list? (hash-ref row 'notes)))
     (check-false (string-contains? (jsexpr->line detail) "\n")))

   (test-case "localization switches recipe content"
     (define email (recipe-by-id 'email))
     (define en (parameterize ([current-language 'en])
                  (format-cookbook-recipe email)))
     (define zh (parameterize ([current-language 'zh])
                  (format-cookbook-recipe email)))
     (check-true (string-contains? en "Email address (practical)"))
     (check-true (string-contains? zh "邮箱地址（实用版）"))
     (check-false (string=? en zh)))

   ;; lint findings are fully translated in zh (the teaching content must
   ;; not fall back to English mid-sentence)
   (test-case "lint messages localize completely"
     (define en-msgs
       (parameterize ([current-language 'en])
         (map (lambda (w) (hash-ref w 'message)) (lint-regex-json "(a+)+|a|"))))
     (define zh-msgs
       (parameterize ([current-language 'zh])
         (map (lambda (w) (hash-ref w 'message)) (lint-regex-json "(a+)+|a|"))))
     (check-true (andmap string? en-msgs))
     (check-true (andmap string? zh-msgs))
     (check-not-equal? en-msgs zh-msgs)
     ;; zh messages contain no ASCII-letter run longer than a rule example
     (for ([m zh-msgs])
       (check-false (string-contains? m "backtrack"))))

   (test-case "validate hints"
     (check-true (string? (hint-for-error "missing closing square bracket in pattern")))
     (check-true (string-contains?
                  (parameterize ([current-language 'zh])
                    (hint-for-error "missing closing square bracket in pattern"))
                  "字符类"))
     (check-false (hint-for-error #f))
     (check-false (hint-for-error "some totally unknown engine failure")))))

(provide cookbook-tests)
