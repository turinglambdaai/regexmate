#lang racket

(require rackunit
         crypto
         (only-in crypto/libcrypto libcrypto-factory)
         json
         net/base64
         racket/file
         racket/port
         (except-in rivet/distribution version<?)
         "../core/updater.rkt"
         "../version.rkt")

;; rivet/distribution pins libcrypto at module load; match it here so the
;; generated test keys come from the same provider the updater uses
(crypto-factories (list libcrypto-factory))

(define updater-tests
  (test-suite
   "updater"

   ;; ---- release identity -------------------------------------------------
   (test-case "embedded public key decodes to an Ed25519 key"
     (define key (embedded-public-key))
     (check-true (pk-key? key))
     (define datum (pk-key->datum key 'rkt-public))
     (check-true (and (list? datum) (pair? datum) (eq? (car datum) 'eddsa)))
     (check-true (and (member 'ed25519 datum) #t)))

   (test-case "signing identity constants are present"
     (check-equal? regexmate-update-key-id "regexmate-2026-10")
     (check-equal? regexmate-identifier "site.jrtx.regexmate")
     (check-equal? regexmate-channel 'stable)
     ;; SPKP DER blobs start with the standard 12-byte Ed25519 prefix
     (check-true (string-prefix? regexmate-update-public-key-b64
                                 "MCowBQYDK2VwAyEA")))

   (test-case "manifest url: default and env override"
     (check-equal? (manifest-url)
                   (string-append regexmate-default-update-base-url
                                  "/update-stable.json"))
     (dynamic-wind
       (lambda () (putenv "RIVET_UPDATE_BASE_URL" "https://example.com/staging/"))
       (lambda ()
         (check-equal? (manifest-url) "https://example.com/staging/update-stable.json"))
       (lambda () (putenv "RIVET_UPDATE_BASE_URL" ""))))

   ;; ---- platform & install layout ---------------------------------------
   (test-case "platform id and archive kind agree"
     (define pid (platform-symbol))
     (check-true (and (member pid '(windows macos linux)) #t) "platform symbol")
     (check-true (and (member (architecture-symbol) '(x64 arm64)) #t) "arch symbol")
     (check-equal? (archive-installer-kind)
                   (if (eq? pid 'windows) 'zip 'targz)))

   ;; running from racket -e is not a distributed binary
   (test-case "installed-mode is false for the interpreter"
     (check-false (installed-mode?)))

   ;; ---- version comparison ------------------------------------------------
   (test-case "version ordering"
     (check-true (version<? "0.5.0" "0.6.0"))
     (check-true (version<? "v0.5.0" "0.6.0"))
     (check-true (version<? "0.9.0" "0.10.0"))         ; numeric, not lexicographic
     (check-false (version<? "0.6.0" "0.6.0"))
     (check-false (version<? "0.6.1" "0.6.0"))
     (check-true (version<? "0.6" "0.6.1"))            ; short form pads with zeros
     (check-false (version<? "0.6.0" "0.6")))

   (test-case "parse-version"
     (check-equal? (parse-version "v0.6.0") '(0 6 0))
     (check-equal? (parse-version "0.6.0") '(0 6 0)))

   ;; ---- signed manifest trust machinery -----------------------------------
   ;; The public half of a generated key verifies a manifest signed with its
   ;; private half; any payload mutation and any unexpected key id is
   ;; rejected. This is exactly the trust path `regexmate update` walks,
   ;; minus the HTTPS fetch.
   (test-case "ed25519 manifest sign / verify / reject"
     (define impl (get-pk 'eddsa (list libcrypto-factory)))
     (define private-key (generate-private-key impl '((curve ed25519))))
     (define public-key
       (datum->pk-key (pk-key->datum private-key 'SubjectPublicKeyInfo)
                      'SubjectPublicKeyInfo))
     (define manifest
       (update-manifest regexmate-identifier "9.9.8" 42 'stable
                        "2026-10-09T00:00:00Z" "0.0.0" #f #t 100
                        (list (update-artifact 'macos 'arm64
                                               "https://example.com/a.tar.gz"
                                               (make-string 64 #\a) 1 'targz '()))))
     (define signed
       (with-output-to-bytes
         (lambda () (write-signed-manifest manifest private-key
                                           regexmate-update-key-id))))
     (define verified
       (verify-signed-manifest (open-input-bytes signed) public-key
                               #:key-id regexmate-update-key-id))
     (check-equal? (update-manifest-version verified) "9.9.8")

     ;; wrong key id, even with a valid signature, is rejected
     (check-exn #rx"unexpected key"
                (lambda ()
                  (verify-signed-manifest (open-input-bytes signed) public-key
                                          #:key-id "someone-else-2026")))

     ;; any payload mutation is rejected even when the JSON stays valid
     (define wrapper (read-json (open-input-bytes signed)))
     (define payload (base64-string->bytes (hash-ref wrapper 'payload)))
     (define tampered
       (hash-set wrapper 'payload
                 (bytes->base64-string (bytes-append payload #" "))))
     (define tampered-out (open-output-bytes))
     (write-json tampered tampered-out)
     (check-exn #rx"signature verification failed"
                (lambda ()
                  (verify-signed-manifest
                   (open-input-bytes (get-output-bytes tampered-out))
                   public-key
                   #:key-id regexmate-update-key-id))))

   ;; ---- artifact picking ----------------------------------------------------
   ;; pick-artifact must disambiguate windows archives from the standalone
   ;; exe and always honor platform + architecture. Both installer kinds are
   ;; listed for the running platform so the test is host-independent.
   (test-case "pick-artifact: distributed installs take the archive"
     (define host-platform (platform-symbol))
     (define host-arch (architecture-symbol))
     (define archive-kind (archive-installer-kind))
     (define manifest
       (update-manifest regexmate-identifier "9.9.8" 42 'stable
                        "2026-10-09T00:00:00Z" "0.0.0" #f #t 100
                        (list (update-artifact host-platform host-arch
                                               "https://example.com/other.zip"
                                               (make-string 64 #\a) 1 'exe '())
                              (update-artifact host-platform host-arch
                                               "https://example.com/mine"
                                               (make-string 64 #\b) 2 archive-kind '())
                              (update-artifact 'linux 'x64
                                               "https://example.com/linux"
                                               (make-string 64 #\c) 3 'targz '()))))
     (define tmp (make-temporary-file "rmpick~a" 'directory))
     (make-directory* (build-path tmp "lib"))    ; distributed layout marker
     (parameterize ([current-exe-path (build-path tmp "regexmate.exe")])
       (check-true (installed-mode?))
       (check-false (standalone-install?))
       (define picked (pick-artifact manifest))
       (check-equal? (update-artifact-platform picked) host-platform)
       (check-equal? (update-artifact-installer picked) archive-kind)
       (check-equal? (update-artifact-url picked) "https://example.com/mine"))
     (delete-directory/files tmp))

   (test-case "pick-artifact: standalone installs take the exe"
     (define host-platform (platform-symbol))
     (define host-arch (architecture-symbol))
     (define manifest
       (update-manifest regexmate-identifier "9.9.8" 42 'stable
                        "2026-10-09T00:00:00Z" "0.0.0" #f #t 100
                        (list (update-artifact host-platform host-arch
                                               "https://example.com/archive"
                                               (make-string 64 #\a) 1
                                               (archive-installer-kind) '())
                              (update-artifact host-platform host-arch
                                               "https://example.com/standalone.exe"
                                               (make-string 64 #\b) 2 'exe '()))))
     (define tmp (make-temporary-file "rmpick~a" 'directory))
     ;; no lib/ next to the exe: a standalone single-file install
     (parameterize ([current-exe-path (build-path tmp "regexmate.exe")])
       (check-true (standalone-install?))
       (define picked (pick-artifact manifest))
       (check-equal? (update-artifact-installer picked) 'exe)
       (check-equal? (update-artifact-url picked) "https://example.com/standalone.exe"))
     (delete-directory/files tmp))

   ;; ---- download verification -----------------------------------------------
   (test-case "verify-downloaded accepts matching bytes and rejects tampering"
     (define tmp (make-temporary-file "rmdown~a"))
     (define payload #"update-payload-0123456789")
     (call-with-output-file tmp
       (lambda (out) (write-bytes payload out)) #:exists 'truncate)
     (define artifact
       (update-artifact (platform-symbol) (architecture-symbol)
                        "https://example.com/a.tar.gz"
                        (string-downcase (sha256-file/hex tmp))
                        (file-size tmp)
                        (archive-installer-kind) '()))
     (define plan
       (update-plan (update-manifest regexmate-identifier "9.9.8" 42 'stable
                                     "2026-10-09T00:00:00Z" "0.0.0" #f #t 100
                                     (list artifact))
                    artifact))
     (check-equal? (verify-downloaded! plan tmp) tmp)
     ;; flip one byte: size matches, digest must not
     (call-with-output-file tmp
       (lambda (out) (write-bytes #"X" out 0 1) (write-bytes payload out 1))
       #:exists 'truncate)
     (check-exn #rx"SHA-256 does not match"
                (lambda () (verify-downloaded! plan tmp)))
     (delete-file tmp))

   ;; ---- staged layout + swap mechanics ---------------------------------------
   ;; unix distribute nests the exe under bin/ with lib/ and gui/ at the
   ;; root; windows distribute is flat. Both layouts swap whole: exe, lib
   ;; and gui all move; leftovers are cleaned up.
   (test-case "staged-pieces and install-update! swap bin-layout installs"
     (define tmp (make-temporary-file "rmswap~a" 'directory))
     (define install (build-path tmp "install"))
     (define stage (build-path tmp "stage"))
     (make-directory* (build-path install "bin"))
     (make-directory* (build-path install "lib"))
     (make-directory* (build-path install "gui"))
     ;; current install
     (call-with-output-file (build-path install "bin" "regexmate")
       (lambda (o) (display "old-exe" o)) #:exists 'truncate)
     (call-with-output-file (build-path install "lib" "runtime.so")
       (lambda (o) (display "old-lib" o)) #:exists 'truncate)
     (call-with-output-file (build-path install "gui" "RivetHost")
       (lambda (o) (display "old-gui" o)) #:exists 'truncate)
     ;; staged update (extracted archive)
     (define extract (build-path stage "unpacked"))
     (make-directory* (build-path extract "bin"))
     (make-directory* (build-path extract "lib"))
     (make-directory* (build-path extract "gui"))
     (call-with-output-file (build-path extract "bin" "regexmate")
       (lambda (o) (display "new-exe" o)) #:exists 'truncate)
     (call-with-output-file (build-path extract "lib" "runtime.so")
       (lambda (o) (display "new-lib" o)) #:exists 'truncate)
     (call-with-output-file (build-path extract "gui" "RivetHost")
       (lambda (o) (display "new-gui" o)) #:exists 'truncate)

     (parameterize ([current-exe-path (build-path install "bin" "regexmate")])
       (check-true (installed-mode?))
       (define-values (new-exe new-lib new-gui)
         (staged-pieces extract))
       (check-equal? (file->string new-exe) "new-exe")
       (check-equal? (file->string (build-path new-lib "runtime.so")) "new-lib")
       (check-equal? (file->string (build-path new-gui "RivetHost")) "new-gui")
       (install-update! new-exe new-lib new-gui)
       (check-equal? (file->string (build-path install "bin" "regexmate")) "new-exe")
       (check-equal? (file->string (build-path install "lib" "runtime.so")) "new-lib")
       (check-equal? (file->string (build-path install "gui" "RivetHost")) "new-gui")
       (cleanup-stale-updates)
       (check-false (file-exists? (build-path install "bin" "regexmate.old")))
       (check-false (directory-exists? (build-path install "lib.old")))
       (check-false (directory-exists? (build-path install "gui.old"))))
     (delete-directory/files tmp))

   (test-case "install-update! swaps flat layouts and bare standalone exes"
     (define tmp (make-temporary-file "rmswap~a" 'directory))
     (define install (build-path tmp "install"))
     (define stage (build-path tmp "stage"))
     (make-directory* install)
     (make-directory* stage)
     (call-with-output-file (build-path install "regexmate.exe")
       (lambda (o) (display "old-exe" o)) #:exists 'truncate)
     (call-with-output-file (build-path stage "regexmate.exe")
       (lambda (o) (display "new-exe" o)) #:exists 'truncate)

     (parameterize ([current-exe-path (build-path install "regexmate.exe")])
       (install-update! (build-path stage "regexmate.exe") #f #f)
       (check-equal? (file->string (build-path install "regexmate.exe")) "new-exe")
       (cleanup-stale-updates)
       (check-false (file-exists? (build-path install "regexmate.exe.old"))))
     (delete-directory/files tmp))))

(provide updater-tests)
