#lang racket

;; The cookbook: commented, test-verified starter patterns. Every recipe
;; is pure data — pattern, sample text, per-segment teaching notes and
;; variants, all bilingual. The CLI, the MCP server and (later) the
;; desktop GUIs read from this one module, so every surface teaches from
;; the same source. Recipes are self-consistent: each pattern matches its
;; own sample (enforced by the test suite).

(struct recipe (id topic title-en title-zh pattern
                sample-en notes-en variants-en
                sample-zh notes-zh variants-zh)
        #:transparent)
;; notes:    (list (cons segment explanation)) — segment is a raw substring
;;           of the pattern, explanation teaches what it does and why
;; variants: (list (cons pattern explanation))

(define recipes
  (list

   ;; ---- contact -----------------------------------------------------

   (recipe 'email 'contact
           "Email address (practical)" "邮箱地址（实用版）"
           "[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\\.[a-zA-Z]{2,}"
           "write to first.last+tag@example.co.uk"
           (list (cons "[a-zA-Z0-9._%+-]+"
                       "the local part: letters, digits, dots, underscores, plus and hyphen; the trailing + repeats it one or more times")
                 (cons "@"
                       "a literal @ — it separates local part from domain")
                 (cons "[a-zA-Z0-9.-]+"
                       "the domain: labels, dots and hyphens")
                 (cons "\\.[a-zA-Z]{2,}"
                       "the TLD: a literal dot (escaped, because . alone means 'any character') then at least two letters"))
           (list (cons "^...$"
                       "when validating a whole form field, anchor it: ^[a-zA-Z0-9._%+-]+@…$ — otherwise any email inside the text matches"))
           "把邮件发给 first.last+tag@example.co.uk"
           (list (cons "[a-zA-Z0-9._%+-]+"
                       "本地部分：字母、数字、点、下划线、加号和连字符；结尾的 + 表示重复一次或多次")
                 (cons "@"
                       "字面量 @，分隔本地部分和域名")
                 (cons "[a-zA-Z0-9.-]+"
                       "域名：标签、点和连字符")
                 (cons "\\.[a-zA-Z]{2,}"
                       "顶级域：一个转义的点（不转义的 . 表示任意字符），后面至少两个字母"))
           (list (cons "^...$"
                       "校验整个表单字段时加锚点：^[a-zA-Z0-9._%+-]+@…$，否则文本中任意位置的邮箱都会匹配")))

   (recipe 'phone-cn 'contact
           "Chinese mobile number" "中国大陆手机号"
           "1[3-9]\\d{9}"
           "call 13812345678 or 19912345678"
           (list (cons "1"
                       "mobile numbers start with 1")
                 (cons "[3-9]"
                       "the second digit is 3-9 across current carriers")
                 (cons "\\d{9}"
                       "exactly nine more digits — 11 in total"))
           (list (cons "1[3-9]\\d[- ]?\\d{4}[- ]?\\d{4}"
                       "allow 138-1234-5678 style separators with [- ]?"))
           "拨打 13812345678 或 19912345678"
           (list (cons "1"
                       "手机号以 1 开头")
                 (cons "[3-9]"
                       "第二位是 3-9（现行号段）")
                 (cons "\\d{9}"
                       "再精确 9 位数字——共 11 位"))
           (list (cons "1[3-9]\\d[- ]?\\d{4}[- ]?\\d{4}"
                       "允许 138-1234-5678 这类分隔符写法")))

   (recipe 'phone-intl 'contact
           "International phone (+country code)" "国际电话（+国家码）"
           "\\+\\d{1,3}[- ]?\\d{6,14}"
           "support line: +86 13812345678"
           (list (cons "\\+"
                       "a literal + (no escaping needed outside character classes)")
                 (cons "\\d{1,3}"
                       "country code: one to three digits")
                 (cons "[- ]?"
                       "an optional space or hyphen separator")
                 (cons "\\d{6,14}"
                       "the subscriber number, six to fourteen digits (E.164 range)"))
           '()
           "客服热线：+86 13812345678"
           (list (cons "\\+"
                       "字面量 +（字符类外无需转义）")
                 (cons "\\d{1,3}"
                       "国家码：一到三位数字")
                 (cons "[- ]?"
                       "可选的空格或连字符分隔符")
                 (cons "\\d{6,14}"
                       "用户号码，六到十四位（E.164 范围）"))
           '())

   (recipe 'postal-cn 'contact
           "Chinese postal code" "中国邮政编码"
           "[1-9]\\d{5}(?!\\d)"
           "mail to 100085 Beijing"
           (list (cons "[1-9]\\d{5}"
                       "six digits, first one non-zero")
                 (cons "(?!\\d)"
                       "negative lookahead: the next character must NOT be a digit — it stops 1000851 from matching as 100085. Lookaheads assert without consuming text"))
           '()
           "寄往北京 100085"
           (list (cons "[1-9]\\d{5}"
                       "六位数字，首位非零")
                 (cons "(?!\\d)"
                       "负向先行断言：下一个字符不能是数字——避免把 1000851 的前六位当成邮编。断言只检查、不消耗文本"))
           '())

   (recipe 'cn-id 'contact
           "Chinese ID card (18-digit shape)" "身份证号（18 位，格式级）"
           "[1-9]\\d{5}(?:19|20)\\d{2}(?:0[1-9]|1[0-2])(?:0[1-9]|[12]\\d|3[01])\\d{3}[\\dXx]"
           "id 11010519491231002X"
           (list (cons "[1-9]\\d{5}"
                       "the six-digit region code")
                 (cons "(?:19|20)\\d{2}"
                       "birth year: century 19/20 plus two digits — (?:…) groups without capturing")
                 (cons "(?:0[1-9]|1[0-2])"
                       "month 01-12 by alternation")
                 (cons "(?:0[1-9]|[12]\\d|3[01])"
                       "day 01-31")
                 (cons "[\\dXx]"
                       "the checksum slot: a digit or the letter X"))
           (list (cons "checksum"
                       "the real checksum is arithmetic (ISO 7064 weights) — do it in code, not regex"))
           "身份证号 11010519491231002X"
           (list (cons "[1-9]\\d{5}"
                       "六位地区码")
                 (cons "(?:19|20)\\d{2}"
                       "出生年：19/20 世纪加两位——(?:…) 是不捕获的组")
                 (cons "(?:0[1-9]|1[0-2])"
                       "月份 01-12，用交替枚举")
                 (cons "(?:0[1-9]|[12]\\d|3[01])"
                       "日 01-31")
                 (cons "[\\dXx]"
                       "校验位：数字或字母 X"))
           (list (cons "checksum"
                       "真正的校验是算术（ISO 7064 加权）——放在代码里做，别塞进正则")))

   ;; ---- date & time ---------------------------------------------------

   (recipe 'date-iso 'date-time
           "ISO date (yyyy-mm-dd)" "ISO 日期（yyyy-mm-dd）"
           "\\d{4}-(0[1-9]|1[0-2])-(0[1-9]|[12]\\d|3[01])"
           "released on 2026-09-28, not 2026-13-01"
           (list (cons "\\d{4}"
                       "four-digit year")
                 (cons "(0[1-9]|1[0-2])"
                       "month 01-12 as an alternation of two branches")
                 (cons "(0[1-9]|[12]\\d|3[01])"
                       "day 01-31: three branches — 01-09, 10-29, 30-31"))
           (list (cons "(?:…)"
                       "swap (…) for (?:…) when you don't need the group captured — match_rows then reports zero groups")
                 (cons "calendar"
                       "shape only: 2026-02-30 passes. Use the test command to pin real dates"))
           "发布日 2026-09-28，而不是 2026-13-01"
           (list (cons "\\d{4}"
                       "四位年份")
                 (cons "(0[1-9]|1[0-2])"
                       "月份 01-12，两个分支的交替")
                 (cons "(0[1-9]|[12]\\d|3[01])"
                       "日 01-31：三分支——01-09、10-29、30-31"))
           (list (cons "(?:…)"
                       "不需要捕获时把 (…) 换成 (?:…)——match_rows 会报告 0 个组")
                 (cons "calendar"
                       "只验形状：2026-02-30 也能通过。真实日期请配合 test 命令用例")))

   (recipe 'time-24h 'date-time
           "24-hour time (hh:mm)" "24 小时制时间（hh:mm）"
           "([01]\\d|2[0-3]):[0-5]\\d"
           "standup 09:30, deploy 23:45"
           (list (cons "([01]\\d|2[0-3])"
                       "hour: 00-19 or 20-23")
                 (cons ":"
                       "literal colon")
                 (cons "[0-5]\\d"
                       "minute 00-59")
                 (cons "*"
                       "group 1 holds the hour — handy for replace"))
           '()
           "站会 09:30，发布 23:45"
           (list (cons "([01]\\d|2[0-3])"
                       "小时：00-19 或 20-23")
                 (cons ":"
                       "字面量冒号")
                 (cons "[0-5]\\d"
                       "分钟 00-59")
                 (cons "*"
                       "组 1 捕获小时——replace 时直接引用"))
           '())

   ;; ---- web -----------------------------------------------------------

   (recipe 'url 'web
           "HTTP(S) URL (simple)" "HTTP(S) 网址（简单版）"
           "https?://[^\\s]+"
           "docs live at https://example.com/a/b?q=1"
           (list (cons "https?"
                       "http, with the s optional")
                 (cons "://"
                       "literal ://")
                 (cons "[^\\s]+"
                       "a negated character class: everything up to the next whitespace. Fast and honest — it cannot 'overrun' into the next word"))
           (list (cons "https?://[a-z0-9.-]+(?:/[^\\s]*)?"
                       "host-only variant: stops the match at the end of the domain"))
           "文档在 https://example.com/a/b?q=1"
           (list (cons "https?"
                       "http，s 可选")
                 (cons "://"
                       "字面量 ://")
                 (cons "[^\\s]+"
                       "取反字符类：吃掉直到下一个空白的所有字符。快且可控——不会越界吞掉下一个词"))
           (list (cons "https?://[a-z0-9.-]+(?:/[^\\s]*)?"
                       "只取主机名的变体：匹配到域名结尾为止"))

           )

   (recipe 'domain 'web
           "Domain name" "域名"
           "(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\\.)+[a-z]{2,}"
           "mirror at assets.example.co.uk"
           (list (cons "(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\\.)+"
                       "one label + dot, repeated: a label starts and ends alphanumeric, hyphens only inside — that middle group is the 'no leading/trailing hyphen' rule")
                 (cons "[a-z]{2,}"
                       "the TLD, at least two letters"))
           '()
           "镜像站在 assets.example.co.uk"
           (list (cons "(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\\.)+"
                       "「标签+点」重复：标签以字母数字开头结尾、连字符只能在中间——中间那层组就是「连字符不贴边」规则")
                 (cons "[a-z]{2,}"
                       "顶级域，至少两个字母"))
           '())

   (recipe 'ipv4 'web
           "IPv4 address (loose)" "IPv4 地址（宽松版）"
           "\\b(?:\\d{1,3}\\.){3}\\d{1,3}\\b"
           "gateway 192.168.1.1 up"
           (list (cons "\\b"
                       "word boundaries keep it from matching inside longer numbers")
                 (cons "(?:\\d{1,3}\\.){3}"
                       "three 'digits + dot' groups, non-capturing")
                 (cons "\\d{1,3}"
                       "each octet is one to three digits — 999.999.999.999 passes this shape"))
           (list (cons "\\b(?:(?:25[0-5]|2[0-4]\\d|1\\d\\d|[1-9]?\\d)\\.){3}(?:25[0-5]|2[0-4]\\d|1\\d\\d|[1-9]?\\d)\\b"
                       "strict octets 0-255: 25[0-5] / 2[0-4]\\d / 1\\d\\d / [1-9]?\\d enumerate the ranges from the most significant digit down"))
           "网关 192.168.1.1 已连通"
           (list (cons "\\b"
                       "单词边界防止在更长数字串里误匹配")
                 (cons "(?:\\d{1,3}\\.){3}"
                       "三组「数字+点」，不捕获")
                 (cons "\\d{1,3}"
                       "每段一到三位——999.999.999.999 也能通过这种形状"))
           (list (cons "\\b(?:(?:25[0-5]|2[0-4]\\d|1\\d\\d|[1-9]?\\d)\\.){3}(?:25[0-5]|2[0-4]\\d|1\\d\\d|[1-9]?\\d)\\b"
                       "严格 0-255 版本：25[0-5] / 2[0-4]\\d / 1\\d\\d / [1-9]?\\d 从最高位开始枚举区间")))

   (recipe 'hex-color 'web
           "Hex color" "十六进制颜色"
           "#(?:[0-9a-fA-F]{6}|[0-9a-fA-F]{3})\\b"
           "bg #037A55 and #FFF"
           (list (cons "#"
                       "literal hash")
                 (cons "(?:[0-9a-fA-F]{6}|[0-9a-fA-F]{3})"
                       "six digits first, then three — trying the longer alternative first is the habit that saves you from partial matches")
                 (cons "\\b"
                       "stop at the word boundary so #FFF inside #FFFFFF does not win"))
           (list (cons "#(?:[0-9a-fA-F]{8}|[0-9a-fA-F]{6}|[0-9a-fA-F]{3})\\b"
                       "add {8} first when alpha-channel #RRGGBBAA is possible"))
           "背景 #037A55，前景 #FFF"
           (list (cons "#"
                       "字面量 #")
                 (cons "(?:[0-9a-fA-F]{6}|[0-9a-fA-F]{3})"
                       "先六位再三位——长分支放前面是避免半截匹配的习惯")
                 (cons "\\b"
                       "词边界兜底，防止从 #FFFFFF 里截出 #FFF"))
           (list (cons "#(?:[0-9a-fA-F]{8}|[0-9a-fA-F]{6}|[0-9a-fA-F]{3})\\b"
                       "可能带透明通道 #RRGGBBAA 时，把 {8} 放在最前")))

   ;; ---- numbers ---------------------------------------------------------

   (recipe 'thousands 'numbers
           "Number with thousand separators" "千分位数字"
           "\\d{1,3}(?:,\\d{3})+"
           "printed 1,234,567 copies"
           (list (cons "\\d{1,3}"
                       "the leading group: one to three digits")
                 (cons "(?:,\\d{3})+"
                       "then one or more ',three digits' — the + on a non-capturing group is the workhorse pattern for anything 'repeating in blocks'"))
           '()
           "印了 1,234,567 份"
           (list (cons "\\d{1,3}"
                       "首位组：一到三位数字")
                 (cons "(?:,\\d{3})+"
                       "后面跟一或多组「逗号+三位」——「按块重复」的非捕获组加 + 是最常用的主力句型"))
           '())

   (recipe 'decimal 'numbers
           "Decimal number (optional sign)" "小数（可带符号）"
           "[-+]?\\d+(?:\\.\\d+)?"
           "temperature -3.5 degrees"
           (list (cons "[-+]?"
                       "optional sign — a minus first inside […] is a literal, not a range")
                 (cons "\\d+"
                       "integer part, one or more digits")
                 (cons "(?:\\.\\d+)?"
                       "optional fraction: a literal dot then digits; the dot is escaped"))
           (list (cons "[-+]?\\d+"
                       "integer-only variant"))
           "气温 -3.5 度"
           (list (cons "[-+]?"
                       "可选符号——[…] 里减号放最前就是字面量，不构成区间")
                 (cons "\\d+"
                       "整数部分，一位以上")
                 (cons "(?:\\.\\d+)?"
                       "可选小数部分：转义的点加数字；整组可选"))
           (list (cons "[-+]?\\d+"
                       "只要整数的变体")))

   ;; ---- text ------------------------------------------------------------

   (recipe 'password 'text
           "Strong password (8+, lower + upper + digit)" "强密码（8 位以上，含大小写和数字）"
           "(?=.*[a-z])(?=.*[A-Z])(?=.*\\d).{8,}"
           "Passw0rd is fine, password1 is not"
           (list (cons "(?=.*[a-z])"
                       "lookahead: somewhere ahead there is a lowercase letter — the position does not matter, which is how lookaheads express AND")
                 (cons "(?=.*[A-Z])"
                       "…and an uppercase letter")
                 (cons "(?=.*\\d)"
                       "…and a digit. Three zero-width conditions must all hold before anything is consumed")
                 (cons ".{8,}"
                       "only then consume at least eight characters"))
           (list (cons "(?=.*[^A-Za-z0-9]).{8,}"
                       "add a fourth lookahead for at least one symbol"))
           "Passw0rd 可以，password1 不行"
           (list (cons "(?=.*[a-z])"
                       "先行断言：前方某处有小写字母——位置无所谓，这正是 lookahead 表达「与」的方式")
                 (cons "(?=.*[A-Z])"
                       "……还要有大写字母")
                 (cons "(?=.*\\d)"
                       "……还要有数字。三个零宽条件全部满足后才开始消耗文本")
                 (cons ".{8,}"
                       "然后至少消耗八个字符"))
           (list (cons "(?=.*[^A-Za-z0-9]).{8,}"
                       "再加一条「至少一个符号」的断言")))

   (recipe 'duplicate-word 'text
           "Repeated word" "重复单词"
           "\\b(\\w+)\\s+\\1\\b"
           "this this is a bug"
           (list (cons "(\\w+)"
                       "capture group 1: a word")
                 (cons "\\s+"
                       "whitespace between the copies")
                 (cons "\\1"
                       "backreference: exactly what group 1 captured — the whole point of this recipe")
                 (cons "\\b"
                       "boundaries so 'this thesis' does not match"))
           (list (cons "(?i:\\b(\\w+)\\s+\\1\\b)"
                       "case-insensitive scoped to the whole match — note the scoped flag group does not port to every engine (lint will tell you)"))
           "this this 是个 bug"
           (list (cons "(\\w+)"
                       "捕获组 1：一个单词")
                 (cons "\\s+"
                       "两份之间的空白")
                 (cons "\\1"
                       "反向引用：必须和组 1 捕获的内容完全一致——本配方的核心")
                 (cons "\\b"
                       "词边界，避免 this thesis 误配"))
           (list (cons "(?i:\\b(\\w+)\\s+\\1\\b)"
                       "整段忽略大小写——注意作用域标志组并非每个引擎都支持（lint 会提醒你）")))

   (recipe 'quoted-string 'text
           "Double-quoted string" "双引号字符串"
           "\"[^\"]*\""
           "call it \"alpha\" next"
           (list (cons "\""
                       "opening quote")
                 (cons "[^\"]*"
                       "any run of non-quote characters — the negated class is the fastest honest 'everything until X'")
                 (cons "\""
                       "closing quote"))
           (list (cons "\"(?:[^\"\\\\]|\\\\.)*\""
                       "allow \\\" escapes inside: alternate between 'not a quote or backslash' and 'backslash + any character'"))
           "把它叫作 \"alpha\""
           (list (cons "\""
                       "起始引号")
                 (cons "[^\"]*"
                       "一串非引号字符——取反字符类是「直到 X 为止」最快写法")
                 (cons "\""
                       "结束引号"))
           (list (cons "\"(?:[^\"\\\\]|\\\\.)*\""
                       "允许内部 \\\" 转义：在「非引号或反斜杠」与「反斜杠+任意字符」之间交替")))

   (recipe 'trim-spaces 'text
           "Leading/trailing whitespace" "行首行尾空白"
           "(?m:^[ ]+|[ ]+$)"
           "two lines:\n  indented and trailing  \n"
           (list (cons "(?m:"
                       "a scoped multiline flag: inside this group ^ and $ match at every line start/end, not just the string's")
                 (cons "^[ ]+|[ ]+$"
                       "either a run of spaces at line start or at line end"))
           (list (cons "trim"
                       "feed it to replace with an empty replacement to trim every line"))
           "两行文本：\n  缩进和尾部空格  \n"
           (list (cons "(?m:"
                       "作用域内的多行标志：组内 ^ 和 $ 匹配每一行的首尾，而不是整个字符串的")
                 (cons "^[ ]+|[ ]+$"
                       "行首的连续空格，或行尾的连续空格"))
           (list (cons "trim"
                       "把它交给 replace 并用空替换文本，即可去掉每行首尾空白")))

   ;; ---- code ------------------------------------------------------------

   (recipe 'semver 'code
           "Semantic version" "语义化版本号"
           "(?<![.\\d])\\d+\\.\\d+\\.\\d+(?:-[0-9A-Za-z.-]+)?\\b"
           "shipped v2.10.0-beta.1 today"
           (list (cons "(?<![.\\d])"
                       "negative lookbehind: the version must not sit right after a dot or digit — so v2.10.0 matches but the tail of 12.2.3.4 does not")
                 (cons "\\d+\\.\\d+\\.\\d+"
                       "major.minor.patch — literal dots between digit runs")
                 (cons "(?:-[0-9A-Za-z.-]+)?"
                       "optional prerelease: a hyphen then letters, digits, dots, hyphens"))
           '()
           "今天发布了 v2.10.0-beta.1"
           (list (cons "(?<![.\\d])"
                       "负向后行断言：版本号前面不能紧挨着点或数字——v2.10.0 能匹配，而 12.2.3.4 的尾部不会")
                 (cons "\\d+\\.\\d+\\.\\d+"
                       "主版本.次版本.修订号——数字段之间的点要转义")
                 (cons "(?:-[0-9A-Za-z.-]+)?"
                       "可选预发布段：一个连字符后接字母、数字、点、连字符"))
           '())

   (recipe 'uuid 'code
           "UUID" "UUID"
           "\\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\\b"
           "id = 550e8400-e29b-41d4-a716-446655440000"
           (list (cons "[0-9a-f]{8}"
                       "eight lowercase hex digits; repeat the pattern per group with hyphens between")
                 (cons "\\b"
                       "boundaries keep partial hex strings from matching"))
           (list (cons "[0-9a-fA-F]"
                       "swap in uppercase when your source mixes case"))
           "id = 550e8400-e29b-41d4-a716-446655440000"
           (list (cons "[0-9a-f]{8}"
                       "八位小写十六进制；每组重复同一句型、组间连字符")
                 (cons "\\b"
                       "词边界防止截取部分十六进制串"))
           (list (cons "[0-9a-fA-F]"
                       "源数据大小写混用时换成大写集合")))

   (recipe 'camel-boundary 'code
           "camelCase → snake_case (replace)" "camelCase 转 snake_case（替换）"
           "([a-z0-9])([A-Z])"
           "parseHTTPHeader fast"
           (list (cons "([a-z0-9])"
                       "group 1: the character before the hump")
                 (cons "([A-Z])"
                       "group 2: the hump")
                 (cons "*"
                       "run `regexmate replace '([a-z0-9])([A-Z])' '\\1_\\2'` — \\\\1 and \\\\2 reference the groups, giving parseHTTPHeader → parse_HTTP_header; lowercase the result in your tool"))
           '()
           "parseHTTPHeader 快速"
           (list (cons "([a-z0-9])"
                       "组 1：驼峰前的字符")
                 (cons "([A-Z])"
                       "组 2：驼峰本身")
                 (cons "*"
                       "执行 `regexmate replace '([a-z0-9])([A-Z])' '\\1_\\2'`——\\\\1、\\\\2 引用两个组，得到 parseHTTPHeader → parse_HTTP_header；大小写转换交给后续工具"))
           '())

   (recipe 'html-tag 'web
           "Paired HTML tag (backreference)" "配对 HTML 标签（反向引用）"
           "<([a-z][a-z0-9]*)\\b[^>]*>.*?</\\1>"
           "<b>bold</b> and <i>it</i> ok"
           (list (cons "<([a-z][a-z0-9]*)\\b"
                       "tag name captured as group 1")
                 (cons "[^>]*>"
                       "attributes: anything but >, then the closing >")
                 (cons ".*?"
                       "lazy dot-star: stop at the FIRST closing tag, not the last — the greedy .*? alternative would overrun nested markup")
                 (cons "</\\1>"
                       "backreference: the closing tag must name the same tag that opened it"))
           (list (cons "<[^>]+>"
                       "any single tag, paired or not — the simpler shape most tasks actually want"))
           "<b>bold</b> 与 <i>it</i> 正常"
           (list (cons "<([a-z][a-z0-9]*)\\b"
                       "标签名捕获为组 1")
                 (cons "[^>]*>"
                       "属性：除 > 外的任意内容，直到闭合 >")
                 (cons ".*?"
                       "懒惰点星：在第一个结束标签处停下——贪婪版本会越过嵌套标记一路吃到最后")
                 (cons "</\\1>"
                       "反向引用：结束标签必须与开始标签同名"))
           (list (cons "<[^>]+>"
                       "任意单个标签、不论配对——多数任务其实要的是这个简单形状")))

   ;; ---- log -------------------------------------------------------------

   (recipe 'log-level 'log
           "Log level word" "日志级别词"
           "\\b(?:DEBUG|INFO|WARN(?:ING)?|ERROR|FATAL)\\b"
           "2026-10-08 09:00:01 ERROR disk full"
           (list (cons "\\b(?:DEBUG|INFO|WARN(?:ING)?|ERROR|FATAL)\\b"
                       "an alternation of literal words, non-capturing because you rarely need the group")
                 (cons "WARN(?:ING)?"
                       "an optional suffix group covers WARN and WARNING in one branch"))
           (list (cons "^\\d{4}-\\d{2}-\\d{2} \\d{2}:\\d{2}:\\d{2}\\s+\\S+\\s+(?:DEBUG|INFO|WARN(?:ING)?|ERROR|FATAL)\\b.*$"
                       "a full syslog-style line: timestamp, emitter, level, message"))
           "2026-10-08 09:00:01 ERROR 磁盘已满"
           (list (cons "\\b(?:DEBUG|INFO|WARN(?:ING)?|ERROR|FATAL)\\b"
                       "字面量词的交替，不需要捕获组就用非捕获")
                 (cons "WARN(?:ING)?"
                       "可选后缀组，一个分支同时覆盖 WARN 和 WARNING"))
           (list (cons "^\\d{4}-\\d{2}-\\d{2} \\d{2}:\\d{2}:\\d{2}\\s+\\S+\\s+(?:DEBUG|INFO|WARN(?:ING)?|ERROR|FATAL)\\b.*$"
                       "整行 syslog 句型：时间戳、来源、级别、消息")))

   (recipe 'bracketed 'log
           "Bracketed key like [level=warn]" "方括号键值，如 [level=warn]"
           "\\[([a-z]+)=\"?([a-z0-9._-]+)\"?\\]"
           "[level=\"warn\"] [scope=auth.retry] failed"
           (list (cons "\\["
                       "literal [ — outside a character class it needs no escape, but escaping it keeps the intent obvious")
                 (cons "([a-z]+)"
                       "group 1: the key")
                 (cons "=\"?([a-z0-9._-]+)\"?"
                       "group 2: the value, quotes optional — both groups are what you would feed to replace or post-process")
                 (cons "\\]"
                       "literal ]"))
           '()
           "[level=\"warn\"] [scope=auth.retry] 失败"
           (list (cons "\\["
                       "字面量 [——字符类之外无需转义，但写出来意图更清楚")
                 (cons "([a-z]+)"
                       "组 1：键")
                 (cons "=\"?([a-z0-9._-]+)\"?"
                       "组 2：值，引号可选——这两个组就是 replace 或后续处理要用的东西")
                 (cons "\\]"
                       "字面量 ]"))
           '())))

(define (recipe-topics)
  (for/list ([t (in-list (remove-duplicates (map recipe-topic recipes)))]) t))

(define (recipes-in-topic topic)
  (filter (lambda (r) (eq? (recipe-topic r) topic)) recipes))

;; find a recipe by exact id
(define (recipe-by-id id)
  (for/first ([r (in-list recipes)] #:when (eq? (recipe-id r) id)) r))

(provide (struct-out recipe) recipes recipe-topics recipes-in-topic recipe-by-id)
