#lang racket

(require rackunit
         racket/file
         racket/path
         "../core/updater.rkt")

(define updater-tests
  (test-suite
   "updater"

   ;; SHA-256 (FIPS 180-4 vectors + padding boundaries)
   (test-case "sha256 vectors"
     (define (hb b) (call-with-input-bytes b sha256-hex-from-port))
     (check-equal? (hb #"") "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
     (check-equal? (hb #"abc") "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
     (check-equal? (hb #"abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq")
                   "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
     (check-equal? (hb (make-bytes 55 #x61))
                   "9f4390f8d30c2dd92ec9f095b65e2b9ae9b0a925a5258e241c9f1e910f734318")
     (check-equal? (hb (make-bytes 56 #x61))
                   "b35439a4ac6f0948b6d6f9e3c6af0f5f590ce20f1bde7090ef7970686ec6738a")
     (check-equal? (hb (make-bytes 64 #x61))
                   "ffe054fe7ae0cb6dc65c3af9b61d5209f439851db43d0ba5997337df154668eb")
     (check-equal? (hb (make-bytes 119 #x61))
                   "31eba51c313a5c08226adf18d4a359cfdfd8d2e816b13f4af952f7ea6584dcfb"))

   (test-case "sha256-file on disk"
     (define tmp (make-temporary-file "rmsha~a"))
     (with-output-to-file tmp
       (lambda () (display "abc")) #:exists 'truncate)
     (check-equal? (sha256-file tmp)
                   "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
     (delete-file tmp))

   ;; version comparison
   (test-case "version ordering"
     (check-true (version<? "1.1.0" "1.2.0"))
     (check-true (version<? "v1.1.0" "1.2.0"))
     (check-true (version<? "1.9.0" "1.10.0"))        ; numeric, not lexicographic
     (check-false (version<? "1.2.0" "1.2.0"))
     (check-false (version<? "1.2.1" "1.2.0"))
     (check-true (version<? "1.2" "1.2.1"))           ; short form pads with zeros
     (check-false (version<? "1.2.0" "1.2")))

   (test-case "parse-version"
     (check-equal? (parse-version "v1.2.3") '(1 2 3))
     (check-equal? (parse-version "1.2.3") '(1 2 3)))

   ;; platform asset naming
   (test-case "platform id and asset name"
     (define pid (platform-id))
     (check-true (regexp-match? #px"^(windows|linux|macos)-(x86_64|aarch64)$" pid))
     (check-true (string-prefix? (asset-name "v9.9.9")
                                 (string-append "regexmate-" pid "-v9.9.9.")))
     (check-true (or (string-suffix? (asset-name "v9.9.9") ".zip")
                     (string-suffix? (asset-name "v9.9.9") ".tar.gz"))))

   ;; running from racket -e is not standalone mode
   (test-case "installed-mode is false for the interpreter"
     (check-false (installed-mode?)))

   ;; swap mechanics: staged exe+lib replace the install, leftovers clean up
   (test-case "swap-install and cleanup"
     (define tmp (make-temporary-file "rmswap~a" 'directory))
     (define install (build-path tmp "install"))
     (define stage (build-path tmp "stage"))
     (make-directory* install)
     (make-directory* stage)
     ;; fake current install
     (call-with-output-file (build-path install "regexmate.exe")
       (lambda (o) (display "old-exe" o)) #:exists 'truncate)
     (make-directory* (build-path install "lib"))
     (call-with-output-file (build-path install "lib" "runtime.dll")
       (lambda (o) (display "old-lib" o)) #:exists 'truncate)
     ;; fake staged update
     (call-with-output-file (build-path stage "regexmate.exe")
       (lambda (o) (display "new-exe" o)) #:exists 'truncate)
     (make-directory* (build-path stage "lib"))
     (call-with-output-file (build-path stage "lib" "runtime.dll")
       (lambda (o) (display "new-lib" o)) #:exists 'truncate)

     (parameterize ([current-exe-path (build-path install "regexmate.exe")])
       (swap-install (build-path stage "regexmate.exe")
                     (build-path stage "lib"))
       (check-equal? (file->string (build-path install "regexmate.exe")) "new-exe")
       (check-equal? (file->string (build-path install "lib" "runtime.dll")) "new-lib")
       (cleanup-stale-updates)
       (check-false (file-exists? (build-path install "regexmate.exe.old")))
       (check-false (directory-exists? (build-path install "lib.old"))))
     (delete-directory/files tmp))))

(provide updater-tests)
