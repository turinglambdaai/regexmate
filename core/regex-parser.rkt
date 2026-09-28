#lang racket

(require racket/match
         "ast.rkt")

;; Recursive-descent regex parser: pattern string -> AST.
;; Syntax surface is aligned with Racket's pregexp engine (verified on 9.2):
;;   supported: . ^ $ | () (?:) (?=) (?!) (?<=) (?<!) (?>) (?i:) (?is:) (?-i:)
;;              * + ? {n} {n,} {n,m} with lazy ?, [..] ranges/negation,
;;              [:alpha:] POSIX classes, \d \D \w \W \s \S \b \B, \n \t \r,
;;              \\, \1-\9 backrefs, \p{..} \P{..} unicode classes
;;   not supported by pregexp (validator rejects before we ever parse):
;;              (?<name>..) named groups, \A \z, \x41, (?i) without colon
;; parse-regex-safe wraps parse failures for graceful explain/graph fallback.

(define (parse-regex str)
  (define pos 0)
  (define len (string-length str))

  (define (peek) (and (< pos len) (string-ref str pos)))

  ;; char at offset k from current position, or #f
  (define (peek-at k)
    (define i (+ pos k))
    (and (< i len) (string-ref str i)))

  (define (advance) (begin0 (peek) (set! pos (add1 pos))))

  (define (at-end?) (>= pos len))

  (define (expect c)
    (unless (and (peek) (char=? (peek) c))
      (error 'parse-regex "expected '~a' at position ~a in ~v" c pos str))
    (advance))

  ;; top level: alternation
  (define (parse-alt)
    (define left (parse-seq))
    (cond
      [(and (peek) (char=? (peek) #\|))
       (advance)
       (re-alternation left (parse-alt))]
      [else left]))

  ;; sequence: concatenation of quantified atoms
  (define (parse-seq)
    (define elems
      (let loop ()
        (cond
          [(or (at-end?)
               (and (peek) (char=? (peek) #\)))
               (and (peek) (char=? (peek) #\|)))
           '()]
          [else
           (define q (parse-quantified))
           (if q (cons q (loop)) '())])))
    (match elems
      ['() (re-sequence '())]
      [(list single) single]
      [_ (re-sequence elems)]))

  ;; quantified atom
  (define (parse-quantified)
    (define atom (parse-atom))
    (cond
      [(not atom) #f]
      [(at-end?) atom]
      [(memq (peek) '(#\? #\* #\+))
       (parse-quantifier-spec atom)]
      [(and (char=? (peek) #\{) (peek-digit? 1))
       (parse-counted-quantifier atom)]
      [else atom]))

  (define (peek-digit? k)
    (define c (peek-at k))
    (and c (char-numeric? c)))

  (define (parse-quantifier-spec base)
    (case (peek)
      [(#\?)
       (advance)
       (if (and (not (at-end?)) (char=? (peek) #\?))
           (begin (advance) (re-quantifier base 0 1 #f))
           (re-quantifier base 0 1 #t))]
      [(#\*)
       (advance)
       (if (and (not (at-end?)) (char=? (peek) #\?))
           (begin (advance) (re-quantifier base 0 #f #f))
           (re-quantifier base 0 #f #t))]
      [(#\+)
       (advance)
       (if (and (not (at-end?)) (char=? (peek) #\?))
           (begin (advance) (re-quantifier base 1 #f #f))
           (re-quantifier base 1 #f #t))]
      [else base]))

  ;; {n} {n,m} {n,}
  (define (parse-counted-quantifier base)
    (advance) ; consume {
    (define n (parse-number))
    (define-values (min-val max-val)
      (cond
        [(and (peek) (char=? (peek) #\,))
         (advance)
         (if (and (peek) (char-numeric? (peek)))
             (values n (parse-number))
             (values n #f))]
        [else (values n n)]))
    (expect #\})
    (define greedy?
      (if (and (not (at-end?)) (char=? (peek) #\?))
          (begin (advance) #f)
          #t))
    (re-quantifier base min-val max-val greedy?))

  (define (parse-number)
    (define chars
      (let loop ()
        (if (and (peek) (char-numeric? (peek)))
            (cons (advance) (loop))
            '())))
    (if (null? chars)
        0
        (string->number (list->string chars))))

  ;; single atom
  (define (parse-atom)
    (cond
      [(at-end?) #f]
      [(char=? (peek) #\.) (advance) (re-any)]
      [(char=? (peek) #\^) (advance) (re-anchor 'start)]
      [(char=? (peek) #\$) (advance) (re-anchor 'end)]
      [(char=? (peek) #\() (parse-group)]
      [(char=? (peek) #\[) (parse-char-class)]
      [(char=? (peek) #\\) (parse-escape)]
      [(memq (peek) '(#\? #\* #\+ #\| #\))) #f]
      ;; '{' only reaches here when not a valid quantifier opener;
      ;; pregexp rejects such patterns anyway, keep parsing as literal
      [(char=? (peek) #\{) (re-literal (advance))]
      [else (re-literal (advance))]))

  ;; groups: (...) (?:...) (?=..) (?!..) (?<=..) (?<!..) (?>..)
  ;;         (?i:...) (?is:...) (?-i:...) and (?<name>...) accepted defensively
  (define (parse-group)
    (advance) ; consume (
    (define-values (kind name flags)
      (cond
        [(and (peek) (char=? (peek) #\?))
         (advance)
         (cond
           [(and (peek) (char=? (peek) #\:))
            (advance) (values 'noncapture #f #f)]
           [(and (peek) (char=? (peek) #\=))
            (advance) (values 'lookahead-pos #f #f)]
           [(and (peek) (char=? (peek) #\!))
            (advance) (values 'lookahead-neg #f #f)]
           [(and (peek) (char=? (peek) #\<) (peek-at 1)
                 (memq (peek-at 1) '(#\= #\!)))
            (advance) ; <
            (define neg? (char=? (advance) #\!))
            (values (if neg? 'lookbehind-neg 'lookbehind-pos) #f #f)]
           [(and (peek) (char=? (peek) #\>))
            (advance) (values 'atomic #f #f)]
           ;; (?i: (?is: (?-i: ...) — letters and dashes up to ':'
           [(and (peek) (let ([c (peek)])
                          (or (char-alphabetic? c) (char=? c #\-))))
            (define fl (parse-flag-chars))
            (unless (and (peek) (char=? (peek) #\:))
              (error 'parse-regex "unsupported group flags at position ~a in ~v" pos str))
            (advance)
            (values 'flags #f fl)]
           ;; (?<name> — pregexp rejects it, kept for graceful explanation
           [(and (peek) (char=? (peek) #\<))
            (advance)
            (values 'named (parse-group-name) #f)]
           [else
            (error 'parse-regex "unsupported group syntax at position ~a in ~v" pos str)])]
        [else (values 'capture #f #f)]))
    (define child (parse-alt))
    (expect #\))
    (case kind
      [(capture) (re-group child #t #f #f)]
      [(named) (re-group child #t name #f)]
      [(noncapture flags) (re-group child #f #f flags)]
      [(atomic) (re-atomic child)]
      [(lookahead-pos) (re-lookaround 'ahead #f child)]
      [(lookahead-neg) (re-lookaround 'ahead #t child)]
      [(lookbehind-pos) (re-lookaround 'behind #f child)]
      [(lookbehind-neg) (re-lookaround 'behind #t child)]
      [else (error 'parse-regex "internal: unknown group kind ~a" kind)]))

  ;; flag letters/dashes: "i", "is", "-i", "im-s" ...
  (define (parse-flag-chars)
    (define chars
      (let loop ()
        (if (and (peek)
                 (or (char-alphabetic? (peek)) (char=? (peek) #\-)))
            (cons (advance) (loop))
            '())))
    (list->string chars))

  (define (parse-group-name)
    (define chars
      (let loop ()
        (if (and (peek) (not (char=? (peek) #\>)))
            (cons (advance) (loop))
            '())))
    (when (and (peek) (char=? (peek) #\>)) (advance))
    (list->string chars))

  ;; char class: [abc] [a-z] [^a-z] [\d\s] [[:alpha:]] [a-]
  (define (parse-char-class)
    (advance) ; consume [
    (define negated?
      (if (and (peek) (char=? (peek) #\^))
          (begin (advance) #t)
          #f))
    (define items (parse-class-items))
    (expect #\])
    (re-char-class items negated?))

  (define (parse-class-items)
    (let loop ()
      (cond
        [(at-end?) '()]
        [(char=? (peek) #\]) '()]
        ;; POSIX class [:alpha:] / [:digit:] ...
        [(and (char=? (peek) #\[) (char=? (or (peek-at 1) #\#) #\:))
         (define name (parse-posix-class))
         (cons (list 'posix name) (loop))]
        [else
         (define c (parse-class-atom))
         (cond
           ;; range a-z (dash must be followed by a non-] char);
           ;; symbolic items like \d can't be range endpoints, dash stays literal
           [(and (char? c)
                 (peek) (char=? (peek) #\-) (peek-at 1) (not (char=? (peek-at 1) #\])))
            (advance) ; -
            (define end-c (parse-class-atom))
            (if (char? end-c)
                (cons (cons c end-c) (loop))
                (list* c #\- end-c (loop)))]
           ;; trailing dash is literal
           [(and (peek) (char=? (peek) #\-) (peek-at 1) (char=? (peek-at 1) #\]))
            (advance)
            (cons c (cons #\- (loop)))]
           [else (cons c (loop))])])))

  (define (parse-posix-class)
    (advance) ; [
    (advance) ; :
    (define chars
      (let loop ()
        (if (and (peek) (not (char=? (peek) #\:)))
            (cons (advance) (loop))
            '())))
    (when (and (peek) (char=? (peek) #\:)) (advance))
    (expect #\])
    (string->symbol (list->string chars)))

  ;; atom inside a char class: escapes collapse to plain chars here,
  ;; except \d-family which stays symbolic so explain can name it
  (define (parse-class-atom)
    (cond
      [(char=? (peek) #\\)
       (advance)
       (case (peek)
         [(#\n) (advance) #\newline]
         [(#\t) (advance) #\tab]
         [(#\r) (advance) #\return]
         [(#\\) (advance) #\\]
         [(#\]) (advance) #\]]
         [(#\[) (advance) #\[]
         [(#\-) (advance) #\-]
         [(#\d) (advance) (list 'class 'digit)]
         [(#\D) (advance) (list 'class 'non-digit)]
         [(#\w) (advance) (list 'class 'word)]
         [(#\W) (advance) (list 'class 'non-word)]
         [(#\s) (advance) (list 'class 'space)]
         [(#\S) (advance) (list 'class 'non-space)]
         [else (advance)])]
      [else (advance)]))

  ;; escape sequences outside classes
  (define (parse-escape)
    (advance) ; consume \
    (define c (advance))
    (case c
      [(#\d) (re-escape 'digit)]
      [(#\D) (re-escape 'non-digit)]
      [(#\w) (re-escape 'word)]
      [(#\W) (re-escape 'non-word)]
      [(#\s) (re-escape 'space)]
      [(#\S) (re-escape 'non-space)]
      [(#\b) (re-escape 'word-boundary)]
      [(#\B) (re-escape 'non-word-boundary)]
      [(#\n) (re-literal #\newline)]
      [(#\t) (re-literal #\tab)]
      [(#\r) (re-literal #\return)]
      [(#\\) (re-literal #\\)]
      ;; backreferences \1-\9
      [(#\1 #\2 #\3 #\4 #\5 #\6 #\7 #\8 #\9)
       (re-backref (string->number (string c)))]
      ;; unicode classes \p{L} \P{L} \p{Greek}
      [(#\p #\P)
       (if (and (peek) (char=? (peek) #\{))
           (let ()
             (advance)
             (define name (parse-braced-name))
             (re-unicode-class name (char=? c #\P)))
           (re-literal c))]
      [else (re-literal c)]))

  (define (parse-braced-name)
    (define chars
      (let loop ()
        (if (and (peek) (not (char=? (peek) #\})))
            (cons (advance) (loop))
            '())))
    (expect #\})
    (string->symbol (list->string chars)))

  ;; run the parse
  (if (string=? str "")
      (re-sequence '())
      (parse-alt)))

;; Safe variant: returns (cons ast #f) on success or (cons #f message) on failure.
;; explain/graph use this to degrade gracefully on syntax our parser
;; does not model (pregexp still handles the matching itself).
(define (parse-regex-safe str)
  (with-handlers ([exn:fail? (lambda (e) (cons #f (exn-message e)))])
    (cons (parse-regex str) #f)))

(provide parse-regex parse-regex-safe)
