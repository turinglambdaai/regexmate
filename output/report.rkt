#lang racket/base

;; Single-file HTML evidence reports: pattern, match table, highlighted
;; sample, explanation, test results, lint findings and the railroad
;; diagram — everything a pull request or CI job needs to prove a regex.

(require racket/format
         racket/list
         racket/string)

(provide report-html html-escape)

(define (html-escape s)
  (apply string-append
         (for/list ([c (in-string s)])
           (case c
             [(#\&) "&amp;"]
             [(#\<) "&lt;"]
             [(#\>) "&gt;"]
             [(#\") "&quot;"]
             [else (string c)]))))

(define (esc s) (html-escape (if (string? s) s (format "~a" s))))

(define css
  "body{font-family:-apple-system,'Segoe UI',sans-serif;margin:0;background:#f6f6f4;color:#1d1d1f}
h1{font-size:22px;margin:0 0 4px}
h2{font-size:12px;margin:28px 0 8px;color:#037a55;text-transform:uppercase;letter-spacing:.04em}
.wrap{max-width:900px;margin:0 auto;padding:32px 24px 48px}
.pill{display:inline-block;border:1px solid #d5d5d0;border-radius:99px;padding:2px 10px;font-size:12px;margin-right:6px;color:#555}
.mono{font-family:'SF Mono',Consolas,monospace}
.pattern{font-family:monospace;font-size:15px;background:#fff;border:1px solid #d5d5d0;border-radius:8px;padding:12px 16px;word-break:break-all}
table{width:100%;border-collapse:collapse;background:#fff;border:1px solid #d5d5d0;border-radius:8px;overflow:hidden}
th,td{text-align:left;padding:7px 12px;border-bottom:1px solid #eee;font-size:13px}
th{background:#fafaf8;font-size:11px;text-transform:uppercase;letter-spacing:.05em;color:#555}
pre{background:#16181a;color:#d8dcde;border-radius:8px;padding:14px 16px;font-size:13px;line-height:1.6;overflow-x:auto;white-space:pre-wrap;word-break:break-word}
mark{background:#ffe9a8;color:inherit;font-weight:600;padding:0 1px}
.bad{background:#fde8e6;color:#8a2b1d;font-weight:600;padding:0 1px}
.ok{color:#037a55;font-weight:600}
.diagram{background:#fff;border:1px solid #d5d5d0;border-radius:8px;padding:16px;text-align:center}
.diagram svg{max-width:100%;height:auto}
.meta{color:#86868b;font-size:12px;margin-top:28px}
.err{background:#fde8e6;color:#8a2b1d;border-radius:8px;padding:12px 16px;font-family:monospace;font-size:13px}")

(define (table headers rows)
  (string-append
   "<table><thead><tr>"
   (apply string-append (for/list ([h (in-list headers)]) (format "<th>~a</th>" (esc h))))
   "</tr></thead><tbody>"
   (if (null? rows)
       (format "<tr><td colspan=\"~a\" style=\"color:#86868b\">—</td></tr>" (length headers))
       (apply string-append
              (for/list ([row (in-list rows)])
                (string-append "<tr>"
                               (apply string-append
                                      (for/list ([cell (in-list row)])
                                        (format "<td class=\"mono\">~a</td>" (esc cell))))
                               "</tr>"))))
   "</tbody></table>"))

;; sample text with <mark>ed match spans
(define (highlighted-sample text rows)
  (define marks (make-vector (string-length text) #f))
  (for ([row (in-list rows)])
    (when (>= (length row) 3)
      (define start (string->number (list-ref row 1)))
      (define end (string->number (list-ref row 2)))
      (when (and start end (<= 0 start end (string-length text)))
        (for ([i (in-range start end)]) (vector-set! marks i #t)))))
  (define out (open-output-string))
  (let loop ([i 0] [in-mark #f])
    (cond
      [(>= i (string-length text))
       (when in-mark (display "</mark>" out))]
      [(and in-mark (not (vector-ref marks i)))
       (display "</mark>" out)
       (loop i #f)]
      [(and (not in-mark) (vector-ref marks i))
       (display "<mark>" out)
       (loop i #t)]
      [else
       (display (html-escape (string (string-ref text i))) out)
       (loop (add1 i) in-mark)]))
  (get-output-string out))

;; rows: match rows (value start end groups)
;; lint-rows: list of hashes (severity rule position message) or #f
;; test-results: list of hashes (text expect pass reason) or #f, or the
;;   string "INVALID: <message>" when the pattern itself is broken
;; diagram-svg: inline SVG markup or #f
(define (report-html pattern text rows explain lint-rows test-results diagram-svg version)
  (define invalid? (and (string? test-results)
                        (string-prefix? test-results "INVALID: ")))
  (define error-message (and invalid? (substring test-results 9)))
  (define lint-rows*
    (and lint-rows
         (for/list ([w (in-list lint-rows)])
           (list (hash-ref w 'severity)
                 (hash-ref w 'rule)
                 (number->string (hash-ref w 'position))
                 (hash-ref w 'message)))))
  (define test-rows*
    (and (list? test-results)
         (for/list ([r (in-list test-results)])
           (list (hash-ref r 'text)
                 (hash-ref r 'expect)
                 (if (hash-ref r 'pass) "PASS" "FAIL")
                 (or (hash-ref r 'reason) "")))))
  (define failed-tests
    (and (list? test-results)
         (count (lambda (r) (not (hash-ref r 'pass))) test-results)))
  (define test-table
    (and (list? test-results)
         (table
          (list "text" "expect" "result" "reason")
          (for/list ([r (in-list test-results)])
            (define pass? (hash-ref r 'pass))
            (define reason (or (hash-ref r 'reason) ""))
            (list (hash-ref r 'text)
                  (hash-ref r 'expect)
                  (if pass?
                      "<span class=\"ok\">PASS</span>"
                      (format "<span class=\"bad\">FAIL</span> — ~a" reason))
                  reason)))))
  (format #<<EOF
<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8">
<title>RegexMate report — ~a</title>
<style>~a</style></head>
<body><div class="wrap">
<h1>RegexMate report</h1>
<div>
<span class="pill pill-accent">regexmate ~a</span>
<span class="pill">sample · ~a chars</span>
<span class="pill">~a match(es)</span>
~a
</div>
<h2>Pattern</h2>
<div class="pattern">~a</div>
~a
<h2>Sample with matches</h2>
<pre>~a</pre>
<h2>Matches</h2>
~a
<h2>Explanation</h2>
<pre>~a</pre>
~a
~a
<h2>Railroad diagram</h2>
<div class="diagram">~a</div>
<p class="meta">Generated by RegexMate ~a · <span class="mono">regexmate/v1</span> · local file, no network</p>
</div></body></html>
EOF
          (esc pattern)
          css
          (esc version)
          (number->string (string-length text))
          (number->string (length rows))
          (cond
            [invalid?
             "<span class=\"pill\" style=\"color:#8a2b1d;background:#fde8e6;border-color:#f0c4bd\">invalid regex</span>"]
            [(and test-table (zero? failed-tests))
             "<span class=\"pill\" style=\"color:#037a55;background:rgba(3,122,85,.1);border-color:rgba(3,122,85,.3)\">all tests passed</span>"]
            [(and test-table (positive? failed-tests))
             (format "<span class=\"pill\" style=\"color:#8a2b1d;background:#fde8e6;border-color:#f0c4bd\">~a test(s) failed</span>" failed-tests)]
            [else ""])
          (esc pattern)
          (if invalid?
              (format "<div class=\"err\">~a</div>" (esc error-message))
              "")
          (if invalid?
              (html-escape "—")
              (highlighted-sample text rows))
          (if invalid?
              (table (list "value" "start" "end" "groups") '())
              (table (list "value" "start" "end" "groups") rows))
          (esc (if invalid? "" explain))
          (if (and lint-rows* (pair? lint-rows*))
              (string-append "<h2>Lint findings</h2>"
                             (table (list "severity" "rule" "position" "message") lint-rows*))
              "")
          (if test-table
              (string-append "<h2>Test cases</h2>" test-table)
              "")
          (or diagram-svg "<em>diagram unavailable for this pattern</em>")
          (esc version)))

(provide report-html html-escape)
