#lang racket

(require rackunit
         rackunit/text-ui)

(require "tests/test-regex-engine.rkt")
(require "tests/test-regex-parser.rkt")
(require "tests/test-human-format.rkt")
(require "tests/test-json-format.rkt")

(define all-tests
  (test-suite
   "RegexMate test suite"
   regex-engine-tests
   regex-parser-tests
   human-format-tests
   json-format-tests))

(displayln "=== RegexMate tests ===")

;; run-tests returns the number of failed/errored checks (0 = all green)
(define results (run-tests all-tests))

(displayln "=== done ===")

(if (and (number? results) (zero? results))
    (exit 0)
    (exit 1))
