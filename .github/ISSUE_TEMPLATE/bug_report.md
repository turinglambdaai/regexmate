---
name: Bug report
about: Something in RegexMate is broken or behaves differently from the docs
title: ''
labels: bug
assignees: ''
---

**Describe the bug**

A clear description of what happened and what you expected instead.
中文描述完全没问题 — 写清楚即可。

**To reproduce**

The exact CLI invocation (or GUI steps / MCP tool call) that triggers the
behavior:

```console
regexmate match '\d+' 'abc 123' --json
```

**Environment**

- Platform: macOS / Windows / Linux (and version, and architecture)
- RegexMate version: `regexmate --version`
- Install shape: archive (tar.gz / zip) / standalone exe / dmg / msi / deb / rpm / AppImage / `raco pkg install`

**Update context (if this happened during a self-update)**

The exact output of `regexmate update` — the CLI verifies the manifest
signature before downloading anything, so a signature or fetch failure
message is the diagnosis, not a symptom.

**Screenshots / logs**

If applicable, add the `--json` output or console output (redact anything
private first).
