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

(define results (run-tests all-tests))

(displayln "=== done ===")

;; run-tests returns (tests passed failed errored) in rackunit/text-ui
(if (and (list? results) (= 0 (list-ref results 2) (list-ref results 3)))
    (exit 0)
    (exit 1))
