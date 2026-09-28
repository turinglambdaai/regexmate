#lang racket

(require json)

;; JSON output — contract "regexmate/v1".
;; Every envelope carries: schema, command, ok. Field notes for agents:
;;   - spans are [start, end) with end exclusive, absolute indices
;;   - groups are 1-based; value/start/end are null when a group is absent

(define SCHEMA "regexmate/v1")

(define (envelope command ok . extra)
  (apply hasheq 'schema SCHEMA 'command command 'ok ok extra))

;; span (start . end) -> value string
(define (span-text text span)
  (substring text (car span) (cdr span)))

;; capture-group span -> group object; index 1-based, name optional
(define (group-json text index name span)
  (if span
      (hasheq 'index index
              'name name
              'value (span-text text span)
              'start (car span)
              'end (cdr span))
      (hasheq 'index index
              'name name
              'value #f
              'start #f
              'end #f)))

;; match record from find-all-matches -> match object
(define (match-json text names match-record)
  (match-define (cons overall group-spans) match-record)
  (hasheq 'value (span-text text overall)
          'start (car overall)
          'end (cdr overall)
          'groups (for/list ([span group-spans]
                             [index (in-naturals 1)])
                    (group-json text index (hash-ref names index #f) span))))

(define (format-validate-json pattern valid error)
  (if valid
      (envelope "validate" #t 'pattern pattern 'valid #t)
      (envelope "validate" #f 'pattern pattern 'valid #f 'error error)))

(define (format-match-json pattern text match-records names)
  (define matches (for/list ([m match-records]) (match-json text names m)))
  (envelope "match" #t
            'pattern pattern
            'text text
            'count (length matches)
            'matches matches))

(define (format-explain-json pattern parts)
  (envelope "explain" #t 'pattern pattern 'parts parts))

(define (format-replace-json pattern replacement text result count)
  (envelope "replace" #t
            'pattern pattern
            'replacement replacement
            'text text
            'count count
            'result result))

(define (format-graph-json pattern svg-string)
  (envelope "graph" #t 'pattern pattern 'svg svg-string))

(define (format-graph-file-json pattern output-path bytes)
  (envelope "graph" #t 'pattern pattern 'output output-path 'bytes bytes))

(define (format-error-json command error)
  (envelope command #f 'error error))

(define (format-version-json version)
  (hasheq 'schema SCHEMA 'command "version" 'ok #t 'version version))

(define (jsexpr->line v) (jsexpr->string v))

(provide format-validate-json format-match-json format-explain-json
         format-replace-json format-graph-json format-graph-file-json
         format-error-json format-version-json jsexpr->line
         SCHEMA)
