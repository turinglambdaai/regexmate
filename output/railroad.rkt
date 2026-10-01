#lang racket

(require pict
         file/convertible
         racket/draw
         racket/match
         "../core/ast.rkt"
         "../core/regex-parser.rkt")

;; Railroad diagram renderer: AST -> pict -> SVG bytes.

;; color theme — tuned to the RegexMate brand (green accent, quiet neutrals)
(define COLOR-NODE    (make-object color% 255 255 255))   ; white
(define COLOR-SPECIAL (make-object color% 224 243 234))   ; accent green tint
(define COLOR-CLASS   (make-object color% 224 240 247))   ; soft blue tint
(define COLOR-ANCHOR  (make-object color% 252 240 220))   ; soft amber tint
(define COLOR-ESCAPE  (make-object color% 224 243 234))   ; accent green tint
(define COLOR-GROUP   (make-object color% 3 122 85))      ; accent frame
(define COLOR-GROUP-NC (make-object color% 158 158 158))  ; gray frame
(define COLOR-LOOK    (make-object color% 2 132 199))     ; blue frame
(define COLOR-ATOMIC  (make-object color% 109 76 65))     ; brown frame
(define COLOR-BORDER  (make-object color% 51 51 51))      ; dark gray
(define COLOR-TRACK   (make-object color% 102 102 102))   ; gray
(define COLOR-QUANT   (make-object color% 102 102 102))   ; gray

;; node geometry
(define NODE-H 26)
(define NODE-PAD-X 8)
(define NODE-RADIUS 4)
(define TRACK-H 2)
(define GAP 4)
(define ALT-GAP 12)

