#!/usr/bin/env bash
# Build the RegexMate update manifest (rivet format) and merge platform
# artifacts from a release dist directory.
#
# Usage: scripts/make-update-manifest.sh <tag> <dist-dir> <key-der-path>
#   <tag>          release tag, e.g. v0.6.0 (must match rivet.rktd version)
#   <dist-dir>     directory containing the packaged platform archives as
#                  uploaded to the release:
#                    regexmate-<version>-linux-x86_64.tar.gz
#                    regexmate-<version>-linux-arm64.tar.gz
#                    regexmate-<version>-macos-arm64.tar.gz
#                    regexmate-<version>-macos-x64.tar.gz
#                    regexmate-<version>-windows-x86_64.zip
#                    regexmate-<version>-windows-x86_64-standalone.exe
#   <key-der-path> Ed25519 private key in DER (OneAsymmetricKey) form; the
#                  CI secret stores it base64-encoded.
#
# Emits <dist-dir>/update-manifest.json — a single signed channel manifest
# carrying every platform artifact (and the Windows standalone exe) — plus
# SHA256SUMS over all files. Env overrides: RELEASE_ASSET_BASE_URL,
# RIVET_UPDATE_KEY_ID.

set -euo pipefail

TAG="${1:?usage: make-update-manifest.sh <tag> <dist-dir> <key-der-path>}"
DIST="${2:?usage: make-update-manifest.sh <tag> <dist-dir> <key-der-path>}"
KEY_PATH="${3:?usage: make-update-manifest.sh <tag> <dist-dir> <key-der-path>}"
VERSION="${TAG#v}"
KEY_ID="${RIVET_UPDATE_KEY_ID:-regexmate-2026-10}"
BASE_URL="${RELEASE_ASSET_BASE_URL:-https://github.com/turinglambdaai/regexmate/releases/download/$TAG}"

# ---- verify tag/version alignment -------------------------------------------
RKTD_VERSION="$(racket -e '(require racket/file) (displayln (hash-ref (file->value "rivet.rktd") (quote version)))' | tr -d '"')"
if [ "$VERSION" != "$RKTD_VERSION" ]; then
  echo "error: tag $VERSION != rivet.rktd version $RKTD_VERSION" >&2
  exit 1
fi

# ---- build + sign the merged manifest with rivet's own signer ---------------
MANIFEST="$DIST/update-manifest.json"

SCRIPT="$(mktemp /tmp/regexmate-manifest-XXXXXX.rkt)"
trap 'rm -f "$SCRIPT"' EXIT

cat > "$SCRIPT" <<RKT
#lang racket/base
(require rivet/distribution
         racket/file
         racket/format
         racket/list
         racket/string)
(define tag "$TAG")
(define version "$VERSION")
(define base-url "$BASE_URL")
(define key-id "$KEY_ID")
(define dist (path->complete-path "$DIST"))
(define key-path (path->complete-path "$KEY_PATH"))
(define build (hash-ref (file->value "rivet.rktd") 'build))

;; (platform architecture installer filename) — every self-update payload
;; the release ships: the CLI+GUI feed archives for each platform/arch plus
;; the Windows standalone exe. The native installers (dmg/msi/deb/rpm/
;; AppImage) are not self-updating and stay out of the manifest.
(define wanted
  (list (list 'linux 'x64 'targz (format "regexmate-~a-linux-x86_64.tar.gz" version))
        (list 'linux 'arm64 'targz (format "regexmate-~a-linux-arm64.tar.gz" version))
        (list 'macos 'arm64 'targz (format "regexmate-~a-macos-arm64.tar.gz" version))
        (list 'macos 'x64 'targz (format "regexmate-~a-macos-x64.tar.gz" version))
        (list 'windows 'x64 'zip (format "regexmate-~a-windows-x86_64.zip" version))
        (list 'windows 'x64 'exe
              (format "regexmate-~a-windows-x86_64-standalone.exe" version))))

(define (artifact platform architecture installer file)
  (define path (build-path dist file))
  (unless (file-exists? path)
    (error 'make-update-manifest "missing archive: ~a" path))
  ;; rivet #271: trailing component field (#f = the plain app artifact).
  (update-artifact platform architecture
                   (string-append base-url "/" file)
                   (sha256-file/hex path)
                   (file-size path)
                   installer
                   '()
                   #f))

(define artifacts
  (for/list ([entry (in-list wanted)]
             #:when (file-exists? (build-path dist (fourth entry))))
    (artifact (first entry) (second entry) (third entry) (fourth entry))))

(when (null? artifacts)
  (error 'make-update-manifest "no archives found in ~a" dist))

;; every platform artifact shipped must be in the manifest
(unless (= (length artifacts) (length wanted))
  (error 'make-update-manifest
         "only ~a of ~a expected archives present in ~a"
         (length artifacts) (length wanted) dist))

(define manifest
  (update-manifest "site.jrtx.regexmate"
                   version
                   build
                   'stable
                   ;; published-at: RFC 3339, second precision
                   (let ([d (seconds->date (current-seconds) #f)])
                     (format "~a-~a-~aT~a:~a:~aZ"
                             (date-year d)
                             (~r (date-month d) #:min-width 2 #:pad-string "0")
                             (~r (date-day d) #:min-width 2 #:pad-string "0")
                             (~r (date-hour d) #:min-width 2 #:pad-string "0")
                             (~r (date-minute d) #:min-width 2 #:pad-string "0")
                             (~r (date-second d) #:min-width 2 #:pad-string "0")))
                   "0.0.0"
                   #f
                   #t
                   100
                   artifacts))

(call-with-output-file (build-path dist "update-manifest.json")
  #:exists 'truncate/replace
  (lambda (out)
    (write-signed-manifest manifest
                           (read-ed25519-private-key key-path)
                           key-id
                           out)
    (newline out)))
(printf "manifest: ~a (~a artifacts)\\n"
        (build-path dist "update-manifest.json") (length artifacts))
RKT

# rivet must be installed for the signer; the release job links a checkout
racket "$SCRIPT"

# ---- checksums (paths relative to the dist dir, so --check works from it) ----
( cd "$DIST" && find . -maxdepth 1 -type f ! -name SHA256SUMS -print0 \
    | sort -z | xargs -0 shasum -a 256 ) > "$DIST/SHA256SUMS"

echo "checksums: $DIST/SHA256SUMS"
