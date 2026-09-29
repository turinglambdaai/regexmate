#lang racket/gui

;; RegexMate desktop GUI — the same core as the CLI (engine, explainer,
;; railroad renderer) behind a native window: pattern on top, test text
;; and matches on the left, explanation and diagram on the right.

(require pict
         racket/draw
         "core/regex-engine.rkt"
         "core/regex-parser.rkt"
         "core/ast.rkt"
         "output/human-format.rkt"
         "output/railroad.rkt"
         "version.rkt")

;; --version exits before any widget is created (headless smoke on CI)
(define args (vector->list (current-command-line-arguments)))
(when (member "--version" args)
  (printf "RegexMate ~a (GUI)\n" regexmate-version)
  (exit 0))

;; ---- shared state ---------------------------------------------------

(define diagram-pict #f)

;; ---- frame ----------------------------------------------------------

(define frame
  (new frame%
       [label (string-append "RegexMate " regexmate-version)]
       [width 980]
       [height 680]))

(define (refresh! btn evt)
  (define pattern (send pattern-field get-value))
  (define text (send text-editor get-text))
  ;; status
  (define-values (valid? err)
    (if (valid-regex? pattern)
        (values #t #f)
        (values #f (get-regex-error pattern))))
  ;; matches
  (define n 0)
  (when valid?
    (define matches (find-all-matches pattern text))
    (set! n (length matches))
    (define rows
      (for/list ([m matches] [i (in-naturals 1)])
        (match-define (cons span groups) m)
        (define value (substring text (car span) (cdr span)))
        (define shown (if (> (string-length value) 40)
                          (string-append (substring value 0 37) "...")
                          value))
        (format "  ~a. ~a   [~a-~a]   ~a group(s)"
                (~a i #:width 3) (~a shown #:min-width 40 #:pad-string " ")
                (car span) (cdr span) (length groups))))
    (define table (send match-list get-editor))
    (send table erase)
    (send table insert
          (if (null? rows)
              "  (no matches)"
              (string-join rows "
"))
          0)
    ;; explanation
    (define expl (send explain-canvas get-editor))
    (send expl erase)
    (send expl insert (format-explain-human pattern (explain-regex pattern)) 0)
    ;; diagram
    (set! diagram-pict
      (let ([parsed (parse-regex-safe pattern)])
        (and (car parsed) (ast->pict (car parsed))))))
  ;; status line
  (send status set-label
        (if valid?
            (format "~a match(es)  ·  regexmate ~a" n regexmate-version)
            (format "✗ invalid pattern: ~a" err)))
  (send diagram-canvas refresh))

;; ---- widgets --------------------------------------------------------

(define top (new horizontal-panel% [parent frame] [stretchable-height #f]))
(new message% [parent top] [label "Pattern"] [auto-resize #f])
(define pattern-field
  (new text-field%
       [parent top]
       [label #f]
       [init-value "\\d+"]
       [callback (lambda (f e) (when (eq? (send e get-event-type) 'text-field-enter) (refresh! f e)))]))
(new button% [parent top] [label "Refresh"] [callback refresh!])

(define status (new message% [parent frame] [label "Ready"] [auto-resize #t]))

(define main (new horizontal-panel% [parent frame] [spacing 8]))

;; left column: test text + matches
(define left (new vertical-panel% [parent main] [min-width 380]))
(new message% [parent left] [label "Test text"] [auto-resize #f])
(define text-editor (new text%))
(define text-canvas
  (new editor-canvas%
       [parent left]
       [editor text-editor]
       [min-height 140]))
(send text-editor insert "Order 12345 shipped on 2026-09-28 to zip 10115." 0)
(new message% [parent left] [label "Matches"] [auto-resize #f])
(define match-editor (new text%))
(define match-list
  (new editor-canvas%
       [parent left]
       [editor match-editor]
       [min-height 200]))
(send match-editor lock (not #t))
(send match-editor change-style (make-object style-delta% 'change-family 'modern))

;; right column: explanation + diagram
(define right (new vertical-panel% [parent main]))
(new message% [parent right] [label "Explanation"] [auto-resize #f])
(define explain-canvas
  (new editor-canvas%
       [parent right]
       [editor (new text%)]
       [min-height 180]
       [style '(no-hscroll)]))
(define diagram-message (new message% [parent right] [label "Railroad diagram"] [auto-resize #f]))
(define diagram-canvas
  (new canvas% [parent right]
       [paint-callback
        (lambda (c dc)
          (when diagram-pict
            (define cw (send c get-width))
            (define ch (send c get-height))
            (define pw (max 1.0 (pict-width diagram-pict)))
            (define ph (max 1.0 (pict-height diagram-pict)))
            (define s (min 3.0 (/ (- cw 16) pw) (/ (- ch 16) ph)))
            (define sp (scale diagram-pict (max 0.1 s)))
            (draw-pict sp dc
                       (quotient (- cw (inexact->exact (floor (pict-width sp)))) 2)
                       (quotient (- ch (inexact->exact (floor (pict-height sp)))) 2))))]))

(send frame show #t)
(refresh! #f #f)
