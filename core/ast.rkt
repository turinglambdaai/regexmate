#lang racket

;; Regex AST data structures.
;; Node types map 1:1 to the JSON contract ("regexmate/v1") via node-type.

(struct re-literal (char) #:transparent)
(struct re-any () #:transparent)
(struct re-char-class (items negated?) #:transparent) ; items: char | (cons char char) | (list 'posix name) | (list 'class kind)
(struct re-anchor (type) #:transparent)               ; 'start | 'end | 'text-start | 'text-end
(struct re-quantifier (base min max greedy?) #:transparent)
(struct re-group (child capture? name flags) #:transparent) ; flags: #f or string like "i"
(struct re-lookaround (direction negated? child) #:transparent) ; direction: 'ahead | 'behind
(struct re-atomic (child) #:transparent)
(struct re-unicode-class (name negated?) #:transparent) ; \p{L} / \P{L}
(struct re-backref (index) #:transparent)
(struct re-flags (chars) #:transparent)               ; inline flags like (?is)
(struct re-alternation (left right) #:transparent)
(struct re-sequence (elements) #:transparent)
(struct re-escape (type) #:transparent)               ; 'digit 'non-digit 'word 'non-word 'space 'non-space 'word-boundary 'non-word-boundary

;; JSON-contract node type name (stable, agent-facing)
(define (node-type node)
  (cond
    [(re-literal? node) 'literal]
    [(re-any? node) 'any]
    [(re-char-class? node) 'char-class]
    [(re-anchor? node) 'anchor]
    [(re-quantifier? node) 'quantifier]
    [(re-group? node) 'group]
    [(re-lookaround? node) 'lookaround]
    [(re-atomic? node) 'atomic]
    [(re-unicode-class? node) 'unicode-class]
    [(re-backref? node) 'backref]
    [(re-flags? node) 'flags]
    [(re-alternation? node) 'alternation]
    [(re-sequence? node) 'sequence]
    [(re-escape? node) 'escape]))

;; Walk the AST in source order, assigning 1-based capture-group indices.
;; Returns (list group-count (hash index -> name-or-#f)).
(define (collect-groups node)
  (define names (make-hash))
  (define count 0)
  (let walk ([n node])
    (match n
      [(re-group child capture? _ _)
       (when capture?
         (set! count (add1 count))
         (hash-set! names count #f))
       (walk child)]
      [(re-quantifier base _ _ _) (walk base)]
      [(re-lookaround _ _ child) (walk child)]
      [(re-atomic child) (walk child)]
      [(re-alternation left right) (walk left) (walk right)]
      [(re-sequence elems) (for-each walk elems)]
      [_ (void)]))
  (values count names))

;; Second pass that fills in names (names are known only after a full
;; pass, so collect-groups pairs with this constructor).
(define (make-group-namer names)
  (define counter (box 0))
  (lambda ()
    (set-box! counter (add1 (unbox counter)))
    (hash-ref names (unbox counter) #f)))

(provide (struct-out re-literal)
         (struct-out re-any)
         (struct-out re-char-class)
         (struct-out re-anchor)
         (struct-out re-quantifier)
         (struct-out re-group)
         (struct-out re-lookaround)
         (struct-out re-atomic)
         (struct-out re-unicode-class)
         (struct-out re-backref)
         (struct-out re-flags)
         (struct-out re-alternation)
         (struct-out re-sequence)
         (struct-out re-escape)
         node-type
         collect-groups
         make-group-namer)
