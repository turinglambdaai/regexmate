#lang racket

;; Bilingual message tables (en default, zh opt-in).
;; Language selection order: --lang flag > REGEXMATE_LANG env > en.

(define current-language (make-parameter 'en))

(define (valid-language? s) (member s '(en zh)))

;; Resolve language from a flag value or the environment; unknown -> #f
(define (resolve-language flag-value)
  (cond
    [flag-value
     (define s (string->symbol (string-downcase flag-value)))
     (and (valid-language? s) s)]
    [else
     (define env (getenv "REGEXMATE_LANG"))
     (define s (and env (string->symbol (string-downcase env))))
     (and (valid-language? s) s)]))

;; messages: key -> (cons en-format zh-format)
(define messages
  (hasheq
   'usage
   (cons
    (string-append
     "RegexMate ~a — the regex workbench for humans and agents\n"
     "\n"
     "Usage:\n"
     "  regexmate match <pattern> [text|-] [--json]   Run pattern against text ('-' reads stdin)\n"
     "  regexmate validate <pattern> [--json]         Check regex syntax\n"
     "  regexmate explain <pattern> [--json]          Explain each part in plain language\n"
     "  regexmate replace <pattern> <replacement> [text|-] [--json]\n"
     "  regexmate graph <pattern> [-o FILE] [--json]  Render a railroad diagram (SVG)\n"
     "  regexmate test <pattern> [FILE|-] [--json]    Assert cases: {\"text\",\"expect\",\"contains\"}\n"
     "  regexmate lint <pattern> [--strict] [--json]  Static risk findings (ReDoS etc.)\n"
     "  regexmate cookbook [id|topic] [--json]        Commented starter patterns to learn from\n"
     "  regexmate schema [--json]                     Print the machine-readable contract\n"
     "  regexmate update [--check] [--json]           Self-update from GitHub Releases\n"
     "  regexmate mcp                                 Run the stdio MCP server (JSON-RPC 2.0)\n"
     "\n"
     "Options:\n"
     "  --json          Structured JSON output (schema regexmate/v1)\n"
     "  --lang en|zh    Output language (default en; REGEXMATE_LANG also honored)\n"
     "  -o FILE         Write output to FILE (graph)\n"
     "  --version       Print version\n"
     "  -h, --help      Show this help\n"
     "\n"
     "Exit codes: 0 ok · 1 invalid regex · 2 usage error · 3 valid but no match/zero replacements\n")
    (string-append
     "RegexMate ~a — 面向人与 agent 的正则工作台\n"
     "\n"
     "用法:\n"
     "  regexmate match <正则> [文本|-] [--json]   对文本执行匹配（'-' 从 stdin 读取）\n"
     "  regexmate validate <正则> [--json]         校验正则语法\n"
     "  regexmate explain <正则> [--json]          逐部分解释正则\n"
     "  regexmate replace <正则> <替换文本> [文本|-] [--json]\n"
     "  regexmate graph <正则> [-o FILE] [--json]  生成铁路图（SVG）\n"
     "  regexmate test <正则> [FILE|-] [--json]    批量断言用例：{\"text\",\"expect\",\"contains\"}\n"
     "  regexmate lint <正则> [--strict] [--json]  静态风险分析（ReDoS 等）\n"
     "  regexmate cookbook [id|主题] [--json]      带讲解的入门正则配方，边用边学\n"
     "  regexmate schema [--json]                  打印机器可读契约\n"
     "  regexmate update [--check] [--json]        从 GitHub Releases 自更新\n"
     "  regexmate mcp                              启动 stdio MCP server（JSON-RPC 2.0）\n"
     "\n"
     "选项:\n"
     "  --json          结构化 JSON 输出（schema regexmate/v1）\n"
     "  --lang en|zh    输出语言（默认 en；也可用 REGEXMATE_LANG）\n"
     "  -o FILE         输出到文件（graph 命令）\n"
     "  --version       打印版本\n"
     "  -h, --help      显示本帮助\n"
     "\n"
     "退出码：0 成功 · 1 正则无效 · 2 用法错误 · 3 语法有效但无匹配/零替换\n"))
   'usage-version (cons "RegexMate ~a" "RegexMate ~a")
   'err-unknown-command (cons "Error: unknown command '~a' (run `regexmate --help`)\n"
                              "错误：未知命令 '~a'（运行 `regexmate --help` 查看）\n")
   'err-missing-argument (cons "Error: missing argument for '~a'\n"
                               "错误：'~a' 缺少参数\n")
   'err-unknown-flag (cons "Error: unknown flag '~a'\n"
                           "错误：未知选项 '~a'\n")
   'err-invalid-regex (cons "Error: invalid regular expression - ~a\n"
                            "错误：正则表达式无效 - ~a\n")
   'validate-pattern (cons "Pattern: ~a\n" "正则表达式: ~a\n")
   'validate-ok (cons "✓ Valid syntax\n" "✓ 语法有效\n")
   'validate-bad (cons "✗ Invalid syntax: ~a\n" "✗ 语法无效: ~a\n")
   'match-found (cons "Found ~a match(es):\n" "找到 ~a 个匹配:\n")
   'match-none (cons "No matches.\n" "无匹配。\n")
   'match-entry (cons "  at ~a-~a: \"~a\"\n" "  位置 ~a-~a: \"~a\"\n")
   'explain-header (cons "Pattern: ~a\n\nComponents:\n" "正则表达式: ~a\n\n组成部分:\n")
   'explain-entry (cons "  ~a. [~a] ~a  ← ~a\n" "  ~a. [~a] ~a  ← ~a\n")
   'replace-result (cons "Replaced ~a occurrence(s).\n" "完成 ~a 处替换。\n")
   'replace-none (cons "No occurrences replaced.\n" "没有发生替换。\n")
   'replace-text (cons "Result: ~a\n" "结果: ~a\n")
   'graph-saved (cons "SVG saved to: ~a\n" "SVG 已保存到: ~a\n")
   'test-summary (cons "Passed ~a of ~a case(s).\n" "通过 ~a / 共 ~a 个用例。\n")
   'test-case-pass (cons "  ✓ ~s\n" "  ✓ ~s\n")
   'test-case-fail (cons "  ✗ ~s — ~a\n" "  ✗ ~s — ~a\n")
   'test-input-error (cons "Error: test input must be a JSON object with a \"cases\" array or a bare array\n"
                           "错误：test 输入必须是带 \"cases\" 数组的 JSON 对象，或裸数组\n")
   'lint-header (cons "~a finding(s):\n" "~a 条发现:\n")
   'lint-entry (cons "  [~a] ~a at ~a: ~a\n" "  [~a] ~a 位置 ~a: ~a\n")
   'lint-none (cons "No findings.\n" "没有发现。\n")
   'report-saved (cons "Report saved to: ~a
" "报告已保存到: ~a
")
   'update-checking (cons "Checking for updates…\n" "正在检查更新…\n")
   'update-check-result (cons "Latest release: ~a (installed: ~a)\n" "最新版本: ~a（当前安装: ~a）\n")
   'update-up-to-date (cons "Already up to date (regexmate ~a).\n" "已是最新版本（regexmate ~a）。\n")
   'update-downloading (cons "Downloading ~a …\n" "正在下载 ~a …\n")
   'update-verifying (cons "Verifying checksum…\n" "正在校验 SHA-256…\n")
   'update-installing (cons "Installing …\n" "正在安装…\n")
   'update-done (cons "Updated to ~a. Run `regexmate --version` to confirm.\n" "已更新到 ~a。运行 `regexmate --version` 确认。\n")
   'update-source (cons "regexmate is running from source; update via `git pull` or `raco pkg update`.\n"
                        "regexmate 正以源码方式运行；请用 `git pull` 或 `raco pkg update` 更新。\n")
   'update-failed (cons "Update failed: ~a\n" "更新失败: ~a\n")
   'explain-unsupported (cons "This pattern uses syntax the visualizer does not support yet; description is approximate.\n"
                              "该正则包含可视化器尚未支持的语法，描述仅供参考。\n")
   'validate-hint (cons "Hint: ~a\n" "提示: ~a\n")
   'cookbook-list-header (cons "Cookbook — ~a recipe(s). Pick one with `regexmate cookbook <id>`.\n"
                               "配方库——共 ~a 条。用 `regexmate cookbook <id>` 查看单条。\n")
   'cookbook-list-entry (cons "  ~a  (~a)  ~a\n" "  ~a  (~a)  ~a\n")
   'cookbook-recipe-pattern (cons "  Pattern: ~a\n" "  正则: ~a\n")
   'cookbook-recipe-sample (cons "  Sample:  ~a\n" "  样本:   ~a\n")
   'cookbook-recipe-notes (cons "  Notes:\n" "  讲解:\n")
   'cookbook-note-entry (cons "    ~a\n        ~a\n" "    ~a\n        ~a\n")
   'cookbook-note-general (cons "    · ~a\n" "    · ~a\n")
   'cookbook-recipe-variants (cons "  Variants:\n" "  变体:\n")
   'cookbook-unknown (cons "Error: no recipe or topic '~a' (run `regexmate cookbook` to list them)\n"
                           "错误：没有 '~a' 这个配方或主题（运行 `regexmate cookbook` 查看列表）\n")
   ;; lint findings, rendered per rule so every language gets the full
   ;; sentence. args symbols resolve through lint-args.
   'lint-rule-nested-quantifier
   (cons "nested quantifiers over a group can backtrack catastrophically on non-matching input"
         "组内嵌套量词（如 (a+)+）在不匹配的输入上可能引发灾难性回溯")
   'lint-rule-quantified-assertion
   (cons "quantifier applied to ~a — it matches no text, so the quantifier has no effect or hides a bug"
         "量词作用于~a——断言不消耗文本，量词要么无效、要么掩盖了错误")
   'lint-rule-redundant-atomic
   (cons "atomic group over a single element has no effect — there is nothing inside it to backtrack"
         "原子组只包住单个元素时没有任何效果——内部没有可回溯的内容")
   'lint-rule-empty-branch
   (cons "alternative ~a is empty — it matches the empty string, usually a bug"
         "第 ~a 个分支为空——它匹配空字符串，通常是 bug")
   'lint-rule-duplicate-branch
   (cons "alternative ~a duplicates alternative ~a"
         "第 ~a 个分支与第 ~a 个分支重复")
   'lint-rule-shadowed-branch
   (cons "alternative ~a (~s) can never match: earlier alternative ~a (~s) always matches its prefix first"
         "第 ~a 个分支（~s）永远匹配不上：更早的第 ~a 个分支（~s）会先匹配掉它的前缀")
   'lint-rule-port-atomic
   (cons "atomic groups do not port everywhere: PCRE and modern JavaScript only; not Python re, not RE2/Go"
         "原子组并非处处可用：仅 PCRE 与现代 JavaScript 支持；Python re 和 RE2/Go 不支持")
   'lint-rule-port-flags
   (cons "scoped flag groups like (?i:...) do not port everywhere: PCRE and Python 3.11+ only; not JavaScript, not Go"
         "作用域标志组（如 (?i:...)）并非处处可用：仅 PCRE 与 Python 3.11+ 支持；JavaScript 和 Go 不支持")
   'lint-rule-port-unicode
   (cons "unicode property classes do not port everywhere: JavaScript (with the u flag) and PCRE only; not Python re"
         "Unicode 属性类并非处处可用：仅 JavaScript（需 u 标志）与 PCRE 支持；Python re 不支持")
   'lint-rule-port-backref
   (cons "backreferences do not port everywhere: PCRE, Python, JavaScript only; not RE2/Go, not Rust regex"
         "反向引用并非处处可用：仅 PCRE、Python、JavaScript 支持；RE2/Go 与 Rust regex 不支持")
   'lint-rule-port-posix
   (cons "POSIX classes like [:alpha:] do not port everywhere: PCRE only; not JavaScript, not Python re"
         "POSIX 字符类（如 [:alpha:]）并非处处可用：仅 PCRE 支持；JavaScript 和 Python re 不支持")
   'lint-arg-assertion (cons "an assertion" "断言")
   'lint-arg-anchor (cons "an anchor" "锚点")))

