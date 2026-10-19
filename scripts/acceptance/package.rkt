#lang racket/base

(require json racket/file racket/path racket/system)

(define platform
  (case (system-type 'os)
    [(windows) "windows"]
    [(macosx) "macos"]
    [(unix) "linux"]
    [else (error 'regexmate-acceptance "unsupported platform")]))
(define raco
  (or (find-executable-path "raco")
      (error 'regexmate-acceptance "raco was not found")))
(unless (system* raco "rivet" "package" "--skip-launch-smoke")
  (error 'regexmate-acceptance "raco rivet package failed"))
(define output-directory
  (build-path (current-directory) ".rivet" "acceptance" platform))
(make-directory* output-directory)
(call-with-output-file (build-path output-directory "package.json")
  #:exists 'truncate/replace
  (lambda (output)
    (write-json (hash 'platform platform
                      'package-verified #t
                      'source "raco rivet package --skip-launch-smoke")
                output)
    (newline output)))
