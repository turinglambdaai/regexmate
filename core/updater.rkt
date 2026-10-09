#lang racket/base

;; Online update for RegexMate, built on rivet/distribution. `regexmate
;; update` fetches the Ed25519-signed channel manifest (update-stable.json,
;; published alongside each GitHub release), verifies the signature against
;; the embedded public key, applies rivet's selection policy (identity,
;; channel, SemVer precedence, rollout), and downloads the artifact for this
;; install — byte size and SHA-256 are checked against the signed manifest
;; before anything is trusted. The archive is extracted with the system tar
;; and swapped into place (renames keep a running process alive on
;; Windows); stale .old leftovers are cleaned on the next startup.
;;
;; The flow is deliberately CLI-shaped: the GUI ships inside the same
;; archive and cannot replace itself while running, so the CLI performs the
;; swap and the user restarts the GUI afterwards.

(require crypto
         (only-in crypto/libcrypto libcrypto-factory)
         net/base64
         net/head
         net/url
         rivet/distribution
         racket/file
         racket/list
         racket/path
         racket/port
         (only-in racket/system system*)
         racket/string
         "../version.rkt")

(provide (struct-out update-plan)
         current-exe-path find-tar tar-path-string
         platform-symbol architecture-symbol archive-installer-kind
         exe-path install-dir install-root exe-name
         installed-mode? standalone-install?
         embedded-public-key manifest-url
         parse-version version<? check-for-update pick-artifact
         download-candidate! verify-downloaded!
         extract-archive staged-pieces install-update! cleanup-stale-updates
         rmtree)

;; rivet/distribution pins the provider set to libcrypto alone (official
;; Racket distributions bundle OpenSSL on every desktop target); pin it here
;; too so key decoding never instantiates other factories.
(crypto-factories (list libcrypto-factory))

(define maximum-download-bytes (* 800 1024 1024))

;; a CLI has no local state to make a rollout bucket sticky, and releases
;; go out at 100% anyway; bucket 0 always sees the release
(define update-rollout-bucket 0)

;; ---- platform & install layout --------------------------------------

