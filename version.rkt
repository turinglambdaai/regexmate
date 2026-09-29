#lang racket/base

;; Runtime-facing version. Must stay in sync with `version` in info.rkt;
;; scripts/check-version.rkt enforces this on every tagged release.

(define regexmate-version "1.3.0")

(provide regexmate-version)
