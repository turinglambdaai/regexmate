#lang racket

;; Self-update from GitHub Releases.
;; Flow: check latest → compare semver → download platform archive +
;; its .sha256 → verify → extract with system tar → swap the install in
;; place (the rename trick keeps a running process alive on Windows) →
;; stale .old leftovers are cleaned on the next startup.

(require json
         net/url
         racket/file
         racket/port
         (only-in racket/string string-split string-prefix?))

(define UA "regexmate-updater")
(define RELEASES-API
  "https://api.github.com/repos/turinglambdaai/regexmate/releases/latest")

;; ---- platform & install layout --------------------------------------

(define (platform-id)
  (string-append
   (case (system-type)
     [(windows) "windows"]
     [(macosx) "macos"]
     [else "linux"])
   "-"
   (case (system-type 'arch)
     [(aarch64 arm64) "aarch64"]
     [else "x86_64"])))

(define (archive-extension)
  (if (eq? (system-type) 'windows) "zip" "tar.gz"))

;; overridable so tests can point the updater at a fake install
(define current-exe-path (make-parameter (find-system-path 'exec-file)))

(define (exe-path)
  (current-exe-path))

(define (install-dir)
  (define p (exe-path))
  (simplify-path
   (path-only (if (relative-path? p) (path->complete-path p) p))))

(define (exe-name)
  (path->string (file-name-from-path (exe-path))))

(define (old-exe-path)
  (path-replace-suffix (build-path (install-dir) (exe-name)) ".old"))

(define (old-lib-path)
  (build-path (install-dir)
              (string-append (path->string (path-replace-suffix (exe-name) "")) "lib.old")))

;; true when running as a distributed standalone binary
(define (installed-mode?)
  (member (exe-name) '("regexmate" "regexmate.exe")))

;; ---- pure-Racket SHA-256 (FIPS 180-4) --------------------------------

(define SHA256-K
  #(#x428a2f98 #x71374491 #xb5c0fbcf #xe9b5dba5 #x3956c25b #x59f111f1 #x923f82a4 #xab1c5ed5
    #xd807aa98 #x12835b01 #x243185be #x550c7dc3 #x72be5d74 #x80deb1fe #x9bdc06a7 #xc19bf174
    #xe49b69c1 #xefbe4786 #x0fc19dc6 #x240ca1cc #x2de92c6f #x4a7484aa #x5cb0a9dc #x76f988da
    #x983e5152 #xa831c66d #xb00327c8 #xbf597fc7 #xc6e00bf3 #xd5a79147 #x06ca6351 #x14292967
    #x27b70a85 #x2e1b2138 #x4d2c6dfc #x53380d13 #x650a7354 #x766a0abb #x81c2c92e #x92722c85
    #xa2bfe8a1 #xa81a664b #xc24b8b70 #xc76c51a3 #xd192e819 #xd6990624 #xf40e3585 #x106aa070
    #x19a4c116 #x1e376c08 #x2748774c #x34b0bcb5 #x391c0cb3 #x4ed8aa4a #x5b9cca4f #x682e6ff3
    #x748f82ee #x78a5636f #x84c87814 #x8cc70208 #x90befffa #xa4506ceb #xbef9a3f7 #xc67178f2))

(define (rotr32 x n)
  (bitwise-and (bitwise-ior (arithmetic-shift x (- n))
                            (arithmetic-shift x (- 32 n)))
               4294967295))

(define (word block i)
  (+ (* (bytes-ref block (* 4 i)) 16777216)
     (* (bytes-ref block (+ (* 4 i) 1)) 65536)
     (* (bytes-ref block (+ (* 4 i) 2)) 256)
     (bytes-ref block (+ (* 4 i) 3))))

(define (sha256-process! h block)
  (define w (make-vector 64 0))
  (for ([i (in-range 16)])
    (vector-set! w i (bitwise-and (word block i) 4294967295)))
  (for ([i (in-range 16 64)])
    (define s0 (bitwise-xor (rotr32 (vector-ref w (- i 15)) 7)
                            (rotr32 (vector-ref w (- i 15)) 18)
                            (arithmetic-shift (vector-ref w (- i 15)) -3)))
    (define s1 (bitwise-xor (rotr32 (vector-ref w (- i 2)) 17)
                            (rotr32 (vector-ref w (- i 2)) 19)
                            (arithmetic-shift (vector-ref w (- i 2)) -10)))
    (vector-set! w i
                 (bitwise-and (+ (vector-ref w (- i 16)) s0
                                 (vector-ref w (- i 7)) s1)
                              4294967295)))
  (define a (vector-ref h 0)) (define b (vector-ref h 1))
  (define c (vector-ref h 2)) (define d (vector-ref h 3))
  (define e (vector-ref h 4)) (define f (vector-ref h 5))
  (define g (vector-ref h 6)) (define hh (vector-ref h 7))
  (for ([i (in-range 64)])
    (define S1 (bitwise-xor (rotr32 e 6) (rotr32 e 11) (rotr32 e 25)))
    (define ch (bitwise-xor (bitwise-and e f) (bitwise-and (bitwise-not e) g)))
    (define t1 (bitwise-and (+ hh S1 ch (vector-ref SHA256-K i) (vector-ref w i))
                            4294967295))
    (define S0 (bitwise-xor (rotr32 a 2) (rotr32 a 13) (rotr32 a 22)))
    (define maj (bitwise-xor (bitwise-and a b) (bitwise-and a c) (bitwise-and b c)))
    (define t2 (bitwise-and (+ S0 maj) 4294967295))
    (set! hh g) (set! g f) (set! f e)
    (set! e (bitwise-and (+ d t1) 4294967295))
    (set! d c) (set! c b) (set! b a)
    (set! a (bitwise-and (+ t1 t2) 4294967295)))
  (for ([i (in-range 8)] [v (in-list (list a b c d e f g hh))])
    (vector-set! h i (bitwise-and (+ (vector-ref h i) v) 4294967295))))

(define (sha256-hex-from-port in)
  (define h (vector 1779033703 -1150833019 1013904242 -1521486534
                    1359893119 -1694144372 528734635 1541459225))
  (define total 0)
  ;; final padding for n trailing message bytes; when the 0x80 and the
  ;; 8-byte length cannot share one block (n >= 56), emit two blocks
  (define (process-pad! n block)
    (define bit-len (* 8 (+ total n)))
    (if (>= n 56)
        (let* ([full (make-bytes 64 0)])
          (bytes-copy! full 0 block 0 n)
          (bytes-set! full n #x80)
          (sha256-process! h full)
          (define tail (make-bytes 64 0))
          (for ([i (in-range 8)])
            (bytes-set! tail (+ 56 i)
                        (bitwise-and (arithmetic-shift bit-len (* -8 (- 7 i))) #xFF)))
          (sha256-process! h tail))
        (let ([padded (make-bytes 64 0)])
          (bytes-copy! padded 0 block 0 n)
          (bytes-set! padded n #x80)
          (for ([i (in-range 8)])
            (bytes-set! padded (+ 56 i)
                        (bitwise-and (arithmetic-shift bit-len (* -8 (- 7 i))) #xFF)))
          (sha256-process! h padded))))
  (let loop ()
    (define block (read-bytes 64 in))
    (cond
      ;; EOF: always process exactly one padding block
      [(eof-object? block) (process-pad! 0 #"")]
      [(= (bytes-length block) 64)
       (set! total (+ total 64))
       (sha256-process! h block)
       (loop)]
      [else
       (process-pad! (bytes-length block) block)]))
  (define digest
    (apply bytes
           (append*
            (for/list ([word32 (in-vector h)])
              (for/list ([shift (in-list '(24 16 8 0))])
                (bitwise-and (arithmetic-shift word32 (- shift)) #xFF))))))
  (define (byte-hex b)
    (string (string-ref "0123456789abcdef" (arithmetic-shift b -4))
            (string-ref "0123456789abcdef" (bitwise-and b #xF))))
  (string-append* (for/list ([b (in-bytes digest)]) (byte-hex b))))

(define (sha256-file path)
  (call-with-input-file path sha256-hex-from-port))

;; ---- version comparison -----------------------------------------------

(define (parse-version v)
  (define cleaned (string-trim (regexp-replace #rx"^v" (string-trim v) "")))
  (map (lambda (p) (string->number p))
       (string-split cleaned ".")))

(define (version<? a b)
  (define va (parse-version a))
  (define vb (parse-version b))
  (define len (max (length va) (length vb)))
  (define (pad v)
    (define extra (- len (length v)))
    (append v (make-list extra 0)))
  (let loop ([x (pad va)] [y (pad vb)])
    (cond
      [(null? x) #f]
      [(< (car x) (car y)) #t]
      [(> (car x) (car y)) #f]
      [else (loop (cdr x) (cdr y))])))

;; ---- HTTP --------------------------------------------------------------

;; content port with redirects followed (up to 10); no headers available
(define (http-get url-str)
  (get-pure-port (string->url url-str)
                 (list (string-append "User-Agent: " UA))
                 #:redirections 10))

(define (fetch-json url)
  (define in (http-get url))
  (define body (port->string in))
  (close-input-port in)
  (string->jsexpr body))

;; download to file; on-progress gets byte totals while streaming
(define (download-to-file url dest on-progress)
  (define in (http-get url))
  (call-with-output-file dest
    (lambda (out)
      (let loop ([done 0])
        (define chunk (read-bytes 65536 in))
        (unless (eof-object? chunk)
          (write-bytes chunk out)
          (define total (+ done (bytes-length chunk)))
          (when on-progress (on-progress total))
          (loop total))))
    #:exists 'truncate)
  (close-input-port in))

;; ---- release metadata ---------------------------------------------------

;; -> (hash tag assets); assets: (list (hash name url))
(define (fetch-latest-release)
  (define j (fetch-json RELEASES-API))
  (hasheq 'tag (hash-ref j 'tag_name)
          'assets
          (for/list ([a (in-list (hash-ref j 'assets '()))])
            (hasheq 'name (hash-ref a 'name)
                    'url (hash-ref a 'browser_download_url)))))

;; archive asset name for this platform, e.g.
;; "regexmate-windows-x86_64-v1.2.0.zip"
(define (asset-name version-tag)
  (string-append "regexmate-" (platform-id) "-" version-tag "." (archive-extension)))

;; ---- extraction ----------------------------------------------------------

;; prefer the Windows-native bsdtar (handles drive letters); fall back to
;; PATH tar, which may be an MSYS GNU tar needing POSIX-style paths
(define (find-tar)
  (if (eq? (system-type) 'windows)
      (let ([sys-tar (build-path "C:" "Windows" "System32" "tar.exe")])
        (if (file-exists? sys-tar)
            sys-tar
            (find-executable-path "tar")))
      (find-executable-path "tar")))

(define (tar-path-string p)
  (define s (path->string p))
  (define m (regexp-match #rx"^([A-Za-z]):[\\/](.*)" s))
  (if (and (eq? (system-type) 'windows)
           m
           (not (file-exists? (build-path "C:" "Windows" "System32" "tar.exe"))))
      ;; MSYS GNU tar form: C:\x\y -> /c/x/y
      (string-append "/" (string-downcase (cadr m)) "/"
                     (string-replace (caddr m) "\\" "/"))
      s))

(define (extract-archive archive dest)
  (make-directory* dest)
  (define tar (find-tar))
  (unless tar
    (error 'update "system tar not found; cannot extract the update archive"))
  (define null-path (if (eq? (system-type) 'windows) "NUL" "/dev/null"))
  (call-with-output-file null-path
    (lambda (sink)
      (parameterize ([current-output-port sink]
                     [current-error-port sink])
        ;; system* returns a boolean, not an exit code
        (unless (system* tar "-xf" (tar-path-string archive)
                         "-C" (tar-path-string dest))
          (error 'update "archive extraction failed")))))
  #t)

(define (rmtree path)
  (with-handlers ([exn:fail? (lambda (e) (void))])
    (delete-directory/files path #:must-exist? #f)))

;; remove leftovers from a previous update; safe to call at any startup
(define (cleanup-stale-updates)
  (when (installed-mode?)
    (rmtree (old-exe-path))
    (rmtree (old-lib-path))
    (define dir (install-dir))
    (with-handlers ([exn:fail? (lambda (e) (void))])
      (for ([p (in-list (directory-list dir #:build? #t))])
        (define n (path->string (file-name-from-path p)))
        (when (string-prefix? n "regexmate-update-")
          (rmtree p))))))

;; swap a staged install (new exe path + optional new lib dir) into
;; install-dir; renames keep a running process alive even on Windows;
;; leftover .old runtime files are removed by the next startup
(define (swap-install new-exe new-lib)
  (define dir (install-dir))
  (define name (exe-name))
  (define cur-exe (build-path dir name))
  (define cur-lib (build-path dir "lib"))
  ;; move current exe and lib aside
  (when (file-exists? cur-exe)
    (rmtree (old-exe-path))
    (rename-file-or-directory cur-exe (old-exe-path) #f))
  (when (and new-lib (directory-exists? cur-lib))
    (rmtree (old-lib-path))
    (with-handlers ([exn:fail? (lambda (e) (void))])
      (rename-file-or-directory cur-lib (old-lib-path) #f)))
  ;; move new files in
  (rename-file-or-directory new-exe cur-exe)
  (when (and new-lib (directory-exists? new-lib))
    (rename-file-or-directory new-lib (build-path dir "lib")))
  ;; best-effort cleanup (fails while this process still runs on Windows;
  ;; the next startup finishes the job)
  (rmtree (path-only new-exe))
  (rmtree (old-exe-path))
  (rmtree (old-lib-path)))

(provide current-exe-path find-tar tar-path-string
         platform-id archive-extension exe-path install-dir exe-name
         installed-mode? sha256-file sha256-hex-from-port parse-version version<?
         fetch-latest-release asset-name download-to-file extract-archive
         swap-install cleanup-stale-updates)
