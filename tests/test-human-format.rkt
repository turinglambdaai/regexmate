#lang racket

(require rackunit
         (only-in "../output/highlight.rkt" highlight-with-ansi)
         "../core/i18n.rkt"
         "../output/highlight.rkt"
         "../output/human-format.rkt")

(define human-format-tests
  (test-suite
   "human format, i18n and highlight"

   ;; i18n basics
   (test-case "language parameter and resolution"
     (check-equal? (current-language) 'en)
     (check-equal? (resolve-language "zh") 'zh)
     (check-equal? (resolve-language "ZH") 'zh)
     (check-equal? (resolve-language "en") 'en)
     (check-equal? (resolve-language "fr") #f)
     (check-equal? (resolve-language #f) #f))

   (test-case "msg switches by language"
     (check-equal? (parameterize ([current-language 'en]) (msg 'validate-ok))
                   "✓ Valid syntax\n")
     (check-equal? (parameterize ([current-language 'zh]) (msg 'validate-ok))
                   "✓ 语法有效\n"))

   ;; explain: part types use contract names
   (test-case "explain part types"
     (define parts (explain-regex "\\d+"))
     (check-equal? (hash-ref (car parts) 'type) "quantifier")
     (check-equal? (hash-ref (car parts) 'raw) "\\d+")
     (define parts2 (explain-regex "(?=x)[a-z]{2}"))
     (check-equal? (hash-ref (car parts2) 'type) "lookaround")
     (check-equal? (hash-ref (cadr parts2) 'type) "quantifier")
     (define parts3 (explain-regex "(a)\\1"))
     (check-equal? (hash-ref (car parts3) 'type) "group")
     (check-equal? (hash-ref (cadr parts3) 'type) "backref")
     (define parts4 (explain-regex "\\p{L}"))
     (check-equal? (hash-ref (car parts4) 'type) "unicode-class"))

   (test-case "explain descriptions in en and zh"
     (define en (explain-regex "\\d+"))
     (check-true (string-contains? (hash-ref (car en) 'description) "Digit"))
     (parameterize ([current-language 'zh])
       (define zh (explain-regex "\\d+"))
       (check-true (string-contains? (hash-ref (car zh) 'description) "数字"))))

   (test-case "explain degrades on unmodelable syntax"
     ;; pregexp-valid conditionals are beyond the visualizer
     (define parts (explain-regex "(x)?a(?(1)b|c)"))
     (check-equal? (length parts) 1)
     (check-equal? (hash-ref (car parts) 'type) "unsupported"))

   (test-case "ast raw reconstruction round-trips simple patterns"
     (for ([p (list "abc" "a|b" "\\d+" "[a-z]+" "(a|b)*c" "a{2,4}?" "(?:x)(?=y)" "\\1" "\\p{L}")])
       (define parts (explain-regex p))
       (check-equal? (string-join (map (lambda (part) (hash-ref part 'raw)) parts) "") p)))

   ;; highlight
   (test-case "highlight falls back without tty"
     (check-equal? (highlight-matches "hello" '()) "hello")
     (define listing (format-plain-matches "abc 123" '((4 . 7))))
     (check-true (string-contains? listing "4-7"))
     (check-true (string-contains? listing "123")))

   (test-case "ansi highlighting writes escapes"
     (define out (highlight-with-ansi "abc 123" '((4 . 7))))
     (check-true (string-contains? out "\033[32m"))
     (check-true (string-contains? out "123")))))

(provide human-format-tests)
