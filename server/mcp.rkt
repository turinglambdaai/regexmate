#lang racket

;; stdio MCP server: newline-delimited JSON-RPC 2.0 (MCP stdio transport).
;; Exposes the regexmate commands as agent tools. One process, sequential
;; requests, exits 0 on EOF. Nothing may be written to stdout except
;; protocol responses.

(require json
         racket/match
         "../version.rkt"
         "../core/regex-engine.rkt"
         "../core/regex-parser.rkt"
         "../core/ast.rkt"
         "../core/tester.rkt"
         "../core/linter.rkt"
         "../output/json-format.rkt"
         "../output/human-format.rkt"
         "../output/railroad.rkt")

(define PROTOCOL-VERSION "2024-11-05")

;; ---- tool input schemas -------------------------------------------

(define (schema-of properties required)
  (hasheq 'type "object"
          'properties properties
          'required required
          'additionalProperties #f))

(define (str-schema desc)
  (hasheq 'type "string" 'description desc))

(define (tool-def name desc schema)
  (hasheq 'name name 'description desc 'inputSchema schema))

(define TOOL-DEFS-FULL
  (list
   (tool-def
    "regexmate_validate"
    "Check whether a regular expression is syntactically valid (Racket pregexp flavor). Returns valid=true/false with a single-line error message."
    (schema-of (hasheq 'pattern (str-schema "The regular expression to validate"))
               '("pattern")))
   (tool-def
    "regexmate_match"
    "Run a regex against text and return all matches with absolute [start,end) spans and 1-based capture groups (null when a group is absent)."
    (schema-of (hasheq 'pattern (str-schema "The regular expression")
                       'text (str-schema "The text to search in"))
               '("pattern" "text")))
   (tool-def
    "regexmate_explain"
    "Explain a regex part by part in plain English: type, raw source and description for each component."
    (schema-of (hasheq 'pattern (str-schema "The regular expression to explain"))
               '("pattern")))
   (tool-def
    "regexmate_replace"
    "Replace all regex matches in text. Racket insertion syntax: \\\\1 references group 1, \\\\0 the whole match. Returns the result and replacement count."
    (schema-of (hasheq 'pattern (str-schema "The regular expression")
                       'replacement (str-schema "Insertion template with \\\\1, \\\\2, ... references")
                       'text (str-schema "The text to operate on"))
               '("pattern" "replacement" "text")))
   (tool-def
    "regexmate_graph"
    "Render a railroad diagram of the regex as SVG markup. Use it to document or review a pattern visually."
    (schema-of (hasheq 'pattern (str-schema "The regular expression to draw"))
               '("pattern")))
   (tool-def
    "regexmate_test"
    "Assert a regex against sample cases and get per-case evidence: {\"text\": s, \"expect\": \"match\"|\"no-match\", \"contains\": s?}. Use it to verify a regex before shipping it."
    (schema-of
     (hasheq 'pattern (str-schema "The regular expression to test")
             'cases
             (hasheq 'type "array"
                     'description "Test cases; expect defaults to \"match\""
                     'items
                     (hasheq 'type "object"
                             'properties (hasheq 'text (str-schema "Sample text")
                                                 'expect (hasheq 'type "string" 'enum '("match" "no-match"))
                                                 'contains (str-schema "Substring a match must contain"))
                             'required '("text"))))
     '("pattern" "cases")))
   (tool-def
    "regexmate_lint"
    "Static risk findings for a regex: nested quantifiers (catastrophic backtracking), quantified assertions, empty or duplicate alternation branches, shadowed branches. Advisory, not errors."
    (schema-of (hasheq 'pattern (str-schema "The regular expression to analyze"))
               '("pattern")))))

;; ---- tool implementations ------------------------------------------

;; every tool returns a jsexpr payload (the regexmate/v1 envelope)
(define (run-tool name args)
  (define (arg k) (hash-ref args k #f))
  (match name
    ["regexmate_validate"
     (define pattern (arg 'pattern))
     (define valid (valid-regex? pattern))
     (format-validate-json pattern valid (and (not valid) (get-regex-error pattern)))]
    ["regexmate_match"
     (define pattern (arg 'pattern))
     (define text (arg 'text))
     (if (not (valid-regex? pattern))
         (format-error-json "match" (get-regex-error pattern))
         (let ()
           (define records (find-all-matches pattern text))
           (define ast (car (parse-regex-safe pattern)))
           (define names (if ast (let-values ([(_ nm) (collect-groups ast)]) nm) (hash)))
           (format-match-json pattern text records names)))]
    ["regexmate_explain"
     (define pattern (arg 'pattern))
     (if (not (valid-regex? pattern))
         (format-error-json "explain" (get-regex-error pattern))
         (format-explain-json pattern (explain-regex pattern)))]
    ["regexmate_replace"
     (define pattern (arg 'pattern))
     (define replacement (arg 'replacement))
     (define text (arg 'text))
     (if (not (valid-regex? pattern))
         (format-error-json "replace" (get-regex-error pattern))
         (let ()
           (define replaced (replace-regex pattern text replacement))
           (format-replace-json pattern replacement text (car replaced) (cdr replaced))))]
    ["regexmate_graph"
     (define pattern (arg 'pattern))
     (if (not (valid-regex? pattern))
         (format-error-json "graph" (get-regex-error pattern))
         (let ()
           (define ast (car (parse-regex-safe pattern)))
           (if (not ast)
               (format-error-json "graph" "pattern uses syntax the visualizer does not support")
               (format-graph-json pattern (bytes->string/utf-8 (ast->svg ast))))))]
    ["regexmate_test"
     (define pattern (arg 'pattern))
     (if (not (valid-regex? pattern))
         (format-error-json "test" (get-regex-error pattern))
         (let ()
           (define-values (results passed failed) (run-cases pattern (arg 'cases)))
           (format-test-json pattern results (length results) passed failed)))]
    ["regexmate_lint"
     (define pattern (arg 'pattern))
     (if (not (valid-regex? pattern))
         (format-error-json "lint" (get-regex-error pattern))
         (format-lint-json pattern (lint-regex-json pattern)))]
    [else #f]))

;; ---- JSON-RPC plumbing ---------------------------------------------

(define (rpc-result id result)
  (hasheq 'jsonrpc "2.0" 'id id 'result result))

(define (rpc-error id code message)
  (hasheq 'jsonrpc "2.0" 'id id 'error (hasheq 'code code 'message message)))

(define ERR-PARSE -32700)
(define ERR-METHOD -32601)
(define ERR-PARAMS -32602)

(define (write-json port v)
  (displayln (jsexpr->string v) port)
  (flush-output port))

(define (handle-message msg out)
  (define id (and (hash? msg) (hash-ref msg 'id #f)))
  (define method (and (hash? msg) (hash-ref msg 'method #f)))
  (cond
    ;; notifications get no response
    [(not id) (void)]
    [(not method)
     (write-json out (rpc-error id ERR-PARAMS "missing method"))]
    [(string=? method "initialize")
     (write-json out
                 (rpc-result id
                             (hasheq 'protocolVersion PROTOCOL-VERSION
                                     'capabilities (hasheq 'tools (hasheq))
                                     'serverInfo (hasheq 'name "regexmate" 'version regexmate-version))))]
    [(string=? method "ping")
     (write-json out (rpc-result id (hasheq)))]
    [(string=? method "tools/list")
     (write-json out (rpc-result id (hasheq 'tools TOOL-DEFS-FULL)))]
    [(string=? method "tools/call")
     (define params (hash-ref msg 'params (hasheq)))
     (define name (hash-ref params 'name #f))
     (define args (hash-ref params 'arguments (hasheq)))
     (cond
       [(not name)
        (write-json out (rpc-error id ERR-PARAMS "tools/call requires a tool name"))]
       [(not (hash? args))
        (write-json out (rpc-error id ERR-PARAMS "arguments must be an object"))]
       [else
        (define result (run-tool name args))
        (cond
          [result
           (write-json out
                       (rpc-result id
                                   (hasheq 'content (list (hasheq 'type "text" 'text (jsexpr->string result)))
                                           'isError (not (hash-ref result 'ok #t)))))]
          [else
           (write-json out (rpc-error id ERR-METHOD (format "unknown tool: ~a" name)))])])]
    [else
     (write-json out (rpc-error id ERR-METHOD (format "unknown method: ~a" method)))]))

;; ---- main loop ------------------------------------------------------

(define (mcp-main)
  ;; agents may send any locale; force UTF-8 both ways
  (current-input-port (reencode-input-port (current-input-port) "UTF-8"))
  (current-output-port (reencode-output-port (current-output-port) "UTF-8"))
  (let loop ()
    (define line (read-line (current-input-port) 'any))
    (unless (eof-object? line)
      (define trimmed (string-trim line))
      (unless (string=? trimmed "")
        (with-handlers ([exn:fail? (lambda (e)
                                     (write-json (current-output-port)
                                                 (rpc-error #f ERR-PARSE
                                                            "request is not valid JSON")))])
          (define msg (string->jsexpr trimmed))
          (handle-message msg (current-output-port))))
      (loop))))

(provide mcp-main TOOL-DEFS-FULL run-tool)