;; rounded box with centered label
(define (node-box label [bg-color COLOR-NODE])
  (define txt (text label 'default 12))
  (define w (+ (pict-width txt) (* NODE-PAD-X 2)))
  (cc-superimpose
   (colorize (filled-rounded-rectangle w NODE-H NODE-RADIUS) bg-color)
   (colorize (rectangle w NODE-H) COLOR-BORDER)
   txt))

;; track line segment
(define (track w)
  (colorize (hline w TRACK-H) COLOR-TRACK))

;; AST -> pict
(define (ast->pict node)
  (match node
    [(re-literal c)
     (node-box (format "~a" c))]
    [(re-any)
     (node-box "." COLOR-SPECIAL)]
    [(re-char-class items neg?)
     (node-box (format-class items neg?) COLOR-CLASS)]
    [(re-anchor 'start)
     (node-box "^" COLOR-ANCHOR)]
    [(re-anchor 'end)
     (node-box "$" COLOR-ANCHOR)]
    [(re-anchor type)
     (node-box (format "~a" type) COLOR-ANCHOR)]
    [(re-escape type)
     (node-box (format-escape type) COLOR-ESCAPE)]
    [(re-backref index)
     (node-box (format "\\~a" index) COLOR-ESCAPE)]
    [(re-unicode-class name negated?)
     (node-box (if negated? (format "\\P{~a}" name) (format "\\p{~a}" name)) COLOR-ESCAPE)]
    [(re-flags chars)
     (node-box (format "(?~a)" chars) COLOR-NODE)]
    [(re-sequence elems)
     (if (null? elems)
         (blank 0 NODE-H)
         (let ([pics (map ast->pict elems)])
           (apply hc-append (add-between pics (track GAP)))))]
    [(re-alternation left right)
     (alt-layout (ast->pict left) (ast->pict right))]
    [(re-quantifier base q-min q-max q-greedy?)
     (quant-layout (ast->pict base) q-min q-max q-greedy?)]
    [(re-group child capture? name flags)
     (group-layout (ast->pict child) capture? name flags)]
    [(re-lookaround direction negated? child)
     (lookaround-layout (ast->pict child) direction negated?)]
    [(re-atomic child)
     (framed (ast->pict child) "(?>)" COLOR-ATOMIC)]))

;; alternation fork: branches stacked between two rails, each branch row
;; carrying a vertically-centered flow line so taps and content connect
(define (alt-layout left-pict right-pict)
  (define max-w (max (pict-width left-pict) (pict-width right-pict)))
  (define left-pad (/ (- max-w (pict-width left-pict)) 2))
  (define right-pad (/ (- max-w (pict-width right-pict)) 2))
  (define (flow-row pict h lp rp)
    (hc-append (cc-superimpose (blank 10 h) (colorize (hline 10 TRACK-H) COLOR-TRACK))
               (blank lp h) pict (blank rp h)
               (cc-superimpose (blank 10 h) (colorize (hline 10 TRACK-H) COLOR-TRACK))))
  (define h1 (max NODE-H (pict-height left-pict)))
  (define h2 (max NODE-H (pict-height right-pict)))
  (define left-centered (flow-row left-pict h1 left-pad right-pad))
  (define right-centered (flow-row right-pict h2 right-pad left-pad))
  (define branches (vc-append ALT-GAP left-centered right-centered))
  (define H (pict-height branches))
  (define y1 (/ h1 2))
  (define y2 (+ h1 ALT-GAP (/ h2 2)))
  (define rail-w 12)
  (hc-append (rail rail-w H (list y1 y2) 'left)
             branches
             (rail rail-w H (list y1 y2) 'right)))

;; vertical rail with horizontal taps at each y — the fork connectors
(define (rail w h ys side)
  (define canvas (blank w h))
  (define v (colorize (vline 2 h) COLOR-TRACK))
  (define base (if (eq? side 'left) (lt-superimpose canvas v) (rt-superimpose canvas v)))
  (for/fold ([acc base])
            ([y (in-list ys)])
    (define tap
      (vc-append 0
                 (blank w (max 0 (- y 1)))
                 (colorize (hline w 2) COLOR-TRACK)
                 (blank w (max 0 (- h y 1)))))
    (lt-superimpose acc tap)))

;; quantifier: the flow line runs straight through the node's vertical
;; center (correct for every quantifier); a loop branches up from the entry,
;; carries the label in a gap in the line, and rejoins at the exit.
;; Pieces are placed absolutely so alignment never depends on pict's
;; box-alignment rules.
(define (quant-layout base-pict q-min q-max q-greedy?)
  (define core
    (cond
      [(and (= q-min 0) (eq? q-max #f)) "*"]
      [(and (= q-min 1) (eq? q-max #f)) "+"]
      [(and (= q-min 0) (= q-max 1)) "?"]
      [(and (number? q-min) (number? q-max) (= q-min q-max)) (format "{~a}" q-min)]
      [(eq? q-max #f) (format "{~a,}" q-min)]
      [else (format "{~a,~a}" q-min q-max)]))
  (define label (if q-greedy? core (format "~a?" core)))
  (define label-pict (colorize (text label 'default 10) COLOR-QUANT))
  (define lw (pict-width label-pict))
  (define lh (pict-height label-pict))
  (define node-w (pict-width base-pict))
  (define node-h (pict-height base-pict))
  (define loop-w (max (+ node-w 24) (+ lw 26)))
  (define gap (+ lw 12))
  (define side (/ (- loop-w gap) 2))
  (define row-h (max lh 12))
  (define stub-h 6)
  (define total-h (+ row-h stub-h node-h))
  (define center-y (+ row-h stub-h (/ node-h 2)))
  ;; element with its top-left corner at (x, y) on a full-size canvas
  (define (put elt x y)
    (hc-append (blank x 0) (vc-append 0 (blank 0 y) elt)))
  (define (seg w) (cc-superimpose (blank w row-h) (colorize (hline w TRACK-H) COLOR-TRACK)))
  ;; the glyph's font box centers it a touch low; bias the label up ~1.6pt
  ;; so its strokes read centered on the loop line
  (define label-cell
    (cc-superimpose (blank gap lh) (vc-append 0 label-pict (blank 0 3))))
  (define topline (hc-append (seg side) label-cell (seg side)))
  (define drop-h (- center-y (+ (/ row-h 2) 1)))
  (define drop (colorize (vline 2 drop-h) COLOR-TRACK))
  (define p (blank loop-w total-h))
  (set! p (lt-superimpose p (put (colorize (hline loop-w TRACK-H) COLOR-TRACK) 0 (- center-y 1))))
  (set! p (lt-superimpose p (put topline 0 0)))
  (set! p (lt-superimpose p (put drop 0 (+ (/ row-h 2) 1))))
  (set! p (lt-superimpose p (put drop (- loop-w 2) (+ (/ row-h 2) 1))))
  ;; node last so its fill covers the flow line passing behind it
  (set! p (lt-superimpose p (put base-pict (/ (- loop-w node-w) 2) (+ row-h stub-h))))
  ;; balance the space below the node so the flow line sits at the pict's
  ;; vertical center — entry/exit tracks (center-aligned by hc-append) then
  ;; land exactly on it
  (vc-append 0 p (blank loop-w (+ row-h stub-h))))

;; frame around a child pict; opaque white fill masks the parent's flow
;; line so it only shows entering and leaving the frame
(define (framed child-pict color)
  (define w (+ (pict-width child-pict) 10))
  (define h (+ (pict-height child-pict) 8))
  (cc-superimpose
   (colorize (filled-rectangle w h) COLOR-NODE)
   (colorize (rectangle w h) color)
   child-pict))

;; small caption above a frame
(define (tagged child-pict tag color)
  (define lbl (colorize (text tag 'default 8) color))
  (vl-append -2 lbl (framed child-pict color)))

(define (group-layout child-pict capture? name flags)
  (define frame-color (if capture? COLOR-GROUP COLOR-GROUP-NC))
  (define framed-pict (framed child-pict frame-color))
  (cond
    [flags
     (tagged child-pict (format "(?~a:)" flags) frame-color)]
    [name
     (lc-superimpose
      (hc-append 2 (text "(" 'default 8) (text name 'default 8) (text ")" 'default 8))
      framed-pict)]
    [else framed-pict]))

(define (lookaround-layout child-pict direction negated?)
  (define tag
    (case direction
      [(ahead) (if negated? "(?!)" "(?=)")]
      [(behind) (if negated? "(?<!" "(?<=")]))
  (tagged child-pict tag COLOR-LOOK))

;; char class label, shared shape with the human formatter
(define (format-class items neg?)
  (define content
     (string-join
      (for/list ([item items])
        (match item
          [(list 'posix name) (format "[:~a:]" name)]
          [(list 'class kind) (format-escape kind)]
          [(cons a b) (format "~a-~a" a b)]
          [c (format "~a" c)]))
      ""))
  (format "[~a~a]" (if neg? "^" "") content))

(define (format-escape type)
  (case type
    [(digit) "\\d"]
    [(non-digit) "\\D"]
    [(word) "\\w"]
    [(non-word) "\\W"]
    [(space) "\\s"]
    [(non-space) "\\S"]
    [(word-boundary) "\\b"]
    [(non-word-boundary) "\\B"]
    [else (format "\\~a" type)]))

;; full diagram with entry/exit tracks — the shared shape used by the SVG
;; and the PNG renderers
(define (railroad-pict ast)
  (hc-append (track 16) (ast->pict ast) (track 16)))

;; AST -> SVG byte string
(define (ast->svg ast)
  (convert (railroad-pict ast) 'svg-bytes))

;; pattern -> SVG bytes (raises when the parser cannot model the pattern)
(define (railroad-svg pattern)
  (define parsed (parse-regex-safe pattern))
  (define ast (car parsed))
  (unless ast (error 'railroad "cannot visualize pattern: ~a" (cdr parsed)))
  (ast->svg ast))

;; render to file or stdout; returns byte count
(define (generate-railroad-svg pattern output-path)
  (define svg-bytes (railroad-svg pattern))
  (if output-path
      (begin
        (call-with-output-file output-path
          (lambda (out) (write-bytes svg-bytes out))
          #:exists 'truncate)
        (displayln (format "SVG 已保存到: ~a" output-path)))
      (write-bytes svg-bytes))
  (bytes-length svg-bytes))

(provide generate-railroad-svg railroad-svg ast->pict railroad-pict ast->svg)
