#lang racket/base

;; Runtime-facing version. Must stay in sync with `version` in info.rkt;
;; scripts/check-version.rkt enforces this on every tagged release.

(define regexmate-version "0.6.0")

;; Release identity duplicated from rivet.rktd. The packaged binary cannot
;; read the project file at runtime, so the updater embeds these constants.
;; Keep them in sync with rivet.rktd.

(define regexmate-identifier "site.jrtx.regexmate")
(define regexmate-channel 'stable)
(define regexmate-display-name "RegexMate")

;; Update signing identity. Rotate by shipping a build that trusts the next
;; key before signing releases exclusively with it.
(define regexmate-update-key-id "regexmate-2026-10")

;; SubjectPublicKeyInfo DER, base64. The private half lives only in the
;; maintainer's key store and the repository's UPDATE_ED25519_PRIVATE_KEY_B64
;; CI secret; it never ships.
(define regexmate-update-public-key-b64
  "MCowBQYDK2VwAyEAclFzW5zuizRL++Fc4xotnEgtadOhGQ4MajblHrQNDXc=")

;; Signed channel manifest (update-stable.json) location: the latest release
;; of this repository on GitHub Releases.
(define regexmate-default-update-base-url
  "https://github.com/turinglambdaai/regexmate/releases/latest/download")

(provide regexmate-version
         regexmate-identifier
         regexmate-channel
         regexmate-display-name
         regexmate-update-key-id
         regexmate-update-public-key-b64
         regexmate-default-update-base-url)
