#lang racket

;; Matching engine on top of Racket's pregexp. This module is the only
;; place that touches the regexp API; spans use [start, end) with
;; end exclusive and absolute string indices.

(define (compile-regex regex) (pregexp regex))

;; Test whether a pattern compiles
(define (valid-regex? regex)
  (with-handlers ([exn:fail? (lambda (e) #f)])
    (compile-regex regex)
    #t))

;; Compile error message, or #f when the pattern is valid.
;; pregexp messages are multi-line ("pregexp: ...\n  pattern: ...");
;; keep the first line and drop the engine prefix so the JSON contract
;; stays single-line friendly.
(define (get-regex-error regex)
  (with-handlers ([exn:fail? (lambda (e)
                               (define raw (exn-message e))
                               (define first-line (car (string-split raw "\n")))
                               (define stripped
                                 (if (string-prefix? first-line "pregexp: ")
                                     (substring first-line 9)
                                     first-line))
                               (string-trim stripped))])
    (compile-regex regex)
    #f))

;; A match record: overall span (start . end) plus one entry per capture
;; group — (start . end) or #f when that group did not participate.
(define (find-all-matches regex text)
  (define pat (compile-regex regex))
  (define len (string-length text))
  (let loop ([start 0] [acc '()])
    (if (> start len)
        (reverse acc)
        (let ([m (regexp-match-positions pat text start)])
          (if (not m)
              (reverse acc)
              (let* ([overall (car m)]
                     [s (car overall)]
                     [e (cdr overall)]
                     ;; advance past empty matches so the scan always moves
                     [next (if (= e s) (add1 e) e)])
                (loop next (cons (cons overall (cdr m)) acc))))))))

;; Replace all matches with an insertion template. Racket's insertion
;; syntax applies: \\1 references group 1, \\0 the whole match.
;; Returns (cons result-string replacement-count).
(define (replace-regex regex text insertion)
  (define pat (compile-regex regex))
  (define matches (find-all-matches regex text))
  (cons (regexp-replace* pat text insertion)
        (length matches)))

(provide valid-regex? get-regex-error find-all-matches replace-regex)
