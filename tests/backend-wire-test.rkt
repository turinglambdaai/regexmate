#lang racket/base

(require rackunit racket/match racket/path
         rivet/backend rivet/protocol)

(define test-directory
  (or (current-load-relative-directory) (current-directory)))
(define backend-path
  (simplify-path (build-path test-directory ".." "app" "backend.rkt")))
(void (dynamic-require backend-path #f))

(define-values (server-in client-out) (make-pipe))
(define-values (client-in server-out) (make-pipe))
(define server-thread (thread (lambda () (serve server-in server-out))))

(define (read-frame/timeout label)
  (define result (box #f))
  (define failure (box #f))
  (define reader
    (thread
     (lambda ()
       (with-handlers ([exn:fail? (lambda (exception)
                                    (set-box! failure exception))])
         (set-box! result (read-frame client-in))))))
  (unless (sync/timeout 30 reader)
    (fail (format "timed out waiting for ~a" label)))
  (when (unbox failure) (raise (unbox failure)))
  (unbox result))

(define next-id 0)
(define (call-rpc name . arguments)
  (set! next-id (add1 next-id))
  (define id next-id)
  (write-frame (frame message:request id (encode-value (cons name arguments)))
               client-out)
  (flush-output client-out)
  (let loop ()
    (define response (read-frame/timeout name))
    (match (frame-type response)
      [(== message:event) (loop)]
      [(== message:response)
       (check-equal? (frame-id response) id)
       (decode-value (frame-payload response))]
      [(== message:error)
       (fail (format "backend rejected ~a: ~e"
                     name (decode-value (frame-payload response))))]
      [_ (loop)])))

(dynamic-wind
 void
 (lambda ()
   (define hello (read-frame/timeout "RVT1 hello"))
   (check-equal? (frame-type hello) message:hello)
   (check-equal? (decode-value (frame-payload hello))
                 (list "rivet" protocol-version))
   (check-equal? (call-rpc "status" "\\d+") "ok")
   (define rows
     (call-rpc "match-rows" "\\d+" "Order 12345 ships in 2026"))
   (check-equal? (length rows) 2)
   (check-equal? (car (car rows)) "12345")
   (check-equal? (cadr (car rows)) "6")
   (check-true (positive? (bytes-length (call-rpc "diagram-png" "a+")))))
 (lambda () (kill-thread server-thread)))
