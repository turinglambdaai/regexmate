#lang racket

(require json
         "../core/cookbook.rkt")

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

;; hint is an optional repair suggestion — added as a key only when known,
;; so existing consumers never see hint: null
(define (format-validate-json pattern valid error [hint #f])
  (if valid
      (envelope "validate" #t 'pattern pattern 'valid #t)
      (if hint
          (envelope "validate" #f 'pattern pattern 'valid #f 'error error 'hint hint)
          (envelope "validate" #f 'pattern pattern 'valid #f 'error error))))

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

(define (format-error-json command error [hint #f])
  (if hint
      (envelope command #f 'error error 'hint hint)
      (envelope command #f 'error error)))

(define (format-test-json pattern results total passed failed)
  (envelope "test" #t
            'pattern pattern
            'total total
            'passed passed
            'failed failed
            'results results))

(define (format-lint-json pattern warnings)
  (envelope "lint" #t
            'pattern pattern
            'count (length warnings)
            'warnings warnings))

(define (format-version-json version)
  (hasheq 'schema SCHEMA 'command "version" 'ok #t 'version version))

;; cookbook: a listing carries id/topic/title; a detail view adds the
;; pattern, sample, teaching notes and variants in the current language
(define (cookbook-recipe-json r title notes variants sample)
  (hasheq 'id (symbol->string (recipe-id r))
          'topic (symbol->string (recipe-topic r))
          'title title
          'pattern (recipe-pattern r)
          'sample sample
          'notes (for/list ([pair (in-list notes)])
                   (if (string=? (car pair) "*")
                       (hasheq 'note (cdr pair))
                       (hasheq 'segment (car pair) 'note (cdr pair))))
          'variants (for/list ([pair (in-list variants)])
                      (hasheq 'pattern (car pair) 'note (cdr pair)))))

(define (format-cookbook-list-json recipes titles)
  (envelope "cookbook" #t
            'count (length recipes)
            'recipes (for/list ([r recipes] [title titles])
                       (hasheq 'id (symbol->string (recipe-id r))
                               'topic (symbol->string (recipe-topic r))
                               'title title))))

(define (format-cookbook-json r title notes variants sample)
  (envelope "cookbook" #t
            'count 1
            'recipes (list (cookbook-recipe-json r title notes variants sample))))

(define (jsexpr->line v) (jsexpr->string v))

(provide format-validate-json format-match-json format-explain-json
         format-replace-json format-graph-json format-graph-file-json
         format-test-json format-lint-json
         format-error-json format-version-json jsexpr->line
         format-cookbook-list-json format-cookbook-json
         SCHEMA)