;; lint findings: rule -> format template (en . zh); render via lint-msg
(define lint-templates
  (hasheq 'nested-quantifier 'lint-rule-nested-quantifier
          'quantified-assertion 'lint-rule-quantified-assertion
          'redundant-atomic 'lint-rule-redundant-atomic
          'empty-branch 'lint-rule-empty-branch
          'duplicate-branch 'lint-rule-duplicate-branch
          'shadowed-branch 'lint-rule-shadowed-branch))

;; i18n key for a rule id, or #f for rules resolved elsewhere (portability)
(define (lint-rule-key rule)
  (hash-ref lint-templates rule #f))

(define (lint-msg key . args)
  (apply format ((if (eq? (current-language) 'zh) cdr car) (hash-ref messages key)) args))

;; localized lint argument by key ('lint-arg-…), or #f when unknown
(define (lint-arg-text key)
  (and (hash-has-key? messages key) (lint-msg key)))

;; validate errors: substring -> (cons hint-en hint-zh). Matched against the
;; stripped pregexp message; first hit wins.
(define error-hints
  (list
   (cons "missing closing square bracket"
         (cons "a character class opens with [ and must close with ] — e.g. [a-z0-9]"
               "字符类以 [ 开头、以 ] 收尾——例如 [a-z0-9]"))
   (cons "expected a closing"
         (cons "every ( needs a closing ), or use (?:…) for a group you don't capture"
               "每个 ( 都要有对应的 )；不需要捕获就用 (?:…)"))
   (cons "unterminated ("
         (cons "every ( needs a closing ), or use (?:…) for a group you don't capture"
               "每个 ( 都要有对应的 )；不需要捕获就用 (?:…)"))
   (cons "follows nothing"
         (cons "a quantifier needs something to repeat — to match a literal *, escape it as \\*"
               "量词前面要有可重复的对象；想匹配星号本身，请转义为 \\*"))
   (cons "unmatched `)`"
         (cons "remove the ) or escape it as \\) to match a literal one"
               "删掉多余的 )，或转义为 \\) 来匹配字面量"))
   (cons "invalid range within square brackets"
         (cons "inside […], ranges run from the smaller to the larger character — swap the endpoints or escape the -"
               "字符类内区间的两端必须从小到大——调换端点顺序，或转义 -"))
   (cons "after `(?`"
         (cons "this engine has no Python-style named groups (?P<name>…) — use a plain group (…) instead"
               "本引擎不支持 Python 风格命名组 (?P<name>…)——请用普通组 (…)"))))

;; localized repair hint for a (possibly multi-line) engine error, or #f
(define (hint-for-error error-message)
  (and error-message
       (let ([pair (for/first ([p (in-list error-hints)]
                               #:when (string-contains? error-message (car p)))
                     p)])
         (and pair ((if (eq? (current-language) 'zh) cdr car) (cdr pair))))))

;; msg: format-string lookup for the current language
(define (msg key . args)
  (define pair (hash-ref messages key))
  (apply format ((if (eq? (current-language) 'zh) cdr car) pair) args))

(provide current-language valid-language? resolve-language msg
         lint-msg lint-arg-text lint-rule-key hint-for-error)
