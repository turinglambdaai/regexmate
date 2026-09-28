#lang racket

(require racket/match
         "../core/ast.rkt"
         "../core/regex-parser.rkt"
         "../core/i18n.rkt")

;; Human-readable output: validate/match/replace formatting and the
;; plain-language regex explainer. All strings come from i18n (en/zh).

;; control chars render as their escape form in descriptions
(define (escape-char c)
  (case c
    [(#\newline) "\\n"]
    [(#\tab) "\\t"]
    [(#\return) "\\r"]
    [else (string c)]))

(define (char-class-label ranges neg?)
  (define content
    (string-join
     (for/list ([item ranges])
       (match item
         ;; symbolic items are proper lists — match them before the range cons
         [(list 'posix name) (format "[:~a:]" name)]
         [(list 'class kind) (format-escape kind)]
         [(cons a b) (format "~a-~a" (escape-char a) (escape-char b))]
         [c (escape-char c)]))
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

;; quantifier suffix as written in source, with greediness noted
(define (quantifier-label min max greedy?)
  (define core
    (cond
      [(and (= min 0) (eq? max #f)) "*"]
      [(and (= min 1) (eq? max #f)) "+"]
      [(and (= min 0) (= max 1)) "?"]
      [(and (number? min) (number? max) (= min max)) (format "{~a}" min)]
      [(eq? max #f) (format "{~a,}" min)]
      [else (format "{~a,~a}" min max)]))
  (if greedy? core (format "~a? (lazy)" core)))

(define (lang) (current-language))

;; AST -> plain-language description (recursive)
(define (ast->description node [group-name (lambda () #f)])
  (match node
    [(re-literal c)
     (if (eq? (lang) 'zh)
         (format "字面量: ~a" (escape-char c))
         (format "Literal: ~a" (escape-char c)))]
    [(re-any)
     (if (eq? (lang) 'zh)
         "除换行外的任意字符 (.)"
         "Any character except newline (.)")]
    [(re-char-class items neg?)
     (if (eq? (lang) 'zh)
         (format "字符类: ~a" (char-class-label items neg?))
         (format "Character class: ~a" (char-class-label items neg?)))]
    [(re-anchor 'start)
     (if (eq? (lang) 'zh) "锚点: 行首 (^)" "Anchor: start of line (^)")]
    [(re-anchor 'end)
     (if (eq? (lang) 'zh) "锚点: 行尾 ($)" "Anchor: end of line ($)")]
    [(re-quantifier base min max greedy?)
     (define base-desc (ast->description base group-name))
     (define q (quantifier-label min max greedy?))
     (format "~a × ~a" base-desc q)]
    [(re-group child capture? name flags)
     (define inner (ast->description child group-name))
     (cond
       [(and capture? (group-name))
        (define n (group-name))
        (if (eq? (lang) 'zh)
            (format "捕获组 (~a): ~a" n inner)
            (format "Capturing group (~a): ~a" n inner))]
       [capture?
        (if (eq? (lang) 'zh)
            (format "捕获组 (...): ~a" inner)
            (format "Capturing group (...): ~a" inner))]
       [flags
        (if (eq? (lang) 'zh)
            (format "启用标志 ~a 的组 (?~a:...): ~a" flags flags inner)
            (format "Group with flags ~a (?~a:...): ~a" flags flags inner))]
       [else
        (if (eq? (lang) 'zh)
            (format "非捕获组 (?:...): ~a" inner)
            (format "Non-capturing group (?:...): ~a" inner))])]
    [(re-lookaround direction negated? child)
     (define inner (ast->description child group-name))
     (define label
       (if (eq? (lang) 'zh)
           (case direction
             [(ahead) (if negated? "负向先行断言 (?!...)" "正向先行断言 (?=...)")]
             [(behind) (if negated? "负向后行断言 (?<!...)" "正向后行断言 (?<=...)")])
           (case direction
             [(ahead) (if negated? "Negative lookahead (?!...)" "Positive lookahead (?=...)")]
             [(behind) (if negated? "Negative lookbehind (?<!...)" "Positive lookbehind (?<=...)")])))
     (format "~a: ~a" label inner)]
    [(re-atomic child)
     (define inner (ast->description child group-name))
     (if (eq? (lang) 'zh)
         (format "原子组 (?>...): ~a" inner)
         (format "Atomic group (?>...): ~a" inner))]
    [(re-unicode-class name negated?)
     (define token (if negated? (format "\\P{~a}" name) (format "\\p{~a}" name)))
     (if (eq? (lang) 'zh)
         (format "Unicode 属性 ~a (~a)" name token)
         (format "Unicode property ~a (~a)" name token))]
    [(re-backref index)
     (define token (format "\\~a" index))
     (if (eq? (lang) 'zh)
         (format "反向引用第 ~a 组 (~a)" index token)
         (format "Backreference to group ~a (~a)" index token))]
    [(re-alternation left right)
     (format "~a | ~a"
             (ast->description left group-name)
             (ast->description right group-name))]
    [(re-sequence elems)
     (string-join (map (lambda (e) (ast->description e group-name)) elems) " → ")]
    [(re-escape type)
     (define token (format-escape type))
     (if (eq? (lang) 'zh)
         (case type
           [(digit) (format "数字 (~a)" token)]
           [(non-digit) (format "非数字 (~a)" token)]
           [(word) (format "单词字符 (~a)" token)]
           [(non-word) (format "非单词字符 (~a)" token)]
           [(space) (format "空白 (~a)" token)]
           [(non-space) (format "非空白 (~a)" token)]
           [(word-boundary) (format "单词边界 (~a)" token)]
           [else (format "转义: ~a" token)])
         (case type
           [(digit) (format "Digit (~a)" token)]
           [(non-digit) (format "Non-digit (~a)" token)]
           [(word) (format "Word character (~a)" token)]
           [(non-word) (format "Non-word character (~a)" token)]
           [(space) (format "Whitespace (~a)" token)]
           [(non-space) (format "Non-whitespace (~a)" token)]
           [(word-boundary) (format "Word boundary (~a)" token)]
           [(non-word-boundary) (format "Non-word boundary (~a)" token)]
           [else (format "Escape: ~a" token)]))]))

;; AST -> source-form reconstruction
(define (ast->raw node)
  (match node
    [(re-literal c) (escape-char c)]
    [(re-any) "."]
    [(re-char-class items neg?)
     (format "[~a~a]"
             (if neg? "^" "")
             (string-join
              (for/list ([item items])
                (match item
                  [(list 'posix name) (format "[:~a:]" name)]
                  [(list 'class kind) (format-escape kind)]
                  [(cons a b) (format "~a-~a" (escape-char a) (escape-char b))]
                  [c (escape-char c)]))
              ""))]
    [(re-anchor 'start) "^"]
    [(re-anchor 'end) "$"]
    [(re-quantifier base min max greedy?)
     (define base-raw (ast->raw base))
     (define core
       (cond
         [(and (= min 0) (eq? max #f)) "*"]
         [(and (= min 1) (eq? max #f)) "+"]
         [(and (= min 0) (= max 1)) "?"]
         [(and (number? min) (number? max) (= min max)) (format "{~a}" min)]
         [(eq? max #f) (format "{~a,}" min)]
         [else (format "{~a,~a}" min max)]))
     (format "~a~a~a" base-raw core (if greedy? "" "?"))]
    [(re-group child capture? name flags)
     (define inner (ast->raw child))
     (cond
       [flags (format "(?~a:~a)" flags inner)]
       [(and capture? name) (format "(?<~a>~a)" name inner)]
       [capture? (format "(~a)" inner)]
       [else (format "(?:~a)" inner)])]
    [(re-lookaround direction negated? child)
     (define inner (ast->raw child))
     (define head
       (case direction
         [(ahead) (if negated? "(?!" "(?=")]
         [(behind) (if negated? "(?<!" "(?<=")]))
     (format "~a~a)" head inner)]
    [(re-atomic child) (format "(?>~a)" (ast->raw child))]
    [(re-unicode-class name negated?)
     (if negated? (format "\\P{~a}" name) (format "\\p{~a}" name))]
    [(re-backref index) (format "\\~a" index)]
    [(re-alternation left right)
     (format "~a|~a" (ast->raw left) (ast->raw right))]
    [(re-sequence elems)
     (string-join (map ast->raw elems) "")]
    [(re-escape type) (format-escape type)]))

;; pattern -> parts list. Each part: {type, raw, description}.
;; Falls back to a single "unsupported" part when our parser does not
;; model some pregexp-valid syntax.
(define (explain-regex pattern)
  (define parsed (parse-regex-safe pattern))
  (define ast (car parsed))
  (if (not ast)
      (list (hasheq 'type "unsupported"
                    'raw pattern
                    'description (msg 'explain-unsupported)))
      (let ()
        (define-values (_ names) (collect-groups ast))
        (define next-group (make-group-namer names))
        (define (node->part node)
          (hasheq 'type (symbol->string (node-type node))
                  'raw (ast->raw node)
                  'description (ast->description node next-group)))
        (match ast
          [(re-sequence elems) (map node->part elems)]
          [single (list (node->part single))]))))

(define (format-explain-human pattern parts)
  (string-append
   (msg 'explain-header pattern)
   (string-join
    (for/list ([p parts] [i (in-naturals 1)])
      (msg 'explain-entry i (hash-ref p 'type) (hash-ref p 'raw) (hash-ref p 'description)))
    "")))

(provide explain-regex format-explain-human ast->description ast->raw
         escape-char char-class-label quantifier-label format-escape)
