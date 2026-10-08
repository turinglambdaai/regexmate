#lang racket

;; Static risk analysis on the pattern AST. Deterministic rules only —
;; no execution, no heuristics that pretend to be sure. Findings are
;; advisory: agents and CI decide what to do with them.
;;
;; Findings carry (rule position severity args); the human sentence is
;; rendered per rule from the bilingual templates in i18n.rkt, so the
;; teaching content reads natively in en and zh.

(require racket/match
         "ast.rkt"
         "regex-parser.rkt"
         "i18n.rkt")

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

(struct warning (rule position severity args) #:transparent)

(define (lit-raw? s)
  (for/and ([c (in-string s)])
    (not (memq c '(#\\ #\. #\[ #\] #\( #\) #\{ #\} #\| #\* #\+ #\? #\^ #\$)))))

(define lint-port-keys
  (hasheq 'port-atomic 'lint-rule-port-atomic
          'port-flags 'lint-rule-port-flags
          'port-unicode 'lint-rule-port-unicode
          'port-backref 'lint-rule-port-backref
          'port-posix 'lint-rule-port-posix))

(define (translate-lint-arg a)
  (if (symbol? a)
      (or (lint-arg-text (string->symbol (format "lint-arg-~a" a)))
          (symbol->string a))
      a))

;; the finding's sentence in the current language
(define (warning-message w)
  (define args (warning-args w))
  (define port-key (and (pair? args) (hash-ref lint-port-keys (car args) #f)))
  (if port-key
      (lint-msg port-key)
      (apply lint-msg (lint-rule-key (warning-rule w))
             (map translate-lint-arg args))))

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
                    'warning
                    (list (if (re-lookaround? base) 'assertion 'anchor)))
           acc)]
         ;; ((a+)*) style nesting — catastrophic backtracking risk
         [(and (re-group? base)
               (re-quantifier? (re-group-child base))
               (quantifier-unbounded? 0 (re-quantifier-max (re-group-child base)))
               (quantifier-unbounded? 0 max))
          (cons
           (warning 'nested-quantifier
                    (pos-of pattern (ast->raw node))
                    'warning
                    '())
           acc)]
         [else acc]))
     (walk base pattern acc1)]
    [(re-lookaround _ _ child)
     (walk child pattern acc)]
    [(re-atomic child)
     (define acc1
       (if (or (re-literal? child) (re-char-class? child) (re-escape? child))
           (cons (warning 'redundant-atomic
                          (pos-of pattern (ast->raw node))
                          'info
                          '())
                 acc)
           acc))
     (walk child pattern
           (cons (portability-warning pattern node 'port-atomic)
                 acc1))]
    [(re-group child _ _ flags)
     (define acc1
       (if flags
           (cons (portability-warning pattern node 'port-flags)
                 acc)
           acc))
     (walk child pattern acc1)]
    [(re-alternation left right)
     ;; flatten covers the whole right-nested chain, so check once here;
     ;; branches themselves contain no bare alternation nodes to re-walk
     (define branches (flatten-alt node))
     (define acc1 (check-branches branches pattern acc))
     (foldl (lambda (b acc2) (walk b pattern acc2)) acc1 branches)]
    [(re-sequence elems)
     (foldl (lambda (e acc2) (walk e pattern acc2)) acc elems)]
    ;; constructs that do not survive the trip to other engines
    [(re-unicode-class _ _)
     (cons (portability-warning pattern node 'port-unicode)
           acc)]
    [(re-backref _)
     (cons (portability-warning pattern node 'port-backref)
           acc)]
    [(re-char-class items _)
     (foldl (lambda (item acc2)
              (if (and (list? item) (eq? (car item) 'posix))
                  (cons (portability-warning pattern node 'port-posix)
                        acc2)
                  acc2))
            acc items)]
    [_ acc]))

;; info-level note: this construct will not behave the same in every engine
(define (portability-warning pattern node note-id)
  (warning 'portability
           (pos-of pattern (ast->raw node))
           'info
           (list note-id)))

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
                                   'warning
                                   (list (add1 i)))
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
                                                   'info
                                                   (list (add1 i) (add1 j)))
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
                                                        'warning
                                                        (list (add1 i) ri (add1 j) rj))
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

;; JSON-ready form; the message sentence follows the current language
(define (warning->jsexpr pattern w)
  (hasheq 'rule (symbol->string (warning-rule w))
          'position (warning-position w)
          'severity (symbol->string (warning-severity w))
          'message (warning-message w)))

(define (lint-regex-json pattern)
  (map (lambda (w) (warning->jsexpr pattern w)) (lint-regex pattern)))

(provide lint-regex lint-regex-json (struct-out warning))
