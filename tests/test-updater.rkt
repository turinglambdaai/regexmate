#lang racket

(require rackunit
         crypto
         (only-in crypto/libcrypto libcrypto-factory)
         json
         net/base64
         racket/file
         racket/port
         racket/string
         (except-in rivet/distribution version<? platform-symbol architecture-symbol)
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
                                  "/update-manifest.json"))
     (dynamic-wind
       (lambda () (putenv "RIVET_UPDATE_BASE_URL" "https://example.com/staging/"))
       (lambda ()
         (check-equal? (manifest-url) "https://example.com/staging/update-manifest.json"))
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
                                               (make-string 64 #\a) 1 'targz '() #f))))
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
                                               (make-string 64 #\a) 1 'exe '() #f)
                              (update-artifact host-platform host-arch
                                               "https://example.com/mine"
                                               (make-string 64 #\b) 2 archive-kind '() #f)
                              (update-artifact 'linux 'x64
                                               "https://example.com/linux"
                                               (make-string 64 #\c) 3 'targz '() #f))))
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

   ;; the report the GUI's Check-for-Updates surface renders, with the
   ;; network check injected
   (test-case "update-check-report maps check outcomes"
     (define manifest
       (update-manifest regexmate-identifier "9.9.8" 42 'stable
                        "2026-10-09T00:00:00Z" "0.0.0" #f #t 100
                        (list (update-artifact 'macos 'arm64
                                               "https://example.com/a.tar.gz"
                                               (make-string 64 #\a) 1 'targz '() #f))))
     (check-equal? (update-check-report (lambda () #f))
                   (list "up-to-date"))
     (check-equal?
      (update-check-report
       (lambda () (update-plan manifest
                               (car (update-manifest-artifacts manifest)))))
      (list "available" "9.9.8"))
     (define failed
       (update-check-report
        (lambda () (error 'check-for-update "the feed is unreachable"))))
     (check-equal? (car failed) "offline")
     (check-true (string-contains? (cadr failed) "unreachable"))
     ;; a failure message longer than the report cap is truncated, not dropped
     (define long
       (update-check-report
        (lambda () (error 'check-for-update (make-string 500 #\x)))))
     (check-equal? (string-length (cadr long)) 202))  ; 200 chars + " …"

   (test-case "pick-artifact: standalone installs take the exe"
     (define host-platform (platform-symbol))
     (define host-arch (architecture-symbol))
     (define manifest
       (update-manifest regexmate-identifier "9.9.8" 42 'stable
                        "2026-10-09T00:00:00Z" "0.0.0" #f #t 100
                        (list (update-artifact host-platform host-arch
                                               "https://example.com/archive"
                                               (make-string 64 #\a) 1
                                               (archive-installer-kind) '() #f)
                              (update-artifact host-platform host-arch
                                               "https://example.com/standalone.exe"
                                               (make-string 64 #\b) 2 'exe '() #f))))
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
                        (archive-installer-kind) '() #f))
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

   ;; ---- extraction ----------------------------------------------------------
   (test-case "extract-archive unpacks a tarball"
     (define tmp (make-temporary-file "rmtar~a" 'directory))
     (define payload (build-path tmp "payload"))
     (make-directory* payload)
     (call-with-output-file (build-path payload "regexmate")
       (lambda (o) (display "hi" o)) #:exists 'truncate)
     (define tarball (build-path tmp "a.tar.gz"))
     (define tar (find-tar))
     (unless tar (error 'extract-test "system tar not found"))
     (parameterize ([current-output-port (open-output-nowhere)]
                    [current-error-port (open-output-nowhere)])
       (system* tar "-czf" (path->string tarball)
                "-C" (path->string payload) "regexmate"))
     (define out (build-path tmp "out"))
     (extract-archive tarball out)
     (check-equal? (file->string (build-path out "regexmate")) "hi")
     (delete-directory/files tmp))

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

   ;; A Windows ZIP created by `raco distribute stage/bin` keeps its
   ;; patched runtime DLLs in bin/lib, not the Unix root/lib location.
   ;; Verify both fresh bin installs and upgrades of the legacy root layout;
   ;; a wrong standalone classification would select a signed .exe payload
   ;; instead of the signed .zip and silently lose the GUI/runtime.
   (test-case "Windows bin-layout ZIP keeps signed archive update selection and runtime"
     (when (eq? (platform-symbol) 'windows)
       (define tmp (make-temporary-file "rmwinbin~a" 'directory))
       (define root (build-path tmp "installed"))
       (define staged (build-path tmp "unpacked"))
       (make-directory* (build-path root "bin" "lib"))
       (make-directory* (build-path root "gui"))
       (make-directory* (build-path staged "bin" "lib"))
       (make-directory* (build-path staged "gui"))
       (for ([entry (in-list
                     (list (cons (build-path root "bin" "regexmate.exe") "old-exe")
                           (cons (build-path root "bin" "lib" "runtime.dll") "old-lib")
                           (cons (build-path root "gui" "RivetHost.exe") "old-gui")
                           (cons (build-path staged "bin" "regexmate.exe") "new-exe")
                           (cons (build-path staged "bin" "lib" "runtime.dll") "new-lib")
                           (cons (build-path staged "gui" "RivetHost.exe") "new-gui")))])
         (call-with-output-file (car entry)
           (lambda (out) (display (cdr entry) out))
           #:exists 'truncate))
       (parameterize ([current-exe-path (build-path root "bin" "regexmate.exe")])
         (check-equal? (install-root) root)
         (check-false (standalone-install?))
         (define-values (new-exe new-lib new-gui) (staged-pieces staged))
         (check-equal? new-exe (build-path staged "bin" "regexmate.exe"))
         (check-equal? new-lib (build-path staged "bin" "lib"))
         (install-update! new-exe new-lib new-gui)
         (check-equal? (file->string (build-path root "bin" "regexmate.exe")) "new-exe")
         (check-equal? (file->string (build-path root "bin" "lib" "runtime.dll")) "new-lib")
         (check-equal? (file->string (build-path root "gui" "RivetHost.exe")) "new-gui")
         (check-false (directory-exists? (build-path root "lib")))
         (cleanup-stale-updates)
         (check-false (directory-exists? (build-path root "bin" "lib.old"))))
       (delete-directory/files tmp)))

   (test-case "legacy Windows flat ZIP upgrades from a staged bin-layout ZIP"
     (when (eq? (platform-symbol) 'windows)
       (define tmp (make-temporary-file "rmwinlegacy~a" 'directory))
       (define root (build-path tmp "installed"))
       (define staged (build-path tmp "unpacked"))
       (make-directory* (build-path root "lib"))
       (make-directory* (build-path staged "bin" "lib"))
       (for ([entry (in-list
                     (list (cons (build-path root "regexmate.exe") "old-exe")
                           (cons (build-path root "lib" "runtime.dll") "old-lib")
                           (cons (build-path staged "bin" "regexmate.exe") "new-exe")
                           (cons (build-path staged "bin" "lib" "runtime.dll") "new-lib")))])
         (call-with-output-file (car entry)
           (lambda (out) (display (cdr entry) out))
           #:exists 'truncate))
       (parameterize ([current-exe-path (build-path root "regexmate.exe")])
         (check-equal? (install-root) root)
         (check-false (standalone-install?))
         (define-values (new-exe new-lib _new-gui) (staged-pieces staged))
         (check-equal? new-lib (build-path staged "bin" "lib"))
         (install-update! new-exe new-lib #f)
         ;; Keep the existing executable's location instead of relocating a
         ;; live Windows process; the Racket DLL path remains exe-relative.
         (check-equal? (file->string (build-path root "regexmate.exe")) "new-exe")
         (check-equal? (file->string (build-path root "lib" "runtime.dll")) "new-lib")
         (check-false (directory-exists? (build-path root "bin")))
         (cleanup-stale-updates)
         (check-false (directory-exists? (build-path root "lib.old"))))
       (delete-directory/files tmp)))

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
