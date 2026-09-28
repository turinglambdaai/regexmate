#lang racket

(require rackunit
         "../core/regex-parser.rkt"
         "../core/ast.rkt")

(define regex-parser-tests
  (test-suite
   "regex parser"

   ;; atoms
   (test-case "atoms"
     (check-equal? (parse-regex "a") (re-literal #\a))
     (check-equal? (parse-regex ".") (re-any))
     (check-equal? (parse-regex "^") (re-anchor 'start))
     (check-equal? (parse-regex "$") (re-anchor 'end)))

   ;; quantifiers
   (test-case "quantifiers"
     (check-equal? (parse-regex "a*") (re-quantifier (re-literal #\a) 0 #f #t))
     (check-equal? (parse-regex "a+") (re-quantifier (re-literal #\a) 1 #f #t))
     (check-equal? (parse-regex "a?") (re-quantifier (re-literal #\a) 0 1 #t))
     (check-equal? (parse-regex "a*?") (re-quantifier (re-literal #\a) 0 #f #f))
     (check-equal? (parse-regex "a+?") (re-quantifier (re-literal #\a) 1 #f #f))
     (check-equal? (parse-regex "a??") (re-quantifier (re-literal #\a) 0 1 #f))
     (check-equal? (parse-regex "a{3}") (re-quantifier (re-literal #\a) 3 3 #t))
     (check-equal? (parse-regex "a{2,}") (re-quantifier (re-literal #\a) 2 #f #t))
     (check-equal? (parse-regex "a{2,5}?") (re-quantifier (re-literal #\a) 2 5 #f))
     (check-equal? (parse-regex "\t*") (re-quantifier (re-literal #\tab) 0 #f #t)))

   ;; sequences and alternation
   (test-case "sequences and alternation"
     (check-equal? (parse-regex "abc")
                   (re-sequence (list (re-literal #\a) (re-literal #\b) (re-literal #\c))))
     (check-equal? (parse-regex "a|b")
                   (re-alternation (re-literal #\a) (re-literal #\b)))
     (check-equal? (parse-regex "ab|cd")
                   (re-alternation (re-sequence (list (re-literal #\a) (re-literal #\b)))
                                   (re-sequence (list (re-literal #\c) (re-literal #\d)))))
     (check-equal? (parse-regex "") (re-sequence '())))

   ;; character classes
   (test-case "character classes"
     (check-equal? (parse-regex "[abc]")
                   (re-char-class (list #\a #\b #\c) #f))
     (check-equal? (parse-regex "[^a-z]")
                   (re-char-class (list (cons #\a #\z)) #t))
     (check-equal? (parse-regex "[a-]")
                   (re-char-class (list #\a #\-) #f))
     (check-equal? (parse-regex "[\\d]")
                   (re-char-class (list (list 'class 'digit)) #f))
     (check-equal? (parse-regex "[[:alpha:][:digit:]]")
                   (re-char-class (list (list 'posix 'alpha) (list 'posix 'digit)) #f))
     (check-equal? (parse-regex "[\\]]")
                   (re-char-class (list #\]) #f)))

   ;; escapes
   (test-case "escapes"
     (check-equal? (parse-regex "\\d") (re-escape 'digit))
     (check-equal? (parse-regex "\\D") (re-escape 'non-digit))
     (check-equal? (parse-regex "\\w") (re-escape 'word))
     (check-equal? (parse-regex "\\s") (re-escape 'space))
     (check-equal? (parse-regex "\\b") (re-escape 'word-boundary))
     (check-equal? (parse-regex "\\B") (re-escape 'non-word-boundary))
     (check-equal? (parse-regex "\\n") (re-literal #\newline))
     (check-equal? (parse-regex "\\\\") (re-literal #\\))
     (check-equal? (parse-regex "\\1") (re-backref 1))
     (check-equal? (parse-regex "\\9") (re-backref 9))
     (check-equal? (parse-regex "\\p{L}") (re-unicode-class 'L #f))
     (check-equal? (parse-regex "\\P{L}") (re-unicode-class 'L #t))
     (check-equal? (parse-regex "\\p{Greek}") (re-unicode-class 'Greek #f))
     (check-equal? (parse-regex "a\\zb")
                   (re-sequence (list (re-literal #\a) (re-literal #\z) (re-literal #\b)))))

   ;; groups
   (test-case "groups"
     (check-equal? (parse-regex "(a)") (re-group (re-literal #\a) #t #f #f))
     (check-equal? (parse-regex "(?:a)") (re-group (re-literal #\a) #f #f #f))
     (check-equal? (parse-regex "(?i:a)") (re-group (re-literal #\a) #f #f "i"))
     (check-equal? (parse-regex "(?is:a)") (re-group (re-literal #\a) #f #f "is"))
     (check-equal? (parse-regex "(?-i:a)") (re-group (re-literal #\a) #f #f "-i")))

   ;; lookarounds and atomic groups
   (test-case "lookarounds and atomic groups"
     (check-equal? (parse-regex "(?=a)") (re-lookaround 'ahead #f (re-literal #\a)))
     (check-equal? (parse-regex "(?!a)") (re-lookaround 'ahead #t (re-literal #\a)))
     (check-equal? (parse-regex "(?<=a)") (re-lookaround 'behind #f (re-literal #\a)))
     (check-equal? (parse-regex "(?<!a)") (re-lookaround 'behind #t (re-literal #\a)))
     (check-equal? (parse-regex "(?>a+)") (re-atomic (re-quantifier (re-literal #\a) 1 #f #t))))

   ;; misc
   (test-case "misc"
     (check-equal? (parse-regex "{") (re-literal #\{))
     (define empty-group (parse-regex "()"))
     (check-true (re-group? empty-group))
     (check-equal? (re-group-child empty-group) (re-sequence '())))

   ;; safe wrapper
   (test-case "parse-regex-safe"
     (check-equal? (parse-regex-safe "a") (cons (re-literal #\a) #f))
     (check-true (re-group? (car (parse-regex-safe "(?<x>a)"))))  ; named group parses (defensive)
     (check-false (car (parse-regex-safe "(")))       ; unbalanced paren -> error path
     (check-true (string? (cdr (parse-regex-safe "(")))))))

(provide regex-parser-tests)
