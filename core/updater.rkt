#lang racket/base

;; Online update for RegexMate, built on rivet/distribution. `regexmate
;; update` fetches the Ed25519-signed channel manifest (update-manifest.json,
;; published alongside each GitHub release) through rivet's
;; fetch-update-manifest — HTTPS enforced, body capped, release-asset
;; redirects built in, signature verified before anything else looks at the
;; bytes — applies rivet's selection policy (identity, channel, SemVer
;; precedence, rollout), and downloads the artifact for this install through
;; rivet's download-update under a stall/total watchdog (a stalled
;; connection without RST/FIN would otherwise park the CLI forever). The
;; archive is extracted with the system tar and swapped into place (renames
;; keep a running process alive on Windows); stale .old leftovers are
;; cleaned on the next startup.
;;
;; The flow is deliberately CLI-shaped: the GUI ships inside the same
;; archive and cannot replace itself while running, so the CLI performs the
;; swap and the user restarts the GUI afterwards.

(require crypto
         (only-in crypto/libcrypto libcrypto-factory)
         net/base64
         (except-in rivet/distribution platform-symbol architecture-symbol)
         racket/file
         racket/list
         racket/path
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
         update-check-report
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

;; Distribution root is the parent of bin/ for POSIX and newer Windows ZIPs.
;; Legacy Windows ZIPs have the executable directly at the root. Preserve
;; both install shapes so signed updates never silently migrate the running
;; executable's expected path.
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

;; Racket's Unix distribute puts lib/ next to bin/ at the install root.
;; Windows distributes lib/ next to the EXE: root/lib for legacy ZIPs,
;; bin/lib for newer ZIPs. Check the actual executable's layout so Windows
;; bin/ installs are not mistaken for standalone EXEs and offered the wrong
;; signed update artifact.
(define (runtime-lib-path)
  (if (eq? (platform-symbol) 'windows)
      (build-path (install-dir) "lib")
      (build-path (install-root) "lib")))

(define (standalone-install?)
  (not (directory-exists? (runtime-lib-path))))

;; backup locations for pieces parked during a swap
(define (old-exe-path)
  (path-replace-suffix (build-path (install-dir) (exe-name)) ".old"))
(define (old-lib-path)
  (build-path (path-only (runtime-lib-path)) "lib.old"))
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
  (string-append (string-trim base "/" #:right? #t) "/update-manifest.json"))

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
;; rivet owns both network legs: fetch-update-manifest enforces HTTPS, caps
;; the body, follows the release-asset redirects (rivet#153's built-in
;; budget) and verifies the Ed25519 signature before anything else looks at
;; the bytes; download-update owns the artifact path (redirect-following
;; fetch, signed-size cap, .partial cleanup on every failure, SHA-256 + size
;; verification, atomic rename).
;;
;; Timeouts: rivet's copy loop waits on read-bytes-avail! with no deadline —
;; net/url ports have no read timeout, so a connection that stalls without
;; RST/FIN would park the CLI forever. Both legs run on a supervised worker
;; thread that a watchdog breaks on the stall limit (no byte progress) or
;; the total wall-clock limit (the taskly updater's download watchdog,
;; adapted to a synchronous CLI — there is no UI state box to poll here).

(define manifest-deadline-seconds 60)
(define download-stall-limit-seconds 120)
(define download-total-limit-seconds (* 30 60))

;; Run THUNK (receiving a `touch` procedure that refreshes the stall clock)
;; on a worker thread under a watchdog. Returns the thunk's value; a
;; timeout or worker failure raises. The download leg passes `touch` as the
;; downloader's #:on-progress so a slow-but-alive link never false-trips
;; the stall limit; the manifest fetch has no progress surface and ignores
;; it (its deadline is the stall limit).
(define (call-under-watchdog! who stall-limit-seconds total-limit-seconds thunk)
  (define last-tick (box (current-seconds)))
  (define outcome (box #f))
  (define timed-out? (box #f))
  (define worker
    (thread
     (lambda ()
       (with-handlers ([(lambda (e) #t)
                        (lambda (e) (set-box! outcome (cons 'raised e)))])
         (set-box! outcome
                   (cons 'returned
                         (thunk (lambda ()
                                  (set-box! last-tick (current-seconds))))))))))
  (define started (current-seconds))
  (thread
   (lambda ()
     (let loop ()
       (cond
         [(sync/timeout stall-limit-seconds (thread-dead-evt worker)) (void)]
         [(or (> (- (current-seconds) (unbox last-tick)) stall-limit-seconds)
              (> (- (current-seconds) started) total-limit-seconds))
          (set-box! timed-out? #t)
          (break-thread worker)]
         [else (loop)]))))
  ;; The watchdog breaks the worker at the limits; wait a little past them
  ;; so the break lands before this call gives up on the worker.
  (unless (sync/timeout (+ total-limit-seconds 30) worker)
    (error who "update transfer outlived its watchdog budget"))
  (define record (unbox outcome))
  (cond
    [(and record (eq? (car record) 'returned)) (cdr record)]
    [(unbox timed-out?)
     (error who "update transfer timed out (stall or wall-clock limit)")]
    [(and record (eq? (car record) 'raised)) (raise (cdr record))]
    [else (error who "update worker failed without a result")]))

;; fetch and signature-verify the channel manifest at url-str
(define (fetch-manifest url-str)
  (call-under-watchdog!
   'check-for-update
   manifest-deadline-seconds
   manifest-deadline-seconds
   (lambda (_touch)
     (fetch-update-manifest url-str
                            (embedded-public-key)
                            #:key-id regexmate-update-key-id))))

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

;; what the GUI's Check-for-Updates surface reports: ("up-to-date"),
;; ("available" latest-version) when the selection policy picks a newer
;; stable build, or ("offline" reason) when the check itself fails — no
;; network, rejected manifest, no matching artifact. Deliberately read-only:
;; applying an update stays the CLI's job (`regexmate update` swaps the
;; shared install and the GUI restarts onto it), the GUI never mutates its
;; own bundle. `check` is an injection seam for tests; the real check hits
;; the network, and `serve` handles RPCs serially, so a manual check briefly
;; parks other backend calls — acceptable for a menu item.
(define (update-check-report [check check-for-update])
  (with-handlers ([exn:fail?
                   (lambda (e)
                     (define message (exn-message e))
                     (list "offline"
                           (if ((string-length message) . <= . 200)
                               message
                               (string-append (substring message 0 200) " …"))))])
    (define plan (check))
    (if plan
        (list "available"
              (update-manifest-version (update-plan-manifest plan)))
        (list "up-to-date"))))

;; download the plan's artifact to `destination` through rivet's
;; download-update (redirect-following fetch, signed-size cap, .partial
;; cleanup, SHA-256 + size verification against the signed manifest,
;; atomic rename) under the watchdog, then re-verify the bytes before the
;; caller extracts anything
(define (download-candidate! plan destination)
  (define artifact (update-plan-artifact plan))
  (when (> (update-artifact-size artifact) maximum-download-bytes)
    (error 'download-candidate! "signed artifact size exceeds the download limit"))
  (call-under-watchdog!
   'download-candidate!
   download-stall-limit-seconds
   download-total-limit-seconds
   (lambda (touch)
     (download-update
      (make-config)
      (update-candidate (update-plan-manifest plan) artifact)
      destination
      #:on-progress (lambda (_bytes) (touch)))))
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
          (error 'update "archive extraction failed"))))
    #:exists 'truncate)
  #t)

;; ---- installation --------------------------------------------------------

(define (rmtree path)
  (with-handlers ([exn:fail? (lambda (e) (void))])
    (delete-directory/files path #:must-exist? #f)))

;; Locate the staged pieces inside an extracted archive. Unix distribute
;; puts bin/regexmate and root/lib together. Racket's Windows distribute
;; keeps lib/ next to its exe: the legacy root layout or new bin/lib layout.
;; The GUI always remains at archive-root gui/.
(define (staged-pieces extract-dir)
  (define exe (exe-name))
  (define flat (build-path extract-dir exe))
  (define nested (build-path extract-dir "bin" exe))
  (define new-exe
    (cond
      [(file-exists? flat) flat]
      [(file-exists? nested) nested]
      [else (error 'update "unexpected archive layout")]))
  (define lib-candidates
    (if (eq? (platform-symbol) 'windows)
        (list (build-path (path-only new-exe) "lib")
              (build-path extract-dir "lib"))
        (list (build-path extract-dir "lib"))))
  (define lib
    (for/first ([path (in-list lib-candidates)]
                #:when (directory-exists? path))
      path))
  (define gui (build-path extract-dir "gui"))
  (values new-exe
          lib
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
  (define target-lib (runtime-lib-path))
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
