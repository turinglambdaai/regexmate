# RegexMate user guide

**English** · [简体中文](USER-GUIDE.zh-CN.md)

Validate, test, explain and lint regular expressions locally through a CLI, native GUI or MCP.

## Availability

Free developer and agent tool under the existing BUSL-1.1 terms, including the repository’s allowed internal use. The licence is not MIT and is not changed by the free-product policy.

## Platforms and installation

Desktop/CLI release assets for macOS, Windows and Linux. The engine uses Racket pregexp; it is not a proof of matching JavaScript, PCRE or another production engine.

Use [official Releases](https://github.com/turinglambdaai/regexmate/releases), select an explicitly listed OS/architecture asset, read its release notes and check supplied checksums. An absent asset/platform is not a delivery promise. Preview builds may lack publisher signing or notarization; do not disable system-wide security protections to install them.

Windows ZIP CLI entry points are version-specific: the published **v0.8.0** portable ZIP uses `regexmate.exe` at archive root; archives built with the [layout fix (#13)](https://github.com/turinglambdaai/regexmate/issues/13) use `bin/regexmate.exe` (macOS/Linux: `bin/regexmate`). Extract the entire archive, including Racket's platform-specific runtime libraries and the separate `gui/` tree. For an already-installed legacy Windows ZIP, the verified CLI updater retains its original executable location and swaps the libraries alongside it; it does not silently change the install path. The separately published single-file Windows EXE remains a different installation/update mode.

## Your first successful session

1. Run regexmate validate on your pattern, then match a synthetic positive sample.
2. Add negative and boundary cases with regexmate test; inspect lint findings before using the pattern on untrusted input.
3. For agent use, connect regexmate mcp and allow only the tools needed. Recheck the pattern in the actual destination engine.

## Data, backup and recovery

Save pattern fixtures, expected results and generated SVGs in your own project. Do not put customer secrets in sample text or public issues. Keep a copy before batch replacement; matches and lint are not a guarantee against every performance attack.

## Network, keys and privacy

Core regex work is local. Update checks/downloads and external agents may use the network. Inspect an agent’s permissions before providing sensitive sample files.

## Known limits

The GUI has a read-only update check; applying updates is the CLI’s job. Exit and restart the GUI after updating. Source/package installs use their own update path.

## Updates and removal

Back up data and read the destination release notes first. An in-app update check does not necessarily install an update for your channel; follow the manual for portable, installer and source paths. Never bypass a failed signature check or replace the program with an untrusted artifact. On failure, preserve data and the error, then recover with a trusted release. Removing the program does not necessarily erase its separate data directory; verify your backup before deleting personal data.

## Get help

Report problems in [GitHub Issues](https://github.com/turinglambdaai/regexmate/issues), in English or Chinese. Include the version, OS/architecture, installation channel, steps, expected result and actual result. Reproduce with synthetic input first; do not attach keys, credentials, databases, private source documents or complete logs. Public support has no guaranteed response time.

## Further reading

- [Command manual](../docs/guide.html)
- [Agent workflow](../docs/agents-guide.md)
- [Project overview and development](../README.md)
- [Current licence](../LICENSE)
