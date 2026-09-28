#lang racket

;; Release gate: info.rkt version, version.rkt version and the git tag
;; (when releasing) must all agree.
;;   racket scripts/check-version.rkt           -> internal consistency only
;;   racket scripts/check-version.rkt v1.2.3    -> tag must match too

(define (info-version)
  (define in (open-input-file "info.rkt"))
  (define text (port->string in))
  (close-input-port in)
  (define m (regexp-match #px"\\(define version \"([^\"]+)\"\\)" text))
  (or (and m (cadr m))
      (error 'check-version "no (define version \"...\") found in info.rkt")))

(define (module-version)
  (dynamic-require "version.rkt" 'regexmate-version))

(define given-tag
  (let ([args (vector->list (current-command-line-arguments))])
    (and (not (null? args)) (car args))))

(define iv (info-version))
(define mv (module-version))

(unless (string=? iv mv)
  (fprintf (current-error-port)
           "check-version: info.rkt has ~s but version.rkt has ~s\n" iv mv)
  (exit 1))

(when given-tag
  (define expected (string-append "v" iv))
  (unless (string=? given-tag expected)
    (fprintf (current-error-port)
             "check-version: tag ~s does not match repository version ~s\n"
             given-tag expected)
    (exit 1)))

(printf "check-version: ok (version ~a)\n" iv)
