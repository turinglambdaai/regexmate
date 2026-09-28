#lang racket

(require pict
         file/convertible
         racket/draw
         racket/match
         "../core/ast.rkt"
         "../core/regex-parser.rkt")

;; Railroad diagram renderer: AST -> pict -> SVG bytes.

;; color theme
(define COLOR-NODE    (make-object color% 255 255 255))   ; white
(define COLOR-SPECIAL (make-object color% 232 245 233))   ; light green
(define COLOR-CLASS   (make-object color% 227 242 253))   ; light blue
(define COLOR-ANCHOR  (make-object color% 255 243 224))   ; light orange
(define COLOR-ESCAPE  (make-object color% 243 229 245))   ; light purple
(define COLOR-GROUP   (make-object color% 76 175 80))     ; green frame
(define COLOR-GROUP-NC (make-object color% 158 158 158))  ; gray frame
(define COLOR-LOOK    (make-object color% 3 155 229))     ; blue frame
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

;; alternation fork layout
(define (alt-layout left-pict right-pict)
  (define max-w (max (pict-width left-pict) (pict-width right-pict)))
  (define left-pad (/ (- max-w (pict-width left-pict)) 2))
  (define right-pad (/ (- max-w (pict-width right-pict)) 2))
  (define left-centered (hc-append (blank left-pad NODE-H) left-pict (blank right-pad NODE-H)))
  (define right-centered (hc-append (blank right-pad NODE-H) right-pict (blank left-pad NODE-H)))
  (vc-append ALT-GAP left-centered right-centered))

;; quantifier badge above the node
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
  (define base-w (pict-width base-pict))
  (define label-w (pict-width label-pict))
  (vc-append -4
             (hc-append (/ (max 0 (- base-w label-w)) 2) label-pict)
             base-pict))

;; frame around a child pict
(define (framed child-pict color)
  (define frame-pict
    (colorize
     (rectangle (+ (pict-width child-pict) 10) (+ (pict-height child-pict) 8))
     color))
  (cc-superimpose frame-pict child-pict))

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

;; AST -> SVG byte string
(define (ast->svg ast)
  (define diagram (ast->pict ast))
  (define full-diagram (hc-append (track 16) diagram (track 16)))
  (convert full-diagram 'svg-bytes))

;; pattern -> SVG bytes (raises when the parser cannot model the pattern)
(define (railroad-svg pattern)
  (define-values (ast err) (parse-regex-safe pattern))
  (unless ast (error 'railroad "cannot visualize pattern: ~a" err))
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

(provide generate-railroad-svg railroad-svg ast->pict ast->svg)
