#lang racket

;; ANSI highlighting for human match output.
;; Honors NO_COLOR; falls back to a plain position listing when
;; stdout is redirected.

(define ANSI-RED "\033[31m")
(define ANSI-GREEN "\033[32m")
(define ANSI-YELLOW "\033[33m")
(define ANSI-BOLD "\033[1m")
(define ANSI-RESET "\033[0m")

;; color enabled = real terminal AND user did not disable color
(define (color-enabled?)
  (and (terminal-port? (current-output-port))
       (not (getenv "NO_COLOR"))))

(define (tty?) (color-enabled?))

;; highlight matched spans; positions = list of (start . end)
(define (highlight-matches text positions)
  (cond
    [(null? positions) text]
    [(not (color-enabled?)) (format-plain-matches text positions)]
    [else (highlight-with-ansi text (sort positions < #:key car))]))

;; plain format (redirected output)
(define (format-plain-matches text positions)
  (define count (length positions))
  (define matches
    (for/list ([pos positions])
      (define start (car pos))
      (define end (cdr pos))
      (format "  at ~a-~a: \"~a\"" start end (substring text start end))))
  (string-append
   (format "Found ~a match(es):\n" count)
   (string-join matches "\n")))

;; ANSI highlight, positions must be sorted and non-overlapping
(define (highlight-with-ansi text sorted-positions)
  (define out (open-output-string))
  (let loop ([i 0] [remaining sorted-positions])
    (cond
      [(>= i (string-length text))
       (get-output-string out)]
      [(null? remaining)
       (write-string (substring text i) out)
       (get-output-string out)]
      [else
       (define pos (car remaining))
       (define start (car pos))
       (define end (cdr pos))
       (cond
         [(< i start)
          (write-string (substring text i start) out)
          (loop start remaining)]
         [(= i start)
          (write-string ANSI-BOLD out)
          (write-string ANSI-GREEN out)
          (write-string (substring text i (min end (string-length text))) out)
          (write-string ANSI-RESET out)
          (loop end (cdr remaining))]
         [else
          (loop i (cdr remaining))])])))

(provide highlight-matches tty? format-plain-matches color-enabled?
         highlight-with-ansi)