(define (platform-symbol)
  (case (system-type 'os)
    [(macosx) 'macos]
    [(windows) 'windows]
    [else 'linux]))

(define (architecture-symbol)
  (case (system-type 'arch)
    [(aarch64 arm64) 'arm64]
    [else 'x64]))

;; installer kind of the full platform archive in the signed manifest
(define (archive-installer-kind)
  (if (eq? (system-type) 'windows) 'zip 'targz))

;; overridable so tests can point the updater at a fake install
(define current-exe-path (make-parameter (find-system-path 'exec-file)))

(define (exe-path)
  (current-exe-path))

(define (exe-name)
  (path->string (file-name-from-path (exe-path))))

;; directory holding the running exe (never ends in a separator)
(define (install-dir)
  (define p (exe-path))
  (define full (if (relative-path? p) (path->complete-path p) p))
  ;; simplify-path preserves a trailing separator on directories and
  ;; file-name-from-path then reports #f; rebuild via split-path to get a
  ;; clean directory path
  (define-values (base name _must-be-dir?)
    (split-path (simplify-path (path-only full))))
  (simplify-path (build-path base name)))

;; distribution root: unix distribute nests the exe under bin/, flat
;; Windows layouts keep everything next to the exe
(define (install-root)
  (define dir (install-dir))
  (define name
    (regexp-replace #rx"/+$" (path->string (file-name-from-path dir)) ""))
  (if (string=? name "bin")
      (simplify-path (build-path dir 'up))
      dir))

;; true when running as a distributed binary (regexmate / regexmate.exe)
(define (installed-mode?)
  (and (member (exe-name) '("regexmate" "regexmate.exe")) #t))

;; distributed CLI archives carry a shared runtime in lib/ at the root;
;; the standalone single-file exe embeds its runtime and has none
(define (standalone-install?)
  (not (directory-exists? (build-path (install-root) "lib"))))

;; backup locations for pieces parked during a swap
(define (old-exe-path)
  (path-replace-suffix (build-path (install-dir) (exe-name)) ".old"))
(define (old-lib-path)
  (build-path (install-root) "lib.old"))
(define (old-gui-path)
  (build-path (install-root) "gui.old"))

;; ---- trust -------------------------------------------------------------

;; the public half of the release signing key; the private half never ships
(define (embedded-public-key)
  (datum->pk-key (base64-string->bytes regexmate-update-public-key-b64)
                 'SubjectPublicKeyInfo))

;; channel manifest location; RIVET_UPDATE_BASE_URL overrides for tests
(define (manifest-url)
  (define base
    (or (getenv "RIVET_UPDATE_BASE_URL") regexmate-default-update-base-url))
  (string-append (string-trim base "/" #:right? #t) "/update-stable.json"))

;; ---- version comparison ------------------------------------------------

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

;; ---- transport -----------------------------------------------------------
;; GitHub Releases serves every asset (and the releases/latest alias)
;; behind redirects, and only get-pure-port accepts #:redirections — with no
;; way to see the final status. The transport below follows redirects
;; manually with status checks; the trust machinery (verify-signed-manifest,
;; select-update, verify-update-artifact!) stays rivet's.

(define (http-get once-url)
  ;; one raw HTTP GET; -> (values status-code header-lines body-port)
  (define in (get-impure-port (string->url once-url)
                              (list "User-Agent: regexmate-updater/1")))
  (define status-code
    (let ([line (read-line in 'return-linefeed)])
      (cond
        [(eof-object? line) (error 'update "empty response from ~a" once-url)]
        [else
         (define m (regexp-match #px"^HTTP/[0-9.]+ +(\\d{3})" line))
         (or (and m (string->number (cadr m)))
             (error 'update "malformed response from ~a" once-url))])))
  (define header-lines
    (let loop ([lines '()])
      (define line (read-line in 'return-linefeed))
      (cond
        [(eof-object? line) (reverse lines)]
        [(string=? (string-trim line) "") (reverse lines)]
        [else (loop (cons (string-trim line) lines))])))
  (values status-code header-lines in))

;; resolve a Location header (absolute, host-relative or path-relative)
(define (resolve-redirect base-str location)
  (cond
    [(regexp-match? #rx"^https?://" location) location]
    [(string-prefix? location "/")
     (define m (regexp-match #rx"^(https?://[^/]+)" base-str))
     (if m
         (string-append (cadr m) location)
         (error 'update "cannot resolve redirect ~a from ~a" location base-str))]
    [else
     (string-append (regexp-replace #rx"[^/]+$" base-str "") location)]))

;; GET with redirect following; errors unless the final status is 200 and
;; returns the response-body port
(define (http-get-redirecting url-str)
  (let loop ([current url-str] [hops 0])
    (when (> hops 10)
      (error 'update "too many redirects fetching ~a" url-str))
    (define-values (status headers in) (http-get current))
    (define location
      (and (member status '(301 302 303 307 308))
           (extract-field "Location" (string-join headers "\r\n"))))
    (cond
      [location
       (close-input-port in)
       (define next
         (with-handlers
             ([exn:fail?
               (lambda (e)
                 (error 'update "bad redirect from ~a: ~a"
                        current (exn-message e)))])
           (resolve-redirect current location)))
       (loop next (add1 hops))]
      [(= status 200) in]
      [else
       (close-input-port in)
       (error 'update "fetch failed (HTTP ~a): ~a" status current)])))

;; fetch and signature-verify the channel manifest at url-str
(define (fetch-manifest url-str)
  (define in (http-get-redirecting url-str))
  (define body (port->bytes in))
  (close-input-port in)
  (verify-signed-manifest (open-input-bytes body)
                          (embedded-public-key)
                          #:key-id regexmate-update-key-id))

(define (copy-bytes-with-limit! in out limit)
  (define buffer (make-bytes 65536))
  (let loop ([total 0])
    (define count (read-bytes-avail! buffer in))
    (cond
      [(eof-object? count) total]
      [else
       (define next (+ total count))
       (when (> next limit)
         (error 'download-candidate! "update exceeds the download limit"))
       (write-bytes buffer out 0 count)
       (loop next)])))

;; download url-str to destination with a byte cap; the caller verifies the
;; result against the signed manifest before trusting it
(define (download-artifact url-str destination limit)
  (make-parent-directory* destination)
  (define temporary (path-add-extension destination #".partial"))
  (when (file-exists? temporary) (delete-file temporary))
  (define in (http-get-redirecting url-str))
  (dynamic-wind
    void
    (lambda ()
      (with-handlers
          ([exn:fail?
            (lambda (e)
              (when (file-exists? temporary) (delete-file temporary))
              (raise e))])
        (call-with-output-file temporary
          #:exists 'truncate
          #:mode 'binary
          (lambda (out) (copy-bytes-with-limit! in out limit)))))
    (lambda () (close-input-port in)))
  (rename-file-or-directory temporary destination #t)
  destination)

;; ---- check ---------------------------------------------------------------

;; choose this install's artifact from a verified manifest. Distributed
;; installs take the platform archive (targz/zip); standalone single-file
;; installs take the exe artifact. Platform and architecture are matched
;; here too, so a manifest listing several windows artifacts (archive and
;; standalone exe side by side) stays unambiguous.
(define (pick-artifact manifest)
  (define kind-wanted
    (if (standalone-install?) 'exe (archive-installer-kind)))
  (for/first ([a (in-list (update-manifest-artifacts manifest))]
              #:when (and (eq? (update-artifact-platform a)
                               (platform-symbol))
                          (eq? (update-artifact-architecture a)
                               (architecture-symbol))
                          (eq? (update-artifact-installer a) kind-wanted)))
    a))

(define (make-config)
  (updater-config regexmate-identifier
                  regexmate-version
                  regexmate-channel
                  (platform-symbol)
                  (architecture-symbol)
                  (embedded-public-key)
                  regexmate-update-key-id
                  update-rollout-bucket
                  maximum-download-bytes))

;; an actionable update: the verified manifest it came from and the chosen
;; artifact
(struct update-plan (manifest artifact) #:transparent)

;; fetch and verify the signed channel manifest, then apply rivet's
;; selection policy. Returns an update-plan or #f when up to date. Errors
;; when the manifest has no artifact matching this install — a signed
;; manifest that skips a shipped platform is a release bug, not a soft
;; skip.
(define (check-for-update)
  (define manifest (fetch-manifest (manifest-url)))
  (define candidate (select-update (make-config) manifest))
  (cond
    [(not candidate) #f]
    [(pick-artifact manifest)
     => (lambda (artifact) (update-plan manifest artifact))]
    [else
     (error 'check-for-update
            "signed manifest ~a has no ~a artifact for ~a/~a"
            (update-manifest-version manifest)
            (if (standalone-install?) "standalone" "archive")
            (platform-symbol)
            (architecture-symbol))]))

;; download the plan's artifact to `destination`, then verify byte size and
;; SHA-256 against the signed manifest before the file is trusted
(define (download-candidate! plan destination)
  (define artifact (update-plan-artifact plan))
  (when (> (update-artifact-size artifact) maximum-download-bytes)
    (error 'download-candidate! "signed artifact size exceeds the download limit"))
  (download-artifact (update-artifact-url artifact)
                     destination
                     maximum-download-bytes)
  (verify-downloaded! plan destination)
  destination)

;; re-verify an already downloaded file (used by tests and callers that
;; obtained a file out of band)
(define (verify-downloaded! plan path)
  (verify-update-artifact!
   (update-candidate (update-plan-manifest plan) (update-plan-artifact plan))
   path))

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

;; ---- installation --------------------------------------------------------

(define (rmtree path)
  (with-handlers ([exn:fail? (lambda (e) (void))])
    (delete-directory/files path #:must-exist? #f)))

;; locate the staged pieces inside an extracted archive. Unix distribute
;; nests the exe under bin/; Windows distribute is flat. The GUI always
;; sits in gui/ at the archive root.
(define (staged-pieces extract-dir)
  (define exe (exe-name))
  (define flat (build-path extract-dir exe))
  (define nested (build-path extract-dir "bin" exe))
  (define new-exe
    (cond
      [(file-exists? flat) flat]
      [(file-exists? nested) nested]
      [else (error 'update "unexpected archive layout")]))
  (define lib (build-path extract-dir "lib"))
  (define gui (build-path extract-dir "gui"))
  (values new-exe
          (and (directory-exists? lib) lib)
          (and (directory-exists? gui) gui)))

;; remove leftovers from a previous update; safe to call at any startup
(define (cleanup-stale-updates)
  (when (installed-mode?)
    (rmtree (old-exe-path))
    (rmtree (old-lib-path))
    (rmtree (old-gui-path))
    (define dir (install-root))
    (with-handlers ([exn:fail? (lambda (e) (void))])
      (for ([p (in-list (directory-list dir #:build? #t))])
        (define n (path->string (file-name-from-path p)))
        (when (string-prefix? n "regexmate-update-")
          (rmtree p))))))

;; swap a staged update into place. The GUI is parked first: Windows keeps
;; a lock on every executable the running app holds, and a locked GUI
;; aborts the whole update before anything has moved — close the app and
;; run `regexmate update` again. Renames keep the running CLI alive even on
;; Windows; leftover .old files are removed by the next startup.
(define (install-update! new-exe new-lib new-gui)
  (define root (install-root))
  (define target-exe (build-path (install-dir) (exe-name)))
  (define target-lib (build-path root "lib"))
  (define target-gui (build-path root "gui"))
  (when (and new-gui (directory-exists? target-gui))
    (rmtree (old-gui-path))
    (with-handlers
        ([exn:fail?
          (lambda (e)
            (error 'update
                   "the RegexMate app appears to be running; close it and run `regexmate update` again"))])
      (rename-file-or-directory target-gui (old-gui-path))))
  (when (and new-lib (directory-exists? target-lib))
    (rmtree (old-lib-path))
    (with-handlers ([exn:fail? (lambda (e) (void))])
      (rename-file-or-directory target-lib (old-lib-path) #f)))
  (when (file-exists? target-exe)
    (rmtree (old-exe-path))
    (rename-file-or-directory target-exe (old-exe-path) #f))
  (rename-file-or-directory new-exe target-exe)
  (when (and new-lib (directory-exists? new-lib))
    (with-handlers ([exn:fail? (lambda (e) (void))])
      (rename-file-or-directory new-lib target-lib)))
  (when (and new-gui (directory-exists? new-gui))
    (rename-file-or-directory new-gui target-gui))
  ;; best-effort cleanup (the running exe's .old survives on Windows; the
  ;; next startup finishes the job)
  (rmtree (old-exe-path))
  (rmtree (old-lib-path))
  (rmtree (old-gui-path))
  'installed)
