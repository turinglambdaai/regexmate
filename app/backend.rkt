#lang racket/base

;; RegexMate desktop backend — the same core modules the CLI uses,
;; exposed to the native WinUI 3 host over the RVT1 bridge:
;;   status      pattern validity (single-line error or "ok")
;;   match-rows  matches as rows: value, start, end, group count
;;   explain     plain-language explanation text
;;   diagram-png railroad diagram rendered to PNG bytes

(require rivet/backend
         racket/class
         racket/draw
         racket/match
         racket/port
         pict
         "../core/ast.rkt"
         "../core/regex-engine.rkt"
         "../core/regex-parser.rkt"
         "../core/linter.rkt"
         "../output/human-format.rkt"
         "../output/report.rkt"
         "../output/railroad.rkt"
         "../version.rkt")

(provide start)

(define (first-error pattern)
  (and (not (valid-regex? pattern)) (get-regex-error pattern)))

(define-rpc (status [pattern String] : String)
  (or (first-error pattern) "ok"))

(define-rpc (match-rows [pattern String] [text String] : (List (List String)))
  (if (first-error pattern)
      '()
      (for/list ([m (in-list (find-all-matches pattern text))])
        (match-define (cons span groups) m)
        (list (substring text (car span) (cdr span))
              (number->string (car span))
              (number->string (cdr span))
              (number->string (length groups))))))

(define-rpc (explain-text [pattern String] : String)
  (if (first-error pattern)
      ""
      (format-explain-human pattern (explain-regex pattern))))

;; railroad diagram rendered to PNG. diagram-png yields the bytes (empty on
;; failure); diagram-diag yields a staged diagnostic (empty on success) so the
;; host can surface embedded-runtime drawing problems instead of a blank pane.
(define-rpc (diagram-png [pattern String] : Bytes)
  (call-with-diagram pattern
                     (lambda (png diag) png)))

(define-rpc (lint-rows [pattern String] : (List (List String)))
  (for/list ([w (in-list (lint-regex-json pattern))])
    (list (hash-ref w 'severity)
          (hash-ref w 'rule)
          (number->string (hash-ref w 'position))
          (hash-ref w 'message))))

(define-rpc (report-html [pattern String] [text String] : String)
  (define rows
    (if (first-error pattern)
        '()
        (for/list ([m (in-list (find-all-matches pattern text))])
          (match-define (cons span groups) m)
          (list (substring text (car span) (cdr span))
                (number->string (car span))
                (number->string (cdr span))
                (number->string (length groups))))))
  (define explain
    (if (first-error pattern) "" (format-explain-human pattern (explain-regex pattern))))
  (define lint (lint-regex-json pattern))
  (report-html pattern text rows explain lint #f
               (and (car (parse-regex-safe pattern))
                    (bytes->string/utf-8 (ast->svg (car (parse-regex-safe pattern))))))
  regexmate-version)

(define-rpc (diagram-diag [pattern String] : String)
  (call-with-diagram pattern
                     (lambda (png diag) diag)))

(define (call-with-diagram pattern consume)
  (with-handlers ([exn:fail?
                   (lambda (e) (consume #"" (format "EXC: ~a" (exn-message e))))])
    (define parsed (parse-regex-safe pattern))
    (define ast (car parsed))
    (unless ast (error 'diagram "pattern not modelable"))
    (define stages (open-output-string))
    (define (note s) (fprintf stages "[~a]" s))
    (note "pict")
    ;; Dense render with entry/exit tracks; cap the long side so pathological
    ;; patterns stay within bitmap memory limits.
    (define base (railroad-pict ast))
    (define fit-scale (/ 4200.0 (max 1.0 (pict-width base))))
    (define p (scale base (min 8.0 (max 2.0 fit-scale))))
    (define w (max 1 (inexact->exact (ceiling (pict-width p)))))
    (define h (max 1 (inexact->exact (ceiling (pict-height p)))))
    (note (format "size:~ax~a" w h))
    (define bm (make-object bitmap% w h #f #t))
    (note "bitmap")
    (define dc (make-object bitmap-dc% bm))
    (send dc set-background (make-object color% 255 255 255))
    (send dc clear)
    (draw-pict p dc 0 0)
    (note "drawn")
    (send dc set-bitmap #f)
    (define out (open-output-bytes))
    (define saved (send bm save-file out 'png))
    (define png (get-output-bytes out))
    (note (format "saved:~a:~a" saved (bytes-length png)))
    (consume png (get-output-string stages))))

(define (start in-fd out-fd)
  ;; Force racket/draw + fontconfig to initialize here, in the single-threaded
  ;; boot phase. First touch during concurrent RPC serving hangs the embedded
  ;; runtime; eager init sidesteps that.
  (define warm (make-object bitmap% 8 8 #f #t))
  (define warm-dc (make-object bitmap-dc% warm))
  (send warm-dc clear)
  (send warm-dc set-bitmap #f)
  (serve-fds in-fd out-fd))
