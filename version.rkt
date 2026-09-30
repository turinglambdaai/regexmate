#lang racket/base

;; Runtime-facing version. Must stay in sync with `version` in info.rkt;
;; scripts/check-version.rkt enforces this on every tagged release.

(define regexmate-version "0.2.1")

(provide regexmate-version)
