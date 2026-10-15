#lang racket

;; Release gate: every place that states a version must agree — the VERSION
;; file, info.rkt, version.rkt, rivet.rktd, and the version badge in both
;; READMEs — and the git tag (when releasing) must agree too. The README
;; badge is checked because it is the one version reference that no build
;; step regenerates: it drifts exactly when a release forgets it.
;;   racket scripts/check-version.rkt           -> internal consistency only
;;   racket scripts/check-version.rkt v1.2.3    -> tag must match too

(require racket/file)

(define (info-version)
  (define in (open-input-file "info.rkt"))
  (define text (port->string in))
  (close-input-port in)
  (define m (regexp-match #px"\\(define version \"([^\"]+)\"\\)" text))
  (or (and m (cadr m))
      (error 'check-version "no (define version \"...\") found in info.rkt")))

(define (module-version)
  (dynamic-require "version.rkt" 'regexmate-version))

(define (file-version)
  (string-trim (file->string "VERSION")))

(define (rktd-version)
  (define v (hash-ref (file->value "rivet.rktd") 'version))
  (if (string? v) v (error 'check-version "rivet.rktd version is not a string: ~s" v)))

;; the shields.io version badge in a README, e.g. .../badge/version-1.2.3-037A55
(define (readme-badge path)
  (define m (regexp-match #rx"shields\\.io/badge/version-([0-9]+\\.[0-9]+\\.[0-9]+)"
                          (file->string path)))
  (or (and m (cadr m))
      (error 'check-version "no version badge found in ~a" path)))

(define given-tag
  (let ([args (vector->list (current-command-line-arguments))])
    (and (not (null? args)) (car args))))

(define iv (info-version))

(define (must-agree where value)
  (unless (and (string? value) (string=? iv value))
    (fprintf (current-error-port)
             "check-version: ~a has ~s but info.rkt has ~s\n" where value iv)
    (exit 1)))

(must-agree "version.rkt" (module-version))
(must-agree "VERSION" (file-version))
(must-agree "rivet.rktd" (rktd-version))
(must-agree "README.md" (readme-badge "README.md"))
(must-agree "README.zh-CN.md" (readme-badge "README.zh-CN.md"))

(when given-tag
  (define expected (string-append "v" iv))
  (unless (string=? given-tag expected)
    (fprintf (current-error-port)
             "check-version: tag ~s does not match repository version ~s\n"
             given-tag expected)
    (exit 1)))

(printf "check-version: ok (version ~a)\n" iv)
