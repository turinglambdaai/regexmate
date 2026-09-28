#lang racket

;; Static risk analysis on the pattern AST. Deterministic rules only —
;; no execution, no heuristics that pretend to be sure. Findings are
;; advisory: agents and CI decide what to do with them.

(require racket/match
         "ast.rkt"
         "regex-parser.rkt")

;; first index of needle in haystack, or #f
(define (substring-index needle haystack)
  (define n (string-length needle))
  (let loop ([k 0])
    (cond
      [(> (+ k n) (string-length haystack)) #f]
      [(equal? (substring haystack k (+ k n)) needle) k]
      [else (loop (add1 k))])))

;; raw text of a node, for approximate source positions
(require "../output/human-format.rkt") ; ast->raw lives with the explainers

(struct warning (rule position message severity) #:transparent)

(define (lit-raw? s)
  (for/and ([c (in-string s)])
    (not (memq c '(#\\ #\. #\[ #\] #\( #\) #\{ #\} #\| #\* #\+ #\? #\^ #\$)))))

;; find approximate position of raw in the source pattern
(define (pos-of pattern raw)
  (or (and raw (string-contains? pattern raw)
           (substring-index raw pattern))
      0))

;; alternation chains are right-nested; flatten to a branch list
(define (flatten-alt node)
  (match node
    [(re-alternation left right)
     (append (flatten-alt left) (flatten-alt right))]
    [_ (list node)]))

;; only unbounded repetition can backtrack exponentially
(define (quantifier-unbounded? min max)
  (eq? max #f))

;; walk the AST collecting warnings
(define (walk node pattern acc)
  (match node
    [(re-quantifier base _ max _)
     (define acc1
       (cond
         ;; quantified lookaround/anchor: no-op or a bug
         [(or (re-lookaround? base) (re-anchor? base))
          (cons
           (warning 'quantified-assertion
                    (pos-of pattern (ast->raw node))
                    (format "quantifier applied to ~a — it matches no text, so the quantifier has no effect or hides a bug"
                            (if (re-lookaround? base) "an assertion" "an anchor"))
                    'warning)
           acc)]
         ;; ((a+)*) style nesting — catastrophic backtracking risk
         [(and (re-group? base)
               (re-quantifier? (re-group-child base))
               (quantifier-unbounded? 0 (re-quantifier-max (re-group-child base)))
               (quantifier-unbounded? 0 max))
          (cons
           (warning 'nested-quantifier
                    (pos-of pattern (ast->raw node))
                    "nested quantifiers over a group can backtrack catastrophically on non-matching input"
                    'warning)
           acc)]
         [else acc]))
     (walk base pattern acc1)]
    [(re-group child _ _ _)
     (walk child pattern acc)]
    [(re-lookaround _ _ child)
     (walk child pattern acc)]
    [(re-atomic child)
     (walk child pattern acc)]
    [(re-alternation left right)
     ;; flatten covers the whole right-nested chain, so check once here;
     ;; branches themselves contain no bare alternation nodes to re-walk
     (define branches (flatten-alt node))
     (define acc1 (check-branches branches pattern acc))
     (foldl (lambda (b acc2) (walk b pattern acc2)) acc1 branches)]
    [(re-sequence elems)
     (foldl (lambda (e acc2) (walk e pattern acc2)) acc elems)]
    [_ acc]))

;; duplicate, empty, and shadowing branches
(define (check-branches branches pattern acc)
  (define raws (map (lambda (b) (ast->raw b)) branches))
  (let loop ([i 0] [acc acc])
    (if (>= i (length branches))
        acc
        (let* ([ri (list-ref raws i)]
               [acc-empty
                (if (string=? ri "")
                    (cons (warning 'empty-branch
                                   (pos-of pattern ri)
                                   (format "alternative ~a is empty — it matches the empty string, usually a bug" (add1 i))
                                   'warning)
                          acc)
                    acc)]
               [acc-dup
                (let dup-loop ([j 0] [a acc-empty])
                  (if (>= j i)
                      a
                      (dup-loop (add1 j)
                                (if (string=? ri (list-ref raws j))
                                    (cons (warning 'duplicate-branch
                                                   (pos-of pattern ri)
                                                   (format "alternative ~a duplicates alternative ~a" (add1 i) (add1 j))
                                                   'info)
                                          a)
                                    a))))]
               ;; later literal branch starts with an earlier literal branch:
               ;; the later one can never win when the earlier is tried first
               [acc-shadow
                (let shadow-loop ([j 0] [a acc-dup])
                  (if (>= j i)
                      a
                      (shadow-loop (add1 j)
                                   (let ([rj (list-ref raws j)])
                                     (if (and (> (string-length ri) (string-length rj))
                                              (lit-raw? ri) (lit-raw? rj)
                                              (string-prefix? ri rj))
                                         (cons (warning 'shadowed-branch
                                                        (pos-of pattern ri)
                                                        (format "alternative ~a (~s) can never match: earlier alternative ~a (~s) always matches its prefix first"
                                                                (add1 i) ri (add1 j) rj)
                                                        'warning)
                                               a)
                                         a)))))])
          (loop (add1 i) acc-shadow)))))

;; pattern -> warnings (ordered by position)
(define (lint-regex pattern)
  (define ast (car (parse-regex-safe pattern)))
  (if (not ast)
      '()
      (sort (walk ast pattern '())
            <
            #:key (lambda (w) (warning-position w)))))

;; JSON-ready form
(define (warning->jsexpr pattern w)
  (hasheq 'rule (symbol->string (warning-rule w))
          'position (warning-position w)
          'severity (symbol->string (warning-severity w))
          'message (warning-message w)))

(define (lint-regex-json pattern)
  (map (lambda (w) (warning->jsexpr pattern w)) (lint-regex pattern)))

(provide lint-regex lint-regex-json (struct-out warning))
