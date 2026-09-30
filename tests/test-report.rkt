#lang racket/base

(require rackunit
         racket/string
         racket/port
         (file "../output/report.rkt"))

(define report-tests
  (test-suite
   "report"

   (test-case "html escaping"
     (check-equal? (html-escape "<a & b>") "&lt;a &amp; b&gt;"))

   (test-case "report contains sections and highlights matches"
     (define html
       (report-html "\\d+"
                    "abc 123"
                    (list (list "123" "4" "7" "0"))
                    "Pattern: \\d+\n\nComponents:\n  1. [quantifier] \\d+ ← Digit (\\d) × +"
                    '()
                    #f
                    "<svg id=\"d\"></svg>"
                    "0.2.1"))
     (check-true (string-contains? html "<mark>123</mark>"))
     (check-true (string-contains? html "RegexMate report"))
     (check-true (string-contains? html "<svg id=\"d\"></svg>"))
     (check-true (string-contains? html "0.2.1"))
     (check-false (string-contains? html "<h2>Lint findings</h2>"))
     (check-false (string-contains? html "<h2>Test cases</h2>")))

   (test-case "report escapes html in sample and pattern"
     (define html (report-html "<b>" "<i>" '() "" '() #f #f "0.2.1"))
     (check-true (string-contains? html "&lt;b&gt;"))
     (check-true (string-contains? html "&lt;i&gt;")))

   (test-case "lint and test tables render"
     (define lint (list (hasheq 'severity "warning"
                                'rule "nested-quantifier"
                                'position 0
                                'message "nested quantifiers")))
     (define tests (list (hasheq 'text "a1" 'expect "match" 'pass #t 'reason #f)
                         (hasheq 'text "zz" 'expect "match" 'pass #f
                                 'reason "expected a match but none was found")))
     (define html (report-html "(a+)+" "a1" '() "" lint tests #f "0.2.1"))
     (check-true (string-contains? html "<h2>Lint findings</h2>"))
     (check-true (string-contains? html "nested-quantifier"))
     (check-true (string-contains? html "<h2>Test cases</h2>"))
     (check-true (string-contains? html "PASS"))
     (check-true (string-contains? html "FAIL"))
     (check-true (string-contains? html "expected a match but none was found")))

   (test-case "invalid pattern surfaces the error"
     (define html (report-html "(" "text" '() "" '() "INVALID: missing closing parenthesis" #f "0.2.1"))
     (check-true (string-contains? html "invalid regex"))
     (check-true (string-contains? html "missing closing parenthesis")))

   (test-case "report renders to port as one document"
     (define out (open-output-bytes))
     (display (report-html "a" "a" '() "" '() #f #f "0.2.1") out)
     (define html (bytes->string/utf-8 (get-output-bytes out)))
     (check-true (string-prefix? html "<!DOCTYPE html>"))
     (check-true (string-contains? html "</body></html>"))))

(provide report-tests)
