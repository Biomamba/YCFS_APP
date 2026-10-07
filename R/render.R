# =============================================================================
# 消息渲染
# =============================================================================
# ⚠️ 这里的安全规则不能动：
#
# commonmark::markdown_html() **默认不转义原始 HTML**。实测：
#
#     markdown_html("<script>alert(1)</script>")
#     → <script>alert(1)</script>          ← 原样通过
#
# 而消息内容是彻头彻尾的不可信输入：模型生成的、用户粘贴的、甚至上传文件
# 里被模型复述出来的。直接渲染 = 任何一条消息都能在**所有**访问者的浏览器
# 里执行任意脚本（本应用没有登录，就没有任何东西能限制它）。
#
# 所以必须"先转义，再交给 commonmark"。但反过来，代码块不能走 commonmark ——
# commonmark 自己会转义代码块里的 < 和 &，我们再转一遍就成了二次转义：
#
#     ```r\nx <- c(1,2)\n```  →  x &amp;lt;- c(1,2)   ← 显示成乱码
#
# 两条路径分开走，是这段代码的全部要点。
# =============================================================================

#' 中和 HTML 里的危险链接
#'
#' 转义挡不住 Markdown 链接语法：`[点我](javascript:alert(1))` 里没有任何
#' `<` `>` `&` `"`，转义原样放过，commonmark 却会把它渲染成一个**真的**
#' `<a href="javascript:alert(1)">`。`data:text/html;base64,...` 同理。
#'
#' commonmark 1.9.2 没有暴露 cmark 的 CMARK_OPT_SAFE（markdown_html 的形参里
#' 根本没有 options），所以只能自己在输出上做一遍。
#'
#' 判定方式：把 URL 里的空白和控制字符全部去掉、转小写，再看前缀是不是
#' http/https/mailto。必须先去空白再比较，否则 `java\tscript:` 这种写法
#' 能骗过朴素的前缀匹配。实体编码不用担心 —— cmark 在解析阶段就把
#' `&#106;avascript:` 解码成 `javascript:` 了，我们看到的是解码后的结果。
#'
#' 不合格的链接不是删掉整段，而是去掉 href：链接文字保留下来变成普通文本，
#' 用户看得到内容，只是点不动。
#' @param allow_data ★ Test_V15.2：放行 `data:image/*` 的 `src`。
#'   只给**邮件**那条路开（`dsapp_mail_render` 走的就是它）。
#'
#'   为什么非开不可：邮件客户端拿不到你工作区里的相对路径，
#'   `dsapp_html_inline()` 把 `<img src="fig1.png">` 换成
#'   `data:image/png;base64,...` 之后，如果这里再把 src 剥掉，
#'   收件人看到的就是一篇**图全是裂的**报告 —— 而文献速递那种
#'   "十几个 <img> 全是本地文件"的产出正是主力场景。
#'
#'   ⚠️ 默认 FALSE 不能改。网页预览那条路不需要 data:（同源的文件有
#'      自己的 URL），而放开它等于把 `src` 的白名单从"我们能控制的
#'      URL"放宽到"任何内联数据"，白白多一类要论证的东西。
#'
#'   ⚠️ 放行的正则**故意不含 svg**：SVG 里能塞 `<script>`，而各家邮件
#'      客户端对 data: URI 里的 SVG 处理得不一致。只放位图，见
#'      `DSAPP_MAIL_DATA_SRC_RE`。
#'
#' @param allow_src ★ Test_V15.3 item 6：**精确放行**的一串地址（不是正则）。
#'   由 `dsapp_md_inline_images()` 生成 —— 它把 `![](figures/a.png)` 这类
#'   相对路径换成了本会话私有的 dataobj 地址，而那些地址形如
#'   `session/<token>/dataobj/pv-<hash>?...`，**过不了 `^https?://`**，
#'   不额外放行就会被这里整个剥掉：标签还在、图没了、不报错。
#'
#'   ⚠️ 为什么是**精确匹配**而不是像 allow_data 那样给一条前缀正则：
#'      正则要写对就得先知道 shiny 拼出来的地址长什么样（不同版本不一样），
#'      而猜错的后果是"要么图不显示、要么白名单开得过宽"。精确匹配只需要
#'      我们**自己刚生成的那几个字符串**，多一个都不认 —— 白名单的宽度
#'      由生成方决定，这里不做任何推断。
#'
#'   ⚠️ 只作用于 **src**，不作用于 href。生成方只把地址用在图片上，把 href
#'      也一起放宽等于凭空多一类可点的链接。
dsapp_sanitize_links <- function(html, allow_data = FALSE, allow_src = NULL) {
  if (is.null(html) || !nzchar(html)) return(html)
  # ★★ Test_V15.4：只在**标签里面**找属性。
  #
  # ⚠️⚠️ 这条不是优化，是修一个当场踩到的 bug。这一版把属性正则从
  #    `attr="…"` 放宽到"单双引号都认"之后，它在**代码块里**也匹配上了：
  #    `dsapp_escape()` 只转义 `& < > "` 四个字符，**单引号原样留着** ——
  #    于是一段代码里的 `src='a.png'` 会被当成真的属性，白名单判它不过、
  #    替换成空串，用户看到的代码就**凭空少了一截**（实测：
  #    `parts.append("<img src='a.png'>")` 渲染成 `parts.append("<img >")`）。
  #
  #    只在标签内部找就没有这个问题：commonmark 会把代码里的 `<` 转义成
  #    `&lt;`，所以这份 HTML 里**每一个字面的 `<` 都是一个真标签的开头**。
  #    （推论：`[^<>]*` 里不可能出现字面的 `<`；而 `>` 只可能出现在我们自己
  #    拼的标签里 —— `dsapp_md_allow_img()` 把值里的 `>` 转义成了 `&gt;`，
  #    commonmark 自己生成的属性值也一样，实测 `![a>b](x.png)` 出来的是
  #    `alt="a&gt;b"`。）
  tag_re <- "<[A-Za-z/][^<>]*>"
  tag_m  <- gregexpr(tag_re, html)
  tags   <- regmatches(html, tag_m)[[1]]
  if (!length(tags)) return(html)

  # ★ 归一化必须和"判断是不是危险协议"用**同一套**变换：去空白和控制字符、
  #   转小写。否则 `java\tscript:` 那种写法能骗过前缀匹配（见函数头）。
  #   额外把 `&amp;` 还原成 `&` —— commonmark 会把我们生成的地址里那个 `&`
  #   转义掉（`...?w=..&amp;nonce=..`），不还原的话精确匹配永远对不上，
  #   症状又是"图没了、不报错"。
  norm_url <- function(u) {
    u <- tolower(gsub("[[:space:][:cntrl:]]", "", u))
    gsub("&amp;", "&", u, fixed = TRUE)
  }
  allowed_src <- if (length(allow_src)) norm_url(as.character(allow_src)) else character(0)

  # ★ Test_V15.4 item 5：属性正则**单双引号都要认**。
  #
  # ⚠️ 这里原来写死 `attr="[^"]*"`。那意味着 `src='…'`（**单引号**）这一处
  #    在这条消毒链上是**完全失明**的 —— 白名单一条都不判、原样放行。
  #    用户 item 6 贴出来的那段原文恰好就是单引号：
  #        <img alt='五星红旗 PNG' src='data:image/png;base64,…'>
  #    也就是说，光把 `<img>` 放行、不改这里，等于给单引号写法开了一扇没有
  #    任何检查的门。这不是"顺手补的小洞"，是**必须和放行 img 同批做**的事。
  sanitize_attr <- function(html, attr, allowed, exact = character(0)) {
    pat <- paste0("\\b", attr, "\\s*=\\s*(\"[^\"]*\"|'[^']*')")
    hits <- regmatches(html, gregexpr(pat, html))[[1]]
    if (length(hits) == 0) return(html)

    fixed <- vapply(hits, function(h) {
      # `attr="…"` / `attr = '…'` → 取引号中间的部分
      rest <- trimws(substr(h, regexpr("=", h, fixed = TRUE)[[1]] + 1L, nchar(h)))
      url  <- substr(rest, 2L, nchar(rest) - 1L)
      norm <- norm_url(url)
      if (length(exact) && norm %in% exact) return(h)
      if (grepl(allowed, norm)) h else ""
    }, character(1), USE.NAMES = FALSE)

    regmatches(html, gregexpr(pat, html)) <- list(fixed)
    html
  }

  # src 默认只放行 http/https：data: 图片在多数浏览器里不执行脚本，
  # 但没有非用它不可的理由，直接收紧。邮件那条路是例外，见 allow_data。
  src_allowed <- if (isTRUE(allow_data)) {
    paste0("^https?://|", DSAPP_MAIL_DATA_SRC_RE)
  } else "^https?://"

  fixed <- vapply(tags, function(t) {
    t <- sanitize_attr(t, "href", "^(https?://|mailto:)")
    sanitize_attr(t, "src", src_allowed, exact = allowed_src)
  }, character(1), USE.NAMES = FALSE)

  regmatches(html, tag_m) <- list(fixed)
  html
}

# ---- 放行一批「无属性的排版标签」（Test_V15.3 item 6）------------------------
#
# 用户原话：「言出法随界面输出的 md 似乎很多标记语言未能正常渲染」，
# 追问后确认的第一条是「HTML 标签变字面文字」—— 模型直接写的 `<h4>…</h4>`
# 在对话框里显示成一行 `&lt;h4&gt;`。
#
# 根因不是 bug 而是取舍：`dsapp_escape()` 把**所有** `<` 转义掉（那是防 XSS
# 的铁律，见本文件开头），commonmark 拿到的已经不是 HTML 了，于是模型写的
# 每一个标签都变成字面文字。线上 13 条真实消息里有 `<h4>` / `<p>` / `<br>` /
# `<details>` / `<figure>` —— 都是模型在"用 HTML 排版"，而我们全给废掉了。
#
# 这一节就是在转义之后**把白名单里的标签还原回去**。
#
# ★★ 白名单守住两条，缺一条就是 XSS 入口：
#
#   ① **全小写**（大小写敏感）。`<H4>` / `<Error>` / `<SCRIPT>` 一律不认。
#      这不是随手写的严格 —— 它正是"模型在描述一段 XML / 一个 HTML 文件"
#      和"模型在用 HTML 排版"这两件事的分界线。线上那些
#      `<Error><Code>NoSuchKey</Code></Error>`（S3 报错原文）和
#      `<html><head><meta><title>`（模型在讲一个文件长什么样）**必须**
#      保持字面文字：渲染出来它们会从屏幕上消失，而那正是用户要看的字。
#
#   ② **无属性**。正则里 `\s*(/?)` 只允许"标签名 + 可选斜杠"，带任何属性
#      （`<h4 onclick=…>`、`<p style=…>`）都不匹配。没有属性就没有
#      `on*` 事件、没有 `style`、没有 `href`/`src` —— 这一层不引入任何
#      新的可执行面、也不引入任何新的外链。
#
#   `<script>` / `<style>` / `<iframe>` / `<a>` / `<img>` **不在表里**，
#   照旧转义。`<a>` / `<img>` 尤其不能放：它们的危害全在属性上，而"无属性"
#   这条规则恰恰是放行它们的唯一理由 —— 干脆别放。
DSAPP_MD_SAFE_TAGS <- c(
  "br", "hr", "p", "div", "span",
  "b", "strong", "i", "em", "u", "s", "del", "ins", "mark", "small",
  "sub", "sup", "kbd", "samp", "var", "abbr", "cite", "q", "time",
  "code", "pre", "blockquote",
  "ul", "ol", "li", "dl", "dt", "dd",
  "details", "summary", "figure", "figcaption",
  "table", "thead", "tbody", "tfoot", "tr", "th", "td", "caption",
  "colgroup", "col",
  "h1", "h2", "h3", "h4", "h5", "h6"
)

# ---- 「哪些行是代码」：这一步是 V15.4 item 6 的根 ---------------------------------
#
# ★★★ 现场（线上 messages.id = 391，「绘制国旗」那个会话）：
#
#   我会修正 GIF 帧转换，…内存低于 500 MB。```python
#   import base64
#   …
#   parts.append("<h2>实际静态图</h2>")
#   ```
#
# 模型把**开围栏粘在正文行尾**了（`…500 MB。` 和 ` ```python ` 之间没有换行）。
# CommonMark 的规矩是：围栏必须**自成一行**，粘在段落里的那三个反引号只是普通
# 文字。于是整段 Python 被当成**散文**去渲染 —— 标题变成真标题、代码塌成一行、
# 用户看到的就是「完全没有渲染」那一片乱码。
#
# 而 `dsapp_md_allow_tags()` 当时是**全局 gsub**、完全不看围栏，于是那些
# `parts.append("<h2>…")` 里的 `&lt;h2&gt;` 被还原成了**活的 `<h2>` 元素** ——
# 浏览器拿到 `<pre>` 里冒出来的块级元素就把 `<pre>` 当场截断，剩下的全乱。
#
# 所以这一节干两件事，缺一不可：
#   ① `dsapp_md_repair_fences()` —— 把粘在正文行尾的围栏拆到独立一行，
#      让 commonmark 也认它是围栏（**只有拆完，代码才会真的渲染成代码块**）；
#   ② `.dsapp_md_code_lines()` —— 逐行标出"这是代码"，让白名单**只在代码之外**
#      动手。修好 ① 之后它俩是一致的；① 没修到的（不认识的围栏写法），
#      它仍然是最后一道闸。
#
# ⚠️ 这一节是**纯函数**，自检里拿线上真实消息钉死。它出错的症状是"某些消息又
#    开始乱渲染"，而不是报错。
#
# 认哪些行是代码：
#   · 围栏（``` 或 ~~~，>=3 个）——**含"粘在正文行尾"的那种**（故意比 CommonMark
#     宽松：多保护一行的代价是"那个标签按字面显示"，少保护一行的代价是 XSS 面）；
#   · 四空格 / Tab 缩进的代码块 —— 按 CommonMark 的规矩，**不能打断段落**
#     （所以 `    foo` 紧跟在 `bar` 后面时不算代码，那只是段落的续行）。
#' 按 `\n` 切行，**保留结尾那个空行**
#'
#' ⚠️ 不能直接用 `strsplit(txt, "\n")`：它把结尾的空字段吃掉
#'    （`"a\n"` → `c("a")`），于是"切完再拼回去"少了最后一个换行。
#'    渲染上看不出区别（commonmark 不在乎行尾空白），但这一节的两条不变量是
#'    **逐字节**的 —— `dsapp_md_repair_fences()` 对"没有粘围栏"的消息必须
#'    一个字都不改，自检就是这么钉的。实测线上 8 条消息因为这个假改动
#'    被判成"被修复过"。
.dsapp_md_lines <- function(txt) {
  lines <- strsplit(txt, "\n", fixed = TRUE)[[1]]
  if (nzchar(txt) && endsWith(txt, "\n")) lines <- c(lines, "")
  lines
}

.dsapp_md_code_lines <- function(txt) {
  lines <- .dsapp_md_lines(txt)
  n <- length(lines)
  out <- logical(n)
  if (n == 0L) return(out)

  fence_char <- ""      # "" = 没开围栏；否则是 "`" 或 "~"
  fence_len  <- 0L
  indented   <- FALSE   # 上一行是不是"缩进代码块"（决定这一行能不能续上）
  prev_blank <- TRUE

  for (i in seq_len(n)) {
    ln <- lines[[i]]
    blank <- !nzchar(trimws(ln))
    this_indented <- FALSE

    if (nzchar(fence_char)) {
      out[[i]] <- TRUE
      # 闭围栏：同一种字符、长度 >= 开围栏、行内除了它和空白什么都没有
      m <- regmatches(ln, regexec("^ {0,3}(`{3,}|~{3,})[ \t]*$", ln))[[1]]
      if (length(m) == 2L && substr(m[[2]], 1L, 1L) == fence_char &&
          nchar(m[[2]]) >= fence_len) {
        fence_char <- ""; fence_len <- 0L
      }
    } else {
      m <- regmatches(ln, regexec("^ {0,3}(`{3,}|~{3,})", ln))[[1]]
      if (length(m) == 2L) {
        fence_char <- substr(m[[2]], 1L, 1L); fence_len <- nchar(m[[2]])
        out[[i]] <- TRUE
      } else {
        g <- .dsapp_md_glued_pos(ln)
        if (g > 0L) {
          # ★ 粘在正文行尾的围栏（msg 391 那种）。整行都按代码算 —— 它本来就
          #   是模型写代码时那一行，正文部分只在开头那一小段。
          fence_char <- substr(ln, g, g)
          fence_len  <- 3L
          out[[i]] <- TRUE
        } else if (grepl("^( {4,}|\t)", ln) && (indented || prev_blank)) {
          out[[i]] <- TRUE; this_indented <- TRUE
        }
      }
    }

    if (!blank) indented <- this_indented
    prev_blank <- blank
  }
  out
}

#' 把**不是代码**的那些行挑出来单独处理
#'
#' @param txt 已转义的文本。
#' @param f 逐行调用的函数（`function(character(1)) -> character(1)`）。
#' @return 接回去的整段文本。
#'
#' ⚠️ 按 `\n` 切开再拼回去是**逐字节可逆**的（不碰行内的东西），所以拿它做
#'    "只在散文上动手"是安全的。
.dsapp_md_on_prose <- function(txt, f) {
  lines <- .dsapp_md_lines(txt)
  if (!length(lines)) return(txt)
  mask <- .dsapp_md_code_lines(txt)
  # ⚠️ 两个廉价的前置条件，缺了它这一步会拖慢**每 200ms 一次的流式重画**
  #    （V13.12 item 6 记过同一类账：19KB 的 HTML 上多跑几千次 gregexpr，
  #    主线程直接被钉死，用户看到的是"生成报告时未响应"）。
  #      ① 这一行里没有 `&lt;` —— 两个 f 动的都是转义过的标签，没它就没活干；
  #      ② 行内代码段（`…`）里不许动手 —— 那是**代码**，见下面那个函数。
  idx <- which(!mask & grepl("&lt;", lines, fixed = TRUE))
  if (length(idx)) {
    lines[idx] <- vapply(lines[idx], function(line) {
      .dsapp_md_apply_outside_spans(line, f)
    }, character(1), USE.NAMES = FALSE)
  }
  paste(lines, collapse = "\n")
}

#' 在一行散文里，**跳过行内代码段**（`` `…` ``）再调用 f
#'
#' ⚠️ 为什么行内代码也要算代码：`allow_tags` 对它无害（commonmark 在 `<code>`
#'    里会把标签重新转义，显示的仍然是对的），但 `allow_img` 是**重写**不是
#'    放行 —— 它会把 `` `<img src='a.png'>` `` 重拼成 `` `<img src="a.png" />` ``，
#'    用户看到的代码就变了样（引号形状、多一个斜杠）。V15.3 栽过一次
#'    "内联丢属性"，凡是"重写标签"的地方都得先想清楚它在代码里意味着什么。
#'
#' 配对规则照 CommonMark：**反引号串的长度必须相等**才算一对，所以
#' ``` ``a`b`` ``` 里的那个单反引号不闭合。
.dsapp_md_tick_spans <- function(ch) {
  n <- length(ch)
  tick <- ch == "`"
  m <- logical(n)
  i <- 1L
  while (i <= n) {
    if (!tick[[i]]) { i <- i + 1L; next }
    j <- i
    while (j <= n && tick[[j]]) j <- j + 1L
    run <- j - i
    k <- j; kend <- 0L
    while (k <= n) {
      if (!tick[[k]]) { k <- k + 1L; next }
      k2 <- k
      while (k2 <= n && tick[[k2]]) k2 <- k2 + 1L
      if ((k2 - k) == run) { kend <- k2; break }
      k <- k2
    }
    if (kend > 0L) { m[i:(kend - 1L)] <- TRUE; i <- kend } else i <- j
  }
  m
}

#' 这一行里第一个"**不在行内代码段里**的 3+ 反引号/波浪号串"在哪（0 = 没有）
#'
#' ⚠️ 光看"这一行有 ``` 吗"是不够的：`用 ``` 开头、``` 结尾` 是一句**说明
#'    Markdown 怎么写**的正文，那两串反引号是**行内代码段**（长度相等的两串
#'    配成一对），不是围栏。按围栏处理的话，这句话会被从中间拆开、后半句整个
#'    变成代码块 —— 而这是**破坏性**的（`dsapp_md_repair_fences()` 会真的去
#'    改文本）。判反的代价不对称，所以这里多花几行做配对。
.dsapp_md_glued_pos <- function(ln) {
  if (!grepl("`{3,}", ln)) {
    g <- regexpr("~{3,}", ln)
    return(if (g[[1]] > 0L) g[[1]] else 0L)
  }
  ch <- strsplit(ln, "", fixed = TRUE)[[1]]
  m  <- .dsapp_md_tick_spans(ch)
  g  <- gregexpr("`+", ln)[[1]]
  lens <- attr(g, "match.length")
  for (i in seq_along(g)) {
    if (lens[[i]] < 3L) next
    if (!isTRUE(m[[g[[i]]]])) return(g[[i]])
  }
  0L
}

#' 从位置 `g` 起的那一串，**够不够格当开围栏**（而不只是正文里提到的一串反引号）
#'
#' ★ V15.6：判据和 `dsapp_fence_open()` 对齐 —— 围栏后面只允许再跟一个语言
#'   标注，别的什么都不许有。**行中间**的那串反引号在 CommonMark 里永远开不了
#'   围栏，把它当围栏拆开是**破坏性**的：
#'
#'     这一段用 ``` 包起来就行，不用给我代码。
#'
#'   会被拆成「这一段用」+ 一行 `` ``` 包起来就行，不用给我代码。 ``，commonmark
#'   把后半句整个当成 info string 吃掉，界面上只剩「这一段用」，那半句变成一个
#'   **空代码块** —— 用户的半句话凭空消失，而且库里、日志里一个字都不差，
#'   只有盯着屏幕才看得出来（2026-09-30 就是这么发现的）。
#'
#'   上面那条"配对"的判据（`.dsapp_md_glued_pos`）挡不住这一种：它只认**成对**
#'   的行内代码段，而这里那串反引号是**落单**的，配不上对，于是被当成了围栏。
#'   两条判据缺一不可 —— 配对管「提到两串」的写法，这一条管「只提到一串」的。
.dsapp_md_glued_tail_ok <- function(tail) {
  grepl("^(`{3,}|~{3,})[ \t]*[A-Za-z0-9_+-]*[ \t]*$", tail)
}

.dsapp_md_apply_outside_spans <- function(line, f) {
  if (!grepl("`", line, fixed = TRUE)) return(f(line))
  ch <- strsplit(line, "", fixed = TRUE)[[1]]
  n <- length(ch)
  m <- .dsapp_md_tick_spans(ch)
  if (!any(m)) return(f(line))

  # 把连续的"非代码"片段各自交给 f，代码片段原样拼回去。
  out <- character(0)
  s <- 1L
  while (s <= n) {
    if (m[[s]]) { out <- c(out, ch[[s]]); s <- s + 1L; next }
    e <- s
    while (e <= n && !m[[e]]) e <- e + 1L
    out <- c(out, f(paste(ch[s:(e - 1L)], collapse = "")))
    s <- e
  }
  paste(out, collapse = "")
}

#' 把粘在正文行尾的围栏拆到独立一行（Test_V15.4 item 6）
#'
#' LLM 很爱这么写：`…内存低于 500 MB。```python`。CommonMark 不认它（围栏
#' 必须自成一行），于是整段代码被当散文渲染 —— 这是线上 msg 391 的原样。
#' 拆一刀就好了：`…500 MB。` 换行 ` ```python `。
#'
#' ⚠️ **只在围栏之外动手**。已经在围栏里的那些 `"```",` /
#'    `A("```text")`（模型在写生成代码的代码）**一个字都不能碰** —— 拆了会
#'    提前闭合当前围栏，把后面的代码全放出来。线上 msg 156 / 215 / 247 就是
#'    这种形状，自检里钉了这三条真消息。
#'
#' ⚠️ 只在**聊天**那条路开（`.dsapp_md_html_raw(repair = TRUE)`）。邮件正文 /
#'    文件预览 / 论坛走的是同一套渲染，它们的内容不是"模型刚吐出来的话"，
#'    没有理由跟着改 —— 少改一条路就少一处要论证的地方。
dsapp_md_repair_fences <- function(txt) {
  if (is.null(txt) || !nzchar(txt)) return(txt)
  lines <- .dsapp_md_lines(txt)
  fence_char <- ""; fence_len <- 0L
  out <- character(length(lines))

  for (i in seq_along(lines)) {
    ln <- lines[[i]]
    if (nzchar(fence_char)) {
      out[[i]] <- ln
      m <- regmatches(ln, regexec("^ {0,3}(`{3,}|~{3,})[ \t]*$", ln))[[1]]
      if (length(m) == 2L && substr(m[[2]], 1L, 1L) == fence_char &&
          nchar(m[[2]]) >= fence_len) {
        fence_char <- ""; fence_len <- 0L
      }
      next
    }
    m <- regmatches(ln, regexec("^ {0,3}(`{3,}|~{3,})", ln))[[1]]
    if (length(m) == 2L) {
      fence_char <- substr(m[[2]], 1L, 1L); fence_len <- nchar(m[[2]])
      out[[i]] <- ln
      next
    }
    g <- .dsapp_md_glued_pos(ln)
    # ⚠️ 光"找到一串不在行内代码段里的反引号"还不够，它得**真是个开围栏**
    #    （行尾型：后面只跟一个语言标注）。判据见 .dsapp_md_glued_tail_ok()。
    if (g > 0L && .dsapp_md_glued_tail_ok(substr(ln, g, nchar(ln)))) {
      out[[i]] <- paste0(substr(ln, 1L, g - 1L), "\n", substr(ln, g, nchar(ln)))
      fence_char <- substr(ln, g, g)
      fence_len  <- 3L
      next
    }
    out[[i]] <- ln
  }
  paste(out, collapse = "\n")
}

#' 把代码块里**被转义了两遍**的那一层拆掉（Test_V15.4 item 6 的另一半）
#'
#' 修好围栏之后，代码是老老实实进 `<pre><code>` 了 —— 但里面每个引号都显示成
#' `&quot;`、每个 `<` 都显示成 `&lt;`。原因是这条链**转义了两次**：
#'
#'     dsapp_escape()           `"`  →  `&quot;`
#'     commonmark 的代码块       `&`  →  `&amp;`      ← 于是成了 `&amp;quot;`
#'
#' 浏览器把 `&amp;quot;` 显示成 `&quot;` 这五个字符。用户看到的代码就是这样：
#'
#'     parts.append(&quot;&lt;h2&gt;实际静态图&lt;/h2&gt;&quot;)
#'
#' ⚠️ 为什么不在转义那一步"跳过代码区"：那样 commonmark 拿到的就是**原始
#'    `<h2>`**，全靠它自己在代码里再转义一遍 —— 万一我们和它对"哪里是代码"
#'    的判断不一致，放出去的就是活的标签。现在这样是**先按最严的来，再在
#'    确定是代码的地方拆掉多出来的那一层**，出错的方向是"多显示一层 `&amp;`"，
#'    不是 XSS。
#'
#' ⚠️ 只认 commonmark 生成的 `<code>…</code>`：那里面**不可能**出现字面的
#'    `</code>`（`<` 早被它自己转义了），所以按它切是安全的。代码块渲染成
#'    `<pre><code …>…</code></pre>`，行内代码渲染成 `<code>…</code>`，
#'    两种都盖到了。
#'
#' ⚠️ 替换必须是**单趟**的：先拆 `&amp;amp;` 再拆 `&amp;quot;` 会把作者本来
#'    写的 `&amp;quot;`（他就是要显示 `&quot;` 这五个字符）拆过头。写成一条
#'    带分支的正则，R 的 gsub 从左到右扫、不回头看替换结果，正好是对的。
dsapp_md_fix_code_entities <- function(html) {
  if (is.null(html) || !nzchar(html)) return(html)
  m <- gregexpr("(?s)<code[^>]*>.*?</code>", html, perl = TRUE)
  if (m[[1]][[1]] == -1L) return(html)
  blocks <- regmatches(html, m)[[1]]
  fixed <- gsub("&amp;(amp|lt|gt|quot);", "&\\1;", blocks)
  regmatches(html, m) <- list(fixed)
  html
}

# ---- 放行 <img>：只留五个属性，值全部由我们自己重新拼（Test_V15.4 item 5/6）----
#
# 用户原话（item 6 贴的就是这个）：
#
#     <img alt='五星红旗 PNG' src='data:image/png;base64," + base64... + "'>
#
# 这是模型在**报告正文里**写的一张图，而在 V15.3 里 `img` 压根不在
# `DSAPP_MD_SAFE_TAGS` 里（"无属性"那条铁律把它挡在门外），所以它原样显示成
# 一行字面文字。用户要的是**真的显示成图**。
#
# ★★ 这条路松动了"HTML 一律先转义、只还原无属性标签"那条铁律，所以框死的
#    边界必须写在最前面（`R/render.R` 开头那段总纲 + 自检里逐条钉）：
#
#      ① 只放行 **`img` 一个**标签，别的照旧一个字都不放；
#      ② 只认 **src / alt / title / width / height 五个**属性，其余
#         （`onerror` / `style` / `class` / `loading` / `srcset` …）**一律丢掉**；
#      ③ 属性的值**不是照抄原文**，而是"解回原义 → 重新转义 → 由我们用双引号
#         拼出来"。所以就算值里带 `"` 或 `>`，也拼不出第二个属性；
#      ④ `src` 还要过三道：`dsapp_sanitize_links()` 的协议白名单、
#         `dsapp_md_inline_images()` 的**工作区内**包含性校验、
#         `dsapp_md_limit_data_imgs()` 的体积闸门。这一层只管"把标签拼出来"。
#
# ⚠️ 没有 `src` 的（包括写成 `src=x` 这种**不加引号**的）**整个标签原样退回字面
#    文字** —— 认不出来就当前面那一层没开。不加引号的值不认是**故意的**：
#    线上自检里那条 `<img src=x onerror=alert(1)>` 必须继续是字面文字。
#
# ⚠️ 和 allow_tags 共用 `.dsapp_md_on_prose()`：**围栏里写 `<img>` 的 Python
#    源码必须保持字面**（msg 391 的现场就是 `parts.append("<img …>")`）。
dsapp_md_allow_img <- function(txt) {
  if (is.null(txt) || !nzchar(txt)) return(txt)

  keep <- c("src", "alt", "title", "width", "height")
  attr_re <- paste0("([A-Za-z_:][-A-Za-z0-9_:.]*)\\s*=\\s*",
                    "(?:'([^']*)'|&quot;(.*?)&quot;)")

  .dsapp_md_on_prose(txt, function(line) {
    tag_re <- "&lt;img\\b.*?&gt;"
    tags <- regmatches(line, gregexpr(tag_re, line, perl = TRUE))[[1]]
    if (!length(tags)) return(line)

    fixed <- vapply(tags, function(tag) {
      inner <- substr(tag, nchar("&lt;img") + 1L, nchar(tag) - nchar("&gt;"))
      am <- regmatches(inner, gregexpr(attr_re, inner, perl = TRUE))[[1]]
      if (!length(am)) return(tag)

      parts <- regmatches(am, regexec(attr_re, am, perl = TRUE))
      vals <- lapply(parts, function(p) {
        list(name = tolower(p[[2]]),
             val  = if (nzchar(p[[3]])) p[[3]] else p[[4]])
      })
      src <- NULL
      for (v in vals) if (identical(v$name, "src")) src <- v$val
      # ⚠️ 没有 src 就整个退回字面（见函数头最后一条）。
      if (is.null(src) || !nzchar(src)) return(tag)

      out <- character(0)
      for (k in keep) {
        hit <- NULL
        for (v in vals) if (identical(v$name, k)) hit <- v$val
        if (is.null(hit)) next
        raw <- .dsapp_html_unescape(hit)
        if (k %in% c("width", "height") && !grepl("^[0-9]+%?$", raw)) next
        # ⚠️ 拼出去之前**重新转义**（不是照抄原文）：这是"值拼不出第二个属性"
        #    那条保证的落点。用 dsapp_escape 就够 —— 引号在它里面也要转义。
        out <- c(out, paste0(k, '="', dsapp_escape(raw), '"'))
      }
      paste0("<img ", paste(out, collapse = " "), " />")
    }, character(1), USE.NAMES = FALSE)

    regmatches(line, gregexpr(tag_re, line, perl = TRUE)) <- list(fixed)
    line
  })
}

#' 把实体解回原义（`dsapp_escape()` 的逆）
#'
#' ⚠️ 必须**单趟**：`&amp;lt;` 是"作者本来就想显示 `&lt;` 这几个字"，先拆
#'    `&amp;` 再拆 `&lt;` 会把它拆成 `<`，凭空多出一个尖括号。写成一条带分支的
#'    正则，R 的 gsub 从左到右扫、不回头看替换结果，正好是对的。
.dsapp_html_unescape <- function(v) {
  map <- c("&amp;" = "&", "&lt;" = "<", "&gt;" = ">",
           "&quot;" = "\"", "&apos;" = "'", "&#39;" = "'")
  pat <- paste(names(map), collapse = "|")
  m <- gregexpr(pat, v)
  hits <- regmatches(v, m)[[1]]
  if (!length(hits)) return(v)
  regmatches(v, m) <- list(unname(map[hits]))
  v
}

# 聊天气泡里一张内联图最多多少字符。超了就换成一行小字，**不内联**。
#
# ⚠️ 没有这道闸的症状是「聊得越久越卡」，而界面上**看不出任何原因**：
#    每条消息都在 DOM 里，一张 4MB 的 base64 会跟着每一次重画走一遍。
#    邮件那边早就有同类的一道（`DSAPP_MAIL_INLINE_MAX`，5MB），理由一样。
DSAPP_CHAT_INLINE_MAX <- 4 * 1024^2

#' 把过大的 `data:` 内联图换掉（Test_V15.4 item 5）
#'
#' @param max 单张图 src 的字符数上限；`Inf` / NULL 表示不设限。
#' @return 换过的 HTML。**只在 src 是 `data:` 且超长时**动手，其余一个字不改。
#'
#' ⚠️ 位置在 `dsapp_md_inline_images()` **之后**、`dsapp_sanitize_links()` 之前：
#'    放在前面只挡得到"模型直接写的 `<img src='data:…'>`"，挡不到
#'    `![图](data:image/png;base64,…)` 那种（那是 commonmark 渲染出来的）。
dsapp_md_limit_data_imgs <- function(html, max = DSAPP_CHAT_INLINE_MAX) {
  if (is.null(html) || !nzchar(html)) return(html)
  if (is.null(max) || !is.finite(max)) return(html)
  tag_re <- "<img\\b[^>]*>"
  tags <- regmatches(html, gregexpr(tag_re, html))[[1]]
  if (!length(tags)) return(html)

  fixed <- vapply(tags, function(tag) {
    m <- regmatches(tag, regexec('src\\s*=\\s*"([^"]*)"', tag))[[1]]
    if (length(m) < 2L || !startsWith(m[[2]], "data:")) return(tag)
    if (nchar(m[[2]]) <= max) return(tag)
    '<span class="dsapp-img-omitted">（内联图片过大，已省略）</span>'
  }, character(1), USE.NAMES = FALSE)

  regmatches(html, gregexpr(tag_re, html)) <- list(fixed)
  html
}

#' 把白名单里的标签从 `&lt;x&gt;` 还原成 `<x>`
#'
#' @param txt **已经转义过**的文本（`dsapp_escape()` 的输出）。
#' @return 还原后的文本，仍然可以直接交给 commonmark。
#'
#' ⚠️ 只认 `&lt;` / `&gt;` 这一种写法。**双重转义的不认**：模型如果写的是
#'    `&lt;br&gt;`（本来就想显示"<br>"这几个字），转义之后是
#'    `&amp;lt;br&amp;gt;`，这里匹配不上，原样保留 —— 这是对的。
#'
#' ★★★ Test_V15.4 item 6：**只在代码之外动手**。这一条是那个渲染回归的根 ——
#'    在这之前它是个全局 `gsub`，围栏里 `"<h2>实际静态图</h2>"` 这种字样
#'    也被还原成了活标签。实现见 `.dsapp_md_on_prose()`。
dsapp_md_allow_tags <- function(txt) {
  if (is.null(txt) || !nzchar(txt)) return(txt)
  .dsapp_md_on_prose(txt, function(line) {
    for (t in DSAPP_MD_SAFE_TAGS) {
      # 开标签 / 闭标签 / 自闭合，**只允许标签名与可选的斜杠**。
      # ⚠️ 替换串里那个 `t` 不能省：捕获组只有"可选斜杠"，标签名本身是**字面**
      #    匹配上的，写成 `<\\1\\2>` 会把名字吃掉（`<h4>` 变成 `<>`）——
      #    而它**不报错**，屏幕上是 `<p>&lt;&gt;x&lt;/&gt;</p>` 这种莫名其妙的东西。
      line <- gsub(paste0("&lt;(/?)", t, "\\s*(/?)&gt;"),
                   paste0("<\\1", t, "\\2>"), line)
    }
    line
  })
}

#' 把一段 Markdown 渲染成 HTML 字符串
#'
#' V11 item 1 起从用户须知里提出来复用 —— 文件预览的 .md 分支也要它。
#'
#' ⚠️ 顺序是**先转义、再 commonmark**，不能反。commonmark 默认把内联 HTML
#'    原样放行，所以如果不先转义，用户上传的 .md 里写一句
#'    `<script>...</script>` 就是**真会执行**的脚本；而反过来（先渲染再
#'    转义）会把 commonmark 生成的 `<h2>` 一并转义掉，屏幕上又是一堆字面标签。
#'    dsapp_escape() 只动 & < > " 四个字符，`#`、`*`、`1.` 这些标记字符
#'    原样保留，所以转义之后再交给 commonmark 仍然能正确解析。
#'
#' @param hardbreaks 把段落里的**单个换行**也当成换行（V13.12 item 11）。
#'   只给用户气泡开。默认 FALSE —— 模型写的 Markdown 里，段落内的软换行是
#'   "折行"的意思，硬转成 <br> 会把一段正常的散文切得七零八落。
#'
#'   为什么不用 commonmark 的 hardbreaks 扩展：**1.9.2 没有这个扩展**
#'   （实测 `Invalid commonmark extensions: hardbreaks`）。所以自己在输出上
#'   补一遍，见下面 dsapp_md_hardbreaks()。
#'
#' 没有 commonmark 包时落回"纯文本 + <br>"，不报错、不空白。
#' @param mail ★ Test_V15.2：走邮件那条路（放行 data: 内联图片）。
#'   只由 `dsapp_mail_render()` 传 TRUE，别的地方一律默认 —— 理由见
#'   `dsapp_sanitize_links()` 的 allow_data。
#'
#'   ⚠️ `mail = TRUE` **本身不做内联**，它只是把 src 的白名单放宽。真正的
#'      内联要调用方自己做，而且**必须在消毒之前**做 —— 这正是
#'      `dsapp_mail_render()` 要 `.dsapp_md_html_raw()` 而不是本函数的原因。
dsapp_md_html <- function(txt,
                          extensions = DSAPP_MD_EXTENSIONS,
                          hardbreaks = FALSE,
                          mail = FALSE) {
  html <- dsapp_sanitize_links(.dsapp_md_html_raw(txt, extensions),
                               allow_data = isTRUE(mail))
  if (isTRUE(hardbreaks)) html <- dsapp_md_hardbreaks(html)
  html
}

#' commonmark 开哪些扩展
#'
#' ★ Test_V15.3 item 6：`tagfilter` 是从这一版起加的**第二层**防御，
#'   和 `dsapp_md_allow_tags()` 的白名单配套。
#'
#'   tagfilter 是 cmark 自带的：它把 `<title> <textarea> <style> <xmp>
#'   <iframe> <noembed> <noframes> <script> <plaintext>` 这几个标签的 `<`
#'   转义掉。我们"先转义"这条铁律已经把它们全挡住了，所以现在它是**空转**的
#'   —— 加它的意思是：万一以后有人往 `DSAPP_MD_SAFE_TAGS` 里放了一个不该放的
#'   名字，还有一层 GFM 原生的兜底。实测 commonmark 1.9.2 认这个扩展名
#'   （不认的话 markdown_html 会直接报错，是"启动即崩"而不是静默）。
DSAPP_MD_EXTENSIONS <- c("table", "strikethrough", "autolink", "tagfilter")

#' 转义 + commonmark，**还没消毒** —— 只有两个合法调用方
#'
#' ★ Test_V15.2 从 `dsapp_md_html()` 里拆出来，唯一的目的是让"内联图片"
#' 能插在**渲染之后、消毒之前**。
#'
#' ⚠️⚠️ 为什么非拆不可（这是一个真出过的 bug，别再合回去）：`dsapp_sanitize_links()`
#'    只放行 `^https?://` 的 src，而 `![图](fig.png)` 渲染出来的是**相对路径**，
#'    于是消毒那一步会把 `src="fig.png"` 整个换成空串 —— 标签还在、图没了。
#'    症状极难发现：HTML 是**合法**的（`<img  alt="x" />`，只是多一个空格），
#'    没有任何报错，`dsapp_html_inline()` 拿到手时**已经没有 src 可以换**了，
#'    于是它老老实实报告"0 张内联"—— 而调用方看到的是 `ok: TRUE`。
#'    实测就是这么发生的（2026-09-28，发信探针 0 张图内联，收件人看到裂图）。
#'
#'    ⚠️ 网页预览那条路没暴露这个问题，只是因为**报告是 .html 文件**：
#'       `dsapp_html_read_inlined()` 直接对内联后的 HTML 做事，压根不经过
#'       commonmark 这一步。走 Markdown 的路径（邮件正文）才会踩到。
#'
#' ⚠️ 合法调用方**只有两个**，selftest 有一条哨兵盯着（`V15.2` 一节）：
#'    · `dsapp_md_html()`（本文件，紧跟着就消毒）
#'    · `dsapp_mail_render()`（`R/mail.R`，内联完再消毒，allow_data = TRUE）
#'    别处**一律不许调**。这个函数返回的是可以被 XSS 的 HTML（commonmark
#'    对原始 `<script>` 是原样放行的），绕过消毒就是直通车。
#' @param repair ★ Test_V15.4 item 6：先把"粘在正文行尾的围栏"拆到独立一行。
#'   **只有聊天那条路传 TRUE**（`dsapp_md_chat_html()`）—— 那是模型刚吐出来的话，
#'   它爱这么写；邮件正文 / 文件预览 / 论坛的内容不是这个来路，不跟着改。
#'   理由与现场见 `dsapp_md_repair_fences()`。
.dsapp_md_html_raw <- function(txt, extensions = DSAPP_MD_EXTENSIONS,
                               repair = FALSE) {
  if (is.null(txt) || !nzchar(txt)) return("")
  if (!requireNamespace("commonmark", quietly = TRUE)) {
    message("[dsapp] 没有 commonmark 包，Markdown 按纯文本显示。")
    return(paste(vapply(strsplit(txt, "\n", fixed = TRUE)[[1]],
                        dsapp_escape, character(1)), collapse = "<br>"))
  }
  if (isTRUE(repair)) txt <- dsapp_md_repair_fences(txt)
  # ⚠️ 三步的顺序：转义 → 放行白名单标签 → commonmark。
  #    allow_tags() 必须在**转义之后**（它还原的正是转义产物），也必须在
  #    commonmark 之前（否则 commonmark 看到的还是 `&lt;h4&gt;`）。见它的函数头。
  # ★ V15.4：commonmark 之后还有一步 —— 拆掉代码块里被转义了两遍的那一层，
  #    否则每个引号都显示成 `&quot;`。见 dsapp_md_fix_code_entities()。
  # ★ V15.4 item 5：`dsapp_md_allow_img()` 紧跟 allow_tags，同样在 commonmark
  #    之前、同样只作用于散文行。加在它后面是因为它放行的 `<img …>` 里带属性，
  #    要自己拼、自己转义（见它的函数头）。
  esc <- dsapp_md_allow_tags(dsapp_escape(txt))
  esc <- dsapp_md_allow_img(esc)
  dsapp_md_fix_code_entities(commonmark::markdown_html(esc, extensions = extensions))
}

# ---- 让聊天里的相对路径图片真的显示出来（Test_V15.3 item 6）------------------
#
# 用户原话：「再试一下图片是否也能正常渲染」。模型写 `![图](figures/a.png)`，
# 渲染出来的 src 是**相对路径**，而 `dsapp_sanitize_links()` 只放行
# `^https?://` 的 src —— 于是整个 src 被换成空串：标签还在、图没了、不报错。
#
# 这一节把那些相对路径换成**本会话私有**的 dataobj 地址
# （`dsapp_preview_url()` 给的那种，带会话 token 和一次性 nonce）。
# 换完再把新地址交给消毒那一步做**精确放行**（见 allow_src）。
#
# ⚠️⚠️ 这一节是整个改动里**唯一一处安全边界**，别删下面任何一条校验：
#      模型输出是彻头彻尾的不可信输入（提示注入、它读到的文件内容都会变成它
#      写的话）。没有包含性校验的话，模型写一句 `![](/etc/shadow)` 就能让
#      服务端把任意文件读出来、以图片的名义发进浏览器 —— 而界面上看不出
#      任何异常，只是一张"加载失败"的图。
#
# 认哪些扩展名。**故意和 dsapp_file_kind() 的 image 一类对齐**（files.R），
# 但**去掉 avif/tiff**：`dsapp_image_mime()` 没有它们的分支，会回落到
# `application/octet-stream`，浏览器拿到之后是**下载**而不是显示 ——
# 加了等于给用户一个必然裂的图。
DSAPP_MD_IMG_EXT_RE <- "\\.(png|jpe?g|gif|bmp|webp|svg)$"

#' 把一个 Markdown 图片地址解析成**工作区内**的真实文件路径
#'
#' @param src `![]()` 里那串地址，可能是相对路径、绝对路径、http(s)、data:。
#' @param sid 会话 id —— 相对路径按**这个会话自己的工作区**解析。
#' @return 绝对路径（已 resolve 过符号链接）；不该显示的返回 NULL。
#'
#' ★ 安全判据一共四条，缺一条都不行：
#'   ① 只认本地路径：带协议头的（http/https/data/…）和协议相对的（`//x`）
#'      一律 NULL —— 那些走原本那条白名单，不归这里管。
#'   ② `normalizePath()` **之后**必须落在该会话的工作区内。这一步同时挡掉
#'      `../` 穿越和"工作区里放一个指向外面的符号链接"两种写法 ——
#'      normalizePath 对存在的路径会解析符号链接。
#'   ③ 必须是**已存在的普通文件**（目录、不存在的路径都 NULL）。
#'   ④ 扩展名必须是图片。
dsapp_md_image_path <- function(src, sid, cfg = dsapp_config()) {
  src <- trimws(as.character(src %||% "")[1] %||% "")
  if (!nzchar(src)) return(NULL)
  # ① 带协议头的（`data:`、`http:`、`mailto:`…）和 `//host/x` 不碰
  if (grepl("^[a-zA-Z][a-zA-Z0-9+.-]*:", src) || grepl("^//", src)) return(NULL)
  # 查询串 / 锚点不属于文件名（`![](a.png?v=2)` 是合法的 Markdown 写法）
  src <- sub("[?#].*$", "", src)
  src <- tryCatch(utils::URLdecode(src), error = function(e) src)

  ws <- dsapp_ws_dir(sid, cfg, create = FALSE)
  # ⚠️ dsapp_ws_dir() 拿不到 sid 时返回 NA_character_，不是 NULL
  if (length(ws) != 1L || is.na(ws) || !nzchar(ws)) return(NULL)
  p <- if (grepl("^/", src)) src else file.path(ws, src)

  root <- tryCatch(normalizePath(ws, mustWork = FALSE), error = function(e) NULL)
  np   <- tryCatch(normalizePath(p, mustWork = FALSE), error = function(e) NULL)
  if (is.null(root) || !nzchar(root) || is.null(np) || !nzchar(np)) return(NULL)

  # ② 包含性校验。⚠️ 别写成 `startsWith(np, root)` —— 那样 `/ws/a` 会
  #    把 `/ws/abc` 也放进来。分隔符必须带上。
  if (!identical(np, root) && !startsWith(np, paste0(root, "/"))) return(NULL)
  # ③ 必须是个真的文件
  if (!file.exists(np) || dir.exists(np)) return(NULL)
  # ④ 必须是图片
  if (!grepl(DSAPP_MD_IMG_EXT_RE, tolower(np))) return(NULL)
  np
}

#' 一个文件的会话私有地址（**同一个会话里永远同一个串**）
#'
#' ★ V15.3 item 6 的一部分，单独拆出来是因为它解决的是一件很容易被忽略的事：
#' Shiny 的 `registerDataObj()` **每调用一次就生成一个新的 nonce**：
#'
#'     session/<token>/dataobj/<name>?w=<worker>&nonce=<每次都不一样>
#'
#' 而服务端收到请求时**只看 `<name>`**（`ShinySession$handleRequest` 里
#' `self$downloads$get(dlname)`），根本不校验 nonce。于是"每次渲染都重新
#' 注册一次"等于**每次渲染都换一个新地址**：
#'
#'   · 流式输出时正文每 200ms 重渲染一次 → `<img src>` 每 200ms 变一次 →
#'     浏览器把同一张图反复重新下载、重新解码。用户看到的是图在闪，
#'     而这一版 item 3 要的正是"别闪"；
#'   · memo 桶满了被清空之后，整屏历史消息的图会一起重新下载。
#'
#' 缓存之后地址稳定，浏览器自己会复用（同一个 URL 就是同一份缓存）。
#'
#' ⚠️ key 用**会话 token**，不是会话 id。同一个对话可以开在两个标签页里，
#'    它们各是一个 Shiny session、各有各的 token —— 按会话 id 缓存的话，
#'    甲标签页拿到的地址在乙标签页里是无效的（那个 token 不是它的）。
#'    `session$token` 在模块的 session_proxy 上够得到（和 registerDataObj
#'    同一条路径，见 CLAUDE 里那条"proxy 不是 session"的说明）。
#' @noRd
dsapp_md_image_url <- function(session, path, cfg = dsapp_config()) {
  tok <- tryCatch(as.character(session$token %||% "")[1] %||% "",
                  error = function(e) "")
  mime <- dsapp_image_mime(path)
  # ⚠️ 拿不到 token 就**不缓存**，直接每次现算。退化成"地址会变"（图可能
  #    重下一次），总好过把甲标签页的地址缓存下来发给乙标签页 —— 那个
  #    症状是"另一个标签页里图全裂"，而且只在开两个标签页时出现。
  if (!nzchar(tok)) {
    return(tryCatch(dsapp_preview_url(session, path, mime, cfg),
                    error = function(e) NULL))
  }
  key <- paste(tok, path, mime, sep = "\r")

  hit <- .dsapp_img_urls[[key]]
  # ⚠️ 命中的必须是**非空字符串**。注册失败时我们什么都不存（见下），
  #    所以这里不会缓存住一次失败 —— 那会让一个本来只是"这一次没读到"的
  #    文件永远显示不出来。
  if (is.character(hit) && length(hit) == 1L && nzchar(hit)) return(hit)

  url <- tryCatch(dsapp_preview_url(session, path, mime, cfg),
                  error = function(e) NULL)
  if (is.null(url) || !nzchar(url)) return(NULL)
  # 长会话别让它无限长下去。清空一次只是让下次渲染重新注册一遍，
  # 地址会变一次（图重新下载一次），代价可接受。
  if (length(ls(.dsapp_img_urls)) >= 2000L) {
    rm(list = ls(.dsapp_img_urls), envir = .dsapp_img_urls)
  }
  .dsapp_img_urls[[key]] <- url
  url
}

# 上面那个缓存的存放处。进程级、到 R worker 换代为止。
.dsapp_img_urls <- new.env(parent = emptyenv())

#' 把 HTML 里指向工作区的 `<img src>` 换成会话私有的可访问地址
#'
#' @param html `.dsapp_md_html_raw()` 的输出（**还没消毒**）。
#' @return `list(html = <换过的 HTML>, srcs = <这次生成的地址们>)`。
#'   `srcs` 要原样交给 `dsapp_sanitize_links(allow_src = )`。
#'
#' ⚠️ 必须在**消毒之前**做。反过来的话相对路径已经被剥成空串，
#'    这里拿到手时已经没有 src 可以换 —— 而且不报错，只是一张裂图。
#'    （Test_V15.2 的邮件路径踩过一模一样的坑，见 `.dsapp_md_html_raw` 的函数头。）
#'
#' ⚠️ 每一张图都会 `registerDataObj()` 一次，注册表挂在**会话**上，会话一关
#'    就跟着没了。所以这个函数**需要 session**，拿不到就原样返回（图不显示，
#'    但也不会报错）。
dsapp_md_inline_images <- function(html, session, sid, cfg = dsapp_config()) {
  if (is.null(html) || !nzchar(html)) return(list(html = html, srcs = character(0)))
  if (is.null(session)) return(list(html = html, srcs = character(0)))

  tags <- regmatches(html, gregexpr("<img\\b[^>]*>", html))[[1]]
  if (!length(tags)) return(list(html = html, srcs = character(0)))

  srcs <- character(0)
  fixed <- vapply(tags, function(tag) {
    m <- regmatches(tag, regexec('src="([^"]*)"', tag))[[1]]
    if (length(m) < 2L) return(tag)
    path <- dsapp_md_image_path(m[2], sid, cfg)
    if (is.null(path)) return(tag)
    url <- dsapp_md_image_url(session, path, cfg)
    if (is.null(url) || !nzchar(url)) return(tag)
    srcs <<- c(srcs, url)
    # ⚠️ 地址里有 `&`（query 串），写回属性时要转义成 `&amp;` —— 否则
    #    HTML 不合法，而且消毒那边的精确匹配还要多做一次还原（见 norm_url）。
    sub('src="[^"]*"', paste0('src="', gsub("&", "&amp;", url, fixed = TRUE), '"'),
        tag)
  }, character(1), USE.NAMES = FALSE)

  # 按出现顺序一对一换回去（vapply 保序，regmatches<- 也是按序替换）
  regmatches(html, gregexpr("<img\\b[^>]*>", html)) <- list(fixed)
  list(html = html, srcs = unique(srcs))
}

#' 聊天正文专用的 Markdown 渲染（Test_V15.3 item 6）
#'
#' 完整链路：
#'
#'     .dsapp_md_html_raw()  →  dsapp_md_inline_images()  →  dsapp_sanitize_links()
#'     转义+白名单+commonmark    相对路径 → 会话私有地址        消毒（含精确放行）
#'
#' ⚠️ **只给聊天正文用。** 邮件那条路（`R/mail.R` 的三步）和文件预览那条路
#'    **不动**：它们的 URL 语义完全不同 —— 邮件要的是 `data:` 内联（收件人
#'    拿不到我们的 dataobj 地址，那儿根本没有会话），文件预览压根不经过
#'    commonmark。三条路各管各的，别为了"统一"把它们并成一条。
#'
#' ⚠️ 调用方必须已经有一个**活着的 session**（`dsapp_preview_url()` 要注册
#'    dataobj）。拿不到 session 时这里会退化成"图不显示"，不会报错。
#' @param inline_data ★ Test_V15.4 item 5：放行 `data:image/*`（**位图，不含 svg**）。
#'   默认 TRUE —— 用户要的就是「聊天里的 `data:image/png;base64` 要真显示成图」，
#'   而那正是模型写报告时贴图的方式（它没有工作区可写，只能内联）。
#'
#'   ⚠️ 名字是 `inline_data` 不是 `allow_data`：那个名字在 `dsapp_sanitize_links()`
#'      上是"这是**邮件**"的意思（收件人拿不到相对路径），而这里的意思完全不同。
#'      两处共用同一个开关名，读代码的人迟早会把其中一处当成另一处。
#'
#'   ⚠️ 复用的是**同一条** `DSAPP_MAIL_DATA_SRC_RE`（`R/mail.R`），**故意不含
#'      `image/svg+xml`** —— SVG 里能塞 `<script>`。别为了"支持更多格式"动它。
dsapp_md_chat_html <- function(txt, session = NULL, sid = NULL,
                               cfg = dsapp_config(),
                               extensions = DSAPP_MD_EXTENSIONS,
                               hardbreaks = FALSE,
                               inline_data = TRUE) {
  # ★ V15.4 item 6：聊天这条路开 fence 修复（见 dsapp_md_repair_fences()）。
  html <- .dsapp_md_html_raw(txt, extensions, repair = TRUE)
  r <- dsapp_md_inline_images(html, session, sid, cfg)
  # ★ V15.4 item 5：体积闸门。必须夹在 inline_images 之后、sanitize 之前 ——
  #   放在前面挡不到 `![](data:image/png;base64,…)` 那种（commonmark 渲染出来的）。
  html <- dsapp_md_limit_data_imgs(r$html, DSAPP_CHAT_INLINE_MAX)
  html <- dsapp_sanitize_links(html, allow_src = r$srcs,
                               allow_data = isTRUE(inline_data))
  if (isTRUE(hardbreaks)) html <- dsapp_md_hardbreaks(html)
  html
}

#' 把 <p> 段落里的软换行变成真换行（V13.12 item 11）
#'
#' 用户在自己那句话里敲的换行，是他**要的**换行。commonmark 默认把段内换行
#' 渲染成一个空格（那是 Markdown 的规矩），于是用户写：
#'
#'     第一行
#'     第二行
#'
#' 在气泡里变成"第一行 第二行"一行 —— 和之前 `white-space: pre-wrap` 的
#' 表现比，这是**退步**，而用户报的是"markdown 不渲染"，不是"顺便把我的
#' 换行也吃掉"。
#'
#' ⚠️ 只在 `<p>…</p>` 里做，别全局替换：
#'    · `<pre><code>` 里的换行是代码的一部分，转了会让每行代码后面多一个
#'      <br>（视觉上多一行空白）；
#'    · `<li>` 之间、`<td>` 之间的换行是 commonmark 的排版缩进，转了只是
#'      多几个空行。
#'    所以只认"`<p>` 开头、到下一个 `</p>` 为止"这一段。
#'
#' ⚠️ 按 `<p>` 切分而不是用正则整体替换：R 的 gsub 没有回调，一次正则替换
#'    没法"只动捕获组里的东西"。而 `<p>` 不可能嵌在 `<p>` 里（commonmark
#'    不生成这种结构），所以按它切是安全的。代码块里的 `<p>` 已经被
#'    dsapp_escape 转成 `&lt;p&gt;` 了，切不到。
dsapp_md_hardbreaks <- function(html) {
  if (is.null(html) || !nzchar(html)) return(html)
  if (!grepl("<p>", html, fixed = TRUE)) return(html)

  parts <- strsplit(html, "<p>", fixed = TRUE)[[1]]
  rest <- parts[-1]
  rest <- vapply(rest, function(x) {
    i <- regexpr("</p>", x, fixed = TRUE)[1]
    if (is.na(i) || i < 0) return(x)          # 没闭合（不该发生），原样放过
    body <- substr(x, 1L, i - 1L)
    tail <- substr(x, i, nchar(x))
    paste0(gsub("\n", "<br />\n", body, fixed = TRUE), tail)
  }, character(1), USE.NAMES = FALSE)

  paste0(parts[1], paste0("<p>", rest, collapse = ""))
}

#' 判断一行是不是"开围栏"，并取出它带的语言标注
#'
#' ★★ 这是平台**唯一**一处开围栏判定：dsapp_split_segments_raw() 和
#'    jobs.R 的 dsapp_parse_code_blocks() 都走它。那两个解析器必须数出
#'    **一样多**的块（mod_chat.R 里那句提醒），所以判定只能有一份。
#'
#' ★ V15.6：原来的判据是"开围栏必须独占行首"（`^\s*````）。2026-09-30
#'   线上栽在这上面 —— 会话「GPT6文献解析」：模型写了
#'       ……首次检索预计耗时 1 分钟、内存低于 0.5 GB。```python
#'   围栏**粘在正文末尾**，两个解析器都当它不存在 → 整段代码被当成正文 →
#'   `dsapp_agent_pick_block` 判 "回复里没有代码块" → 循环走了"模型给出了
#'   结论"那个出口，**没有转圈、没有新消息、没有执行**，用户看到的就是
#'   "跑到一半停住了"。同类回复此前已经有 6 条这样静默死掉（见 selftest
#'   里那组断言）。
#'   现在：开围栏可以粘在正文后面，条件是**它后面到行尾**只有一个语言标注
#'   （`python` / `r` / 什么都没有）。前面那半句还给正文（prefix）。
#'
#'   闭合围栏仍然要求独占一行（`^\s*```\s*$`）—— 反过来的话，代码里的
#'   `s <- "```"` 会被当成块结束、把后面半段代码**静默截掉**，那比这次的
#'   bug 更坏：跑出来的东西少一半，谁都不知道。
#'
#' @return NULL（这行不是开围栏），
#'   或 list(prefix=围栏前的正文, lang=语言标注, ticks=反引号个数)
#' @noRd
dsapp_fence_open <- function(line) {
  # 字面量预筛，理由见下面 V13.12 item 6 那段（一行里连三个反引号都没有，
  # 就不可能是围栏，直接跳过两个正则）
  if (!grepl("```", line, fixed = TRUE)) return(NULL)

  # ① 标准写法：行首围栏
  if (grepl("^\\s*```", line)) {
    m <- regmatches(line, regexec("^\\s*(```+)\\s*([A-Za-z0-9_+-]*)", line))[[1]]
    if (length(m) < 3) return(NULL)
    return(list(prefix = "", lang = m[3], ticks = nchar(m[2])))
  }

  # ② 粘在正文后面的围栏：``` 之后到行尾只剩语言标注。
  #    用 regexpr（会逐位置试）而不是 grepl —— "a ``` b ```python" 这种
  #    要认**最后一个**（从它开始能一路匹配到行尾），前面那个留在正文里。
  pos <- regexpr("```+\\s*[A-Za-z0-9_+-]*\\s*$", line)
  if (pos < 0) return(NULL)
  m <- regmatches(line, regexec("(```+)\\s*([A-Za-z0-9_+-]*)\\s*$", line))[[1]]
  if (length(m) < 3) return(NULL)
  list(prefix = sub("\\s+$", "", substr(line, 1L, pos - 1L)),
       lang   = m[3],
       ticks  = nchar(m[2]))
}

#' 判断一行是不是"闭合围栏"
#'
#' ★ V15.6：判据从"正好三个反引号"改成 CommonMark 的规矩 —— 闭合围栏只能
#'   是反引号（前后允许空白），且反引号个数**不少于**开围栏。
#'   为什么必须带上"不少于"：提示词里明明白白写着「代码内部如果也有 ```
#'   请改用四个反引号包住」（agent.R 的 unclosed 回喂那条），可原来的闭合
#'   判据只认正好三个 —— 模型**照提示词做**反而更解析不出来：四个反引号开头
#'   的块永远等不到结束围栏，回喂让它重发，它再发一次四个反引号，一直到
#'   轮次上限。这也是"平台说的话和平台的实现不一致"那一类。
#'   带上"不少于"之后，四个反引号块里的 ``` 行是**内容**不是结束（这正是
#'   CommonMark 那条规矩存在的理由：不然举例写 markdown 会被截断）。
#'
#' @noRd
dsapp_fence_close <- function(line, ticks = 3L) {
  if (!grepl("```", line, fixed = TRUE)) return(FALSE)   # 字面量预筛
  grepl("^\\s*`+\\s*$", line) && nchar(gsub("[^`]", "", line)) >= ticks
}

#' 把消息切成"文本段"和"代码块"交替的序列
#'
#' 与 dsapp_parse_code_blocks() 的区别：那个只返回代码块，这个保留代码块
#' 在原文中的位置，这样渲染时能还原原始顺序。
#'
#' 未闭合的围栏（流式输出到一半时很常见）按"直到结尾都是代码"处理，
#' 否则用户会看到代码被当成正文渲染，闪烁一下再变成代码块。
dsapp_split_segments <- function(content) {
  if (is.null(content) || !nzchar(content)) return(list())
  # 纯函数，按正文摘要缓存（见 dsapp_memo）。历史消息的正文落库之后不再变，
  # 所以整段历史重画时这一格基本全是命中。
  dsapp_memo("split", digest::digest(content, algo = "xxhash64"),
             function() dsapp_split_segments_raw(content))
}

#' @noRd
dsapp_split_segments_raw <- function(content) {
  lines <- strsplit(content, "\n", fixed = TRUE)[[1]]
  n <- length(lines)
  idx <- 0

  # ⚠️★ V13.12 item 6：这一段原来是 `buf <- c(buf, lines[i])`、
  #    `body <- c(body, lines[i])`、`segs[[length(segs) + 1]] <- …`
  #    —— 三个都在循环里一边算一边长大。R 的 c() 和 list 增长每轮都
  #    **整份复制**，所以整段是 O(n²)：一份 40KB 的报告（约 1000 行）
  #    单是搬这些行就要几十毫秒，而它每渲染一屏就跑一次（历史重画、
  #    流式每 200ms 一次）。用户报的"生成报告的时候未响应"里，这是
  #    排在 linkify 后面的第二个大头。
  #
  #    改法：上界就是行数（最坏情况每行自成一段也装得下），先分配、
  #    用下标写，最后一次截断。零次复制。
  segs  <- vector("list", n)
  n_seg <- 0L
  buf   <- character(n); n_buf  <- 0L
  body  <- character(n); n_body <- 0L

  flush_text <- function() {
    if (n_buf > 0L) {
      n_seg <<- n_seg + 1L
      segs[[n_seg]] <<- list(type = "text",
                             text = paste(buf[seq_len(n_buf)], collapse = "\n"))
      n_buf <<- 0L
    }
  }

  # ★ V13.12 item 6：真正的围栏判定是带 ^…$ 锚点的正则，每行要跑两次
  #   （正则在 UTF-8 上还要逐字符走）。加一道固定的字面量预筛 —— 一行里
  #   连三个反引号都没有，就不可能是围栏，直接跳过整个正则。
  #   实测 1000 行的正文从 4.2ms 降到 1ms 出头。
  #   ★ V15.6：这段判定搬到 dsapp_fence_open() / dsapp_fence_close() 里了
  #   （两个解析器共用一份），预筛也跟着搬过去，那条预筛别丢。
  i <- 1L
  while (i <= n) {
    # ★ V15.6：开围栏的判定统一走 dsapp_fence_open()（原来这里是一句
    #   `grepl("^\\s*```")`）—— 现在"粘在正文后面的围栏"也算数，
    #   理由和代价都写在那上面。
    fo <- dsapp_fence_open(lines[i])
    if (!is.null(fo)) {
      i0      <- i
      lang    <- fo$lang
      n_ticks <- fo$ticks

      n_body <- 0L
      i <- i + 1L
      # 结束围栏要**不少于**开围栏的反引号数，见 dsapp_fence_close()
      while (i <= n && !dsapp_fence_close(lines[i], n_ticks)) {
        n_body <- n_body + 1L
        body[n_body] <- lines[i]
        i <- i + 1L
      }
      closed <- i <= n      # 有没有找到闭合围栏
      i <- i + 1L

      # ★ V15.6：空的 + 没闭合 = 这**不是**代码块，是正文里正好以一个 ```
      #   收尾的一句话（流式流到一半也是这个样子）。原来这一支会把后面的
      #   正文**整段吃掉**（`i` 已经推到结尾了），现在整行还回正文。
      if (n_body == 0L && !closed) {
        n_buf <- n_buf + 1L
        buf[n_buf] <- lines[i0]
        i <- i0 + 1L
        next
      }

      # 粘在正文后面的围栏：围栏前那半句还给正文。必须在 flush_text() 之前
      # 进缓冲，否则它会跑到代码块后面去（顺序反了）。
      if (nzchar(fo$prefix)) {
        n_buf <- n_buf + 1L
        buf[n_buf] <- fo$prefix
      }
      flush_text()

      if (n_body > 0L) {
        idx <- idx + 1L
        n_seg <- n_seg + 1L
        segs[[n_seg]] <- list(
          type = "code", lang = dsapp_norm_lang(lang),
          # ⚠️ 这里必须解码（V11 item 7）。模型有时把中文写成字面的 \uXXXX，
          #    落在符号位置（列名）时 R 连解析都过不去 —— task#11 就是这么
          #    挂在 92% 的。解码对字符串是等价改写、对符号位是修复，
          #    详见 utils.R 的 dsapp_decode_uescapes()。
          code = dsapp_decode_uescapes(paste(body[seq_len(n_body)], collapse = "\n")),
          index = idx, closed = closed
        )
      }
    } else {
      n_buf <- n_buf + 1L
      buf[n_buf] <- lines[i]
      i <- i + 1L
    }
  }
  flush_text()
  if (n_seg < n) segs <- segs[seq_len(n_seg)]
  segs
}

#' 进程级的内容缓存
#'
#' 渲染是**纯函数**：同一段正文 + 同一份产物名单，渲染出来永远一样。
#' 而它被调用的频率和"内容变没变"完全无关 —— 流式每 200ms 一次、
#' 历史每次重画一次、切页面又重画一次。所以按内容摘要缓存是安全的。
#'
#' ★ V13.12 item 6 加的。用户报"生成报告的时候未响应了几次"：一篇报告
#' 正文渲染一次要几十到几百毫秒，而它一秒钟被要求重画五次，主线程
#' 根本喘不过气。真正把成本压下来的是这条缓存 —— 前面那些 O(n²) 的
#' 优化只是把单次成本降一个量级，缓存是把**次数**从"每秒五次"降到
#' "内容真的变了才一次"。
#'
#' @param bucket 桶名。不同用途分开存，免得互相把对方挤出去。
#' @param key 内容摘要（用 digest 算，别直接把正文当 key —— environment
#'        的查找要拿整个字符串做哈希，几万字的正文每次查都白扫一遍）。
#' @param compute 未命中时算一次。**不要返回 NULL**：environment 里存
#'        NULL 读出来还是 NULL，会被当成没命中，等于永远不缓存。
#' @param cap 条目上限。超了整桶清空 —— 长会话别无限长下去。
#' @noRd
dsapp_memo <- function(bucket, key, compute, cap = 500L) {
  st <- dsapp_state()
  if (is.null(st$memo)) st$memo <- new.env(parent = emptyenv())
  b <- st$memo[[bucket]]
  if (is.null(b)) {
    b <- new.env(parent = emptyenv())
    st$memo[[bucket]] <- b
  }
  hit <- b[[key]]
  if (!is.null(hit)) return(hit)
  v <- compute()
  if (length(ls(b)) >= cap) rm(list = ls(b), envir = b)
  b[[key]] <- v
  v
}

#' 扫描结果缓存
#'
#' 渲染一条消息时每个代码块都要扫描一次；一个长会话可能有几十个代码块，
#' 每次重渲染都重扫一遍会明显卡顿。消息一旦落库内容就不再变，
#' 所以按代码内容的摘要缓存是安全的。
dsapp_scan_cached <- function(code) {
  st <- dsapp_state()
  if (is.null(st$scan_cache)) st$scan_cache <- new.env(parent = emptyenv())

  key <- digest::digest(code, algo = "xxhash64")
  if (!is.null(st$scan_cache[[key]])) return(st$scan_cache[[key]])

  res <- dsapp_scan_code(code)
  # 简单封顶，防止长会话无限增长
  if (length(ls(st$scan_cache)) > 500) rm(list = ls(st$scan_cache), envir = st$scan_cache)
  st$scan_cache[[key]] <- res
  res
}

#' 单个代码块卡片
#'
#' @param message_id 消息在数据库里的 id。执行按钮只传"坐标"
#'   （消息 id + 块序号），代码内容由服务端回库重取 —— 浏览器改 DOM
#'   也换不掉要执行的代码。
#' @param executable 流式输出中的消息还没落库，坐标解析不了，
#'   这时不渲染执行按钮。
#' @param ran_ids 本会话已经提交执行过的 code_id。只影响那个纯展示的状态
#'   标签写「已执行」还是「待执行」—— V11 item 10 把按钮挪走之后，卡片上
#'   剩下的就只有状态了，状态说错比没有状态更糟。
dsapp_code_card <- function(seg, message_id, executable = TRUE,
                            running_id = NULL, ran_ids = NULL, alert = TRUE) {
  # ★★ V15.10 item 3（性能）：整张卡片按 (段, 消息, 执行状态) 缓存。
  #
  #    扫描结果早就缓存了（dsapp_scan_cached），但**卡片本身**没有 ——
  #    每个代码块每次重画都要重新拼一遍 HTML。而"重画"在流式输出时是
  #    **每 200ms 一次、每次都是全量正文**：2026-10-02 实测一段 20 KB /
  #    400 段的回复，一次重画 0.13 s，**全部耗在这里**（正文段都命中
  #    segtext 缓存，切段几乎不要钱）。
  #
  #    ⚠️ key 里放的是**整个 seg**，不是挑出来的几个字段（code/lang/closed/
  #       index…）。挑字段的写法在以后给 seg 加新字段时会**静默漏掉它** ——
  #       缓存住旧卡片、界面定格、不报错，正是 V13.17 wall_limit 那个坑。
  #       整个 seg 进 key，新字段自动跟着走。
  #    ⚠️ 执行状态四件套（executable / running_id / ran_ids / alert）也必须
  #       进 key：它们决定卡片上写「执行中 / 已执行 / 待执行」还是画那条
  #       黄条。漏掉哪一个，症状都是"点了执行，卡片还写着待执行"——
  #       看着像没生效。
  #    ⚠️ cap 给 2000 而不是默认的 500：dsapp_memo 装满时是**整桶清空**，
  #       而"一条消息里有几百个代码块"虽然不常见，一旦出现就会每次重画都
  #       把桶灌满再清空（清空 = 下一次全部重算，比不缓存还亏）。真实会话
  #       一条消息最多几十段，2000 这个量级纯粹是给极端情况留的余地。
  dsapp_memo("codecard",
             digest::digest(list(seg, message_id, executable, running_id,
                                 ran_ids, alert), algo = "xxhash64"),
             function() .dsapp_code_card_build(seg, message_id, executable,
                                               running_id, ran_ids, alert),
             cap = 2000L)
}

#' 代码卡片的实际渲染（外面套着 dsapp_code_card 的缓存）
#' @noRd
.dsapp_code_card_build <- function(seg, message_id, executable = TRUE,
                                   running_id = NULL, ran_ids = NULL,
                                   alert = TRUE) {
  scan <- dsapp_scan_cached(seg$code)
  blocked <- nrow(scan$blocked) > 0
  warned <- nrow(scan$warnings) > 0

  # 非 R/Python/Bash 的块（json、txt 之类）不可执行：平台没有对应的执行器，
  # 给个按钮点了也只会报错。
  runnable <- executable && seg$closed && seg$lang %in% c("R", "Python", "Bash")

  code_id <- paste0(message_id, ":", seg$index)

  # 这一格是**纯展示**的状态标签（V11 item 10 把按钮搬去了 composer）。
  # 四种取值：已拦截 / 执行中 / 已执行 / 待执行；不可执行的块（json、txt
  # 之类）四种都不占 —— 返回 NULL，下面那层槽就不渲染。
  #
  # ⚠️ 不可执行**且**没被拦下的块走最后一个 else，落到 NULL。别改成给个
  #    "待执行"：那个块永远执行不了，写上就是骗人。
  status <- if (blocked) {
    tags$span(class = "dsapp-btn dsapp-btn-disabled", "已拦截")
  } else if (runnable && identical(code_id, running_id)) {
    tags$span(class = "dsapp-btn dsapp-btn-running",
      tags$span(class = "spinner-border spinner-border-sm"), "执行中")
  } else if (runnable && code_id %in% (ran_ids %||% character(0))) {
    tags$span(class = "dsapp-code-flag dsapp-code-flag-done", "已执行")
  } else if (runnable) {
    tags$span(class = "dsapp-code-flag", "待执行")
  }

  tagList(
    div(class = paste0("dsapp-code-card", if (blocked) " dsapp-code-blocked"),
      div(class = "dsapp-code-head",
        tags$span(class = "dsapp-code-lang", seg$lang),
        if (!seg$closed) tags$span(class = "dsapp-code-open", "生成中…"),
        div(class = "dsapp-code-actions",
          tags$button(
            class = "dsapp-btn dsapp-code-copy",
            type = "button",
            onclick = "dsappCopyCode(this)",
            "复制"
          ),
          # V11 item 10：「确认执行」**不再挂在这张卡片上**。
          #
          # 用户的原话：「确认执行的按钮不应该在代码框上，而是应该在对话界面
          # 的固定位置，没有方案待确认时是一个灰度颜色，有方案需要确认时
          # 点亮」。理由很实在：模型一次写几十行代码，按钮就落到卡片底部，
          # 用户得先滚到底才能点；而"要不要执行"这个决定和他此刻在看哪一行
          # 没有关系，它属于整页。
          #
          # 这里只留**状态**，不留动作。四种状态各自是纯展示的标签，
          # 点不动 —— 真正的按钮在 composer 里（mod_chat.R 的
          # output$confirm_slot），样式是同一套 dsapp-btn-run。
          #
          # ⚠️ 外面这层 dsapp-code-slot 不是装饰：它给状态那一格一个**固定**
          #    最小宽度。四种状态字数不一样宽（"待执行"三个字，"已拦截"也是
          #    三个字但字号不同，"执行中"还多一个转圈），不钉住的话右边的
          #    「复制」会在开跑那一瞬间横移几个像素 —— V8 item 6 的原话就是
          #    "不要占据其它操作的位置"。钉在**外层**而不是各个状态自己身上，
          #    是为了让"待执行↔执行中"这种切换连字号差都不会漏出来。
          #
          # ⚠️ 不可执行的块（json/txt 之类）**不渲染这个槽**：那类卡片压根
          #    没有状态可显示，留一个空的 5.4rem 只会凭空多一块空白。
          if (!is.null(status)) tags$span(class = "dsapp-code-slot", status)
        )
      ),

      # 必须用 HTML() 拼字符串，不能写成 tags$pre(class=, tags$code(seg$code))：
      # htmltools 会在 <pre> 内部插入换行和缩进（实测 "<pre>\n      <code>…"），
      # 而 <pre> 里所有空白都是要显示的，结果是每段代码的第一行都凭空多出
      # 一个空行和 6 个空格。HTML() 标记为"已是成品 HTML"，htmltools 不再排版它。
      # 转义仍然由我们自己做，且只做一次。
      tags$pre(class = "dsapp-code",
               HTML(paste0("<code>", dsapp_escape(seg$code), "</code>"))),

      # 扫描结果直接显示在卡片下方，用户点执行之前就能看到
      if (blocked) div(class = "dsapp-code-alert dsapp-code-alert-block",
        HTML(paste0("<strong>已拒绝执行</strong>，命中高危指令：<br>",
                    paste(sprintf("第 %d 行：%s", scan$blocked$line, scan$blocked$reason),
                          collapse = "<br>")))),
      # ★★ V15.6 item 13：`alert = FALSE` 时**只**不画这条黄条。
      #
      #   用户原话：「执行结果 · 任务 #176 后面出现了两个确认框，思考过程里
      #   有个确认框，又额外出现了一个确认框，不要这种冗余」。
      #
      #   那一段代码同时被两条渲染路画了"要你确认"：这一条（黄条）和
      #   agent 内联卡（mod_chat.R 的 output$agent_confirm_card，「这一段需要
      #   你确认」+ 继续执行/跳过）。两条说的是同一件事，而**内联卡才是能用的
      #   那一个**（它真的会让循环往下走）。所以循环正停在这一段上时，由调用方
      #   传 alert = FALSE 把这半条让位。
      #   ⚠️ `blocked` 那条**不跟着关**：那是"已拒绝执行"，不是"请你确认"，
      #      两种情况同时在时它必须照样显示。
      #   ⚠️ 别的 warn（net_http_lib / rm_any_recursive 那类自动放行的提示）
      #      走的还是 alert = TRUE 的老路，一个字没变。
      if (warned && !blocked && isTRUE(alert))
        div(class = "dsapp-code-alert dsapp-code-alert-warn",
        HTML(paste0("<strong>请确认后执行</strong>：<br>",
                    paste(sprintf("第 %d 行：%s", scan$warnings$line, scan$warnings$reason),
                          collapse = "<br>"))))
    )
  )
}

#' 把正则元字符原样化
#'
#' 文件名里 `.` 是家常便饭（`volcano.png`），`+` `(` `)` 也合法。直接拼进
#' 正则的话 `.` 会匹配任意字符 —— `a.csv` 就能匹配上 `abcsv`。
dsapp_re_escape <- function(x) {
  gsub("([][{}()+*^$|\\\\?.])", "\\\\\\1", x)
}

#' 产物名单的**预筛**：只留下在这段 HTML 里原样出现过的
#'
#' 这是纯粹的必要条件 —— 正则里每个分支都是字面量（`dsapp_re_escape` 已经把
#' 元字符全转义了），一个在正文里一次都没出现过的名字，在正则里本来就一个
#' 字符都匹配不到。所以筛掉它们**不改变任何结果**，只是把正则从几十万字符
#' 缩到几十个字符。
#'
#' ⚠️⚠️ `useBytes = TRUE` 是这里的命门，不是随手加的。同样的 5262 条名字扫
#'    23KB 正文：不带它 **219ms**，带上 **25ms**（差 9 倍，实测）。
#'    R 在 UTF-8 模式下做固定串查找是逐字符走的，退回字节模式才用得上
#'    memmem。两边都是合法 UTF-8 时两种口径**结果完全一致**（UTF-8 自同步，
#'    字节命中必然落在字符边界上）—— 实测对照过 5262 条的命中向量，
#'    `identical()` 为 TRUE。
#'
#'    这段是**每渲染一屏就要跑一次**的（流式 5 拍/秒；产物名单一变整条历史
#'    重画，每个片段各跑一次），所以 219ms 和 25ms 的差别就是"卡住三秒"和
#'    "无感"的差别 —— 线上那次一秒内 16 条报错，正是 16 个片段一起卡在这。
#' @noRd
dsapp_link_candidates <- function(names, html) {
  if (!length(names) || is.null(html) || length(html) != 1 || !nzchar(html))
    return(character(0))
  # 预筛本身是为了**避免抛错**，它自己更不能抛：真出了意外（比如正文里有
  # 非法 UTF-8）就整份名单原样往下走 —— 后面 dsapp_re_find_all 还会切块。
  tryCatch(
    names[vapply(names, function(n)
      grepl(n, html, fixed = TRUE, useBytes = TRUE), logical(1))],
    error = function(e) names
  )
}

#' 在正文里找出所有命中（长名优先、单趟不重叠），必要时**切块**跑
#'
#' @return list(start, end)：命中区间，**字符**下标（1-based），升序、互不重叠。
#'   调用方拿它跟标签区间做整数比较，不去切字符串。
#'
#' ★★★ V16.7：切块是**正确性**的一部分，不是优化。
#'   PCRE 对编译后的模式有 64KB 上限，而这里要匹配的是"一整个工作区的文件名"
#'   —— 名单一旦上千条，单个正则必然编译不过，那句
#'   `'regular expression is too large'` 会让**整格对话**渲染失败。切块之后
#'   每块都在安全长度内。
#'
#'   合并规则刻意和"单趟扫描"逐字等价：长名先跑 → 按 (起点升序, 长度降序) 排
#'   → 贪心取不重叠的。这正是原来那条正则的语义（V13.12 item 6 的"每个位置
#'   只被消费一次、长的优先"）：同一位置上长名在更前面的块里，排序后它在前，
#'   短的重叠命中被丢掉。
#'
#'   ⚠️ 切块的依据是**转义后的字符数**，不是条数 —— 40 条 `.venv/...` 长路径
#'      比 200 条短名字还长，按条数切照样炸（实测踩过）。
#'   ⚠️ 最后那层 tryCatch 是"永远不许抛错"的兜底：真有一块编译不过，宁可
#'      这一块的名字不变成链接（并留一条日志），也不能让整格对话报废。
#' @noRd
dsapp_re_find_all <- function(names, html, chunk_chars = 16000L) {
  esc <- dsapp_re_escape(names)

  chunks <- list(); cur <- character(0); cur_len <- 0L
  for (i in seq_along(esc)) {
    n_i <- nchar(esc[i]) + 1L          # +1 = 分隔用的 `|`
    if (cur_len + n_i > chunk_chars && length(cur)) {
      chunks[[length(chunks) + 1L]] <- cur
      cur <- character(0); cur_len <- 0L
    }
    cur <- c(cur, esc[i]); cur_len <- cur_len + n_i
  }
  if (length(cur)) chunks[[length(chunks) + 1L]] <- cur

  s_all <- integer(0); e_all <- integer(0)
  for (ch in chunks) {
    p <- sprintf("(?<![[:alnum:]_/])(?:%s)(?![[:alnum:]_/])",
                 paste(ch, collapse = "|"))
    h <- tryCatch(gregexpr(p, html, perl = TRUE)[[1]], error = function(e) {
      tryCatch(dsapp_err_log(e, "linkify"), error = function(e2) NULL)
      -1L
    })
    if (length(h) == 0L || h[1] == -1L) next
    ln <- attr(h, "match.length")
    s_all <- c(s_all, as.integer(h))
    e_all <- c(e_all, as.integer(h) + as.integer(ln) - 1L)
  }
  if (!length(s_all)) return(list(start = integer(0), end = integer(0)))

  o <- order(s_all, -e_all)            # 起点升序；同起点长的在前
  s <- s_all[o]; e <- e_all[o]
  ks <- integer(length(s)); ke <- integer(length(s)); k <- 0L; last <- 0L
  for (j in seq_along(s)) {
    if (s[j] <= last) next             # 和上一处命中重叠 → 丢（长的那处已经在前面）
    k <- k + 1L; ks[k] <- s[j]; ke[k] <- e[j]; last <- e[j]
  }
  list(start = ks[seq_len(k)], end = ke[seq_len(k)])
}

#' 把一个文件名做成可点的下载链接
#'
#' 产生的是一段 HTML 字符串（不是 tagList），因为它的调用点在已经把渲染
#' 交给 commonmark 之后 —— 那里只有字符串可用。
#'
#' ⚠️ 两个属性都过 dsapp_escape：文件名来自用户上传/模型产出，里面有 `"`
#'    完全可能，那会把 onclick 属性撕开、后面的内容变成新的属性。
#' @noRd
dsapp_file_link_html <- function(nm, input_id, title = "点击下载 %s") {
  # ⚠️★ V13.12 item 6：整个 `<a>` 串按 (文件名, input_id, title) 缓存。
  #    这一格是**按命中数**调的 —— 一篇报告里同一个 `volcano.png` 会被
  #    提到几十次。实测单次 0.245ms（其中 0.21ms 是两次 jsonlite::toJSON
  #    的固定开销），命中 100 处就是 25ms；而每 200ms 就要重来一遍。
  #    名字撞上就直接返回，一次 environment 查找的事。
  key <- paste(input_id, title, nm, sep = "\r")
  dsapp_memo("filelink", key, function() {
    js <- sprintf("Shiny.setInputValue(%s,%s,{priority:'event'});return false;",
                  jsonlite::toJSON(as.character(input_id), auto_unbox = TRUE),
                  jsonlite::toJSON(as.character(nm), auto_unbox = TRUE))
    sprintf('<a href="#" class="dsapp-file-link" title="%s" onclick="%s">%s</a>',
            dsapp_escape(sprintf(title, nm)), dsapp_escape(js), dsapp_escape(nm))
  }, cap = 800L)
}

#' 把正文里的文件名变成可点的下载链接
#'
#' 用户的原话：「对话页面弹出的文件名都做成超链接，直接就能显示下载页面」。
#' 模型回答里写「已生成 volcano.pdf」，用户的第一反应就是去点它 ——
#' 以前那只是一串字符，得自己去翻文件页。
#'
#' ⚠️ **只在文本片段里替换，绝不碰标签内部**。整段 HTML 上做 gsub 的话，
#'    文件名会被替换进 href="…"、class="…" 这些属性里，把标签本身撕开；
#'    而文件名是用户可控的（上传时随便起），等于开了一条注入路径。
#'
#' ⚠️ `<a>` 里面不再套 `<a>`。sanitize 只剥 href 不删标签，所以用户写的
#'    `[点我](http://…)` 到这一步已经是一个真的 `<a>`；往里再塞一个，
#'    浏览器会自动闭合外层，后面半句话就跑到链接外面去了。
#'
#' @param names 白名单 —— **只认这个对话自己的产物**。全库匹配的话，
#'        一个叫 `data` 或 `1` 的共享文件会把正文里所有同名字符串都变成链接。
#' @noRd
dsapp_linkify_files <- function(html, names, input_id, title = "点击下载 %s") {
  if (is.null(html) || length(html) != 1 || !nzchar(html)) return(html)
  names <- unique(as.character(names %||% character()))
  names <- names[!is.na(names) & nzchar(names)]
  if (length(names) == 0 || is.null(input_id) || !nzchar(input_id)) return(html)

  # 单趟扫描，长的优先：先替 `volcano.png` 再替 `png` 的话，第二个会把
  # 刚生成的链接再咬一口（它的文字和属性里都含这个串）。合成一个正则
  # 让每个位置只被消费一次，就不存在这个顺序问题。
  names <- names[order(nchar(names), decreasing = TRUE)]

  # ★★ V16.7：这里原来是一句 `sprintf` 直接把**一整个工作区**的名字拼成正则。
  #    工作区里躺着一整个 Python 虚拟环境时（很常见 —— 模型建 venv 装
  #    scanpy/Seurat），名单 5262 条、正则 **43.8 万字符**，PCRE 编译直接失败：
  #
  #        invalid regular expression '…': 'regular expression is too large'
  #
  #    （R 的 gregexpr(perl=TRUE) 用的是 LINK_SIZE=2 的 PCRE2，**编译产物**
  #      上限 64KB；实测源码 31.8KB 能过、66.2KB 报错 —— 卡的是长度、不是条数。）
  #
  #    它抛在 renderUI 里 = **整个 chat-history 那一格报废**：线上被 sanitize
  #    换成 "An error has occurred. Check your logs…"（真实原因只在
  #    /var/log/shiny-server/*.log 里，shiny:shiny 0640，要 sudo），本地则是那句
  #    PCRE 报错。用户报的「Biomamba_ceshi 账号有一个 error」就是这个。
  #    触发条件是**工作区文件够多**，所以看着毫无规律：历史每重画一次就炸一次，
  #    任务跑完（产物名单一变 → 重渲染）也炸 —— 线上那 221 条日志的爆发时刻
  #    和作业收尾严格对齐，就是这个原因。
  #
  #    下面两道防线，目标只有一个：**这个函数永远不许抛错**。
  #    ⚠️ 别图省事改成"名单太长就干脆不链接" —— 那会让正文里的文件名悄悄
  #       点不动，而这个功能的全部意义就是"文件生成了要能点"。
  names <- dsapp_link_candidates(names, html)
  if (length(names) == 0) return(html)

  # ---- 一遍扫描：把"哪一处文字可以替换"算出来，再一次性拼回去 ------------
  #
  # ⚠️★ V13.12 item 6。这里原来逐片段跑正则，一段带 40 张表格的报告
  #    （~3000 个片段）就是 3000 次 gregexpr，实测 19KB 的 HTML 要 200ms；
  #    而它**每渲染一屏就重跑一遍**（流式每 200ms 一次、历史每次重画一次），
  #    主线程直接被钉死 —— 用户报的"生成报告的时候未响应了几次"。
  #
  #    现在整个 HTML 只跑一次 gregexpr 拿绝对偏移，判定全部走整数比较。
  #
  # ⚠️⚠️ 这一版**一个字符都不许用 substr 去切整段 html**。R 的 substr 在
  #    UTF-8 串上是 O(位置)：它得从头逐字符走到起点。所以"对每个标签取一次
  #    substr"看着人畜无害，实际是 O(标签数 × 串长) —— 实测 41KB、2000 个
  #    标签要 **192ms**，正好是这里最大的一笔。（纯 ASCII 的串走字节快路径，
  #    几千次也只要 1.6ms，所以在英文语料上根本测不出来。中文正文里必踩。）
  #
  #    于是：判"命中在不在标签里"用 t_start/t_end 的整数区间；判"在不在
  #    <a> 里"改成**另外找 <a…> / </a…> 的起点**，两边都是升序数组，
  #    双指针推进比较整数就行。只有最后拼接时才切字符串，而那时切的
  #    次数是命中数（通常个位数），不是标签数。
  n_html <- nchar(html)

  hits <- dsapp_re_find_all(names, html)
  if (length(hits$start) == 0L) return(html)
  h_start <- hits$start
  h_end   <- hits$end

  tags <- gregexpr("<[^>]*>", html)[[1]]
  if (tags[1] == -1L) {
    t_start <- integer(0); t_end <- integer(0)
  } else {
    t_len <- attr(tags, "match.length")
    t_start <- as.integer(tags); t_end <- t_start + t_len - 1L
  }
  n_tag <- length(t_start)

  pos_of <- function(re) {
    p <- gregexpr(re, html)[[1]]
    if (p[1] == -1L) integer(0) else as.integer(p)
  }
  # 只认**标签开头**的那两处：`<a ` 也可能是属性值里的一段文本
  # （`<td title="<a ">` 这种病态 HTML），那不算开了一个 <a>。
  # 原来是把标签整段取出来跑 ^<a[[:space:]>]，判据在这里逐字保持。
  a_open  <- pos_of("<a[[:space:]>]")
  a_close <- pos_of("</a[[:space:]>]")
  if (n_tag > 0L) {
    a_open  <- a_open[a_open   %in% t_start]
    a_close <- a_close[a_close %in% t_start]
  } else {
    a_open <- integer(0); a_close <- integer(0)
  }

  keep <- logical(length(h_start))
  ti <- 0L; io <- 0L; ic <- 0L
  n_ao <- length(a_open); n_ac <- length(a_close)
  for (j in seq_along(h_start)) {
    pos <- h_start[j]
    # 三个指针都只前进：命中位置和标签位置都是升序的，所以整轮是线性的。
    while (ti < n_tag && t_start[ti + 1L] <= pos) ti <- ti + 1L
    while (io < n_ao && a_open[io + 1L]  <  pos) io <- io + 1L
    while (ic < n_ac && a_close[ic + 1L] <  pos) ic <- ic + 1L
    # ti = 最后一个起点不晚于 pos 的标签；它若还没结束，命中就在标签内部
    # （例如 href="volcano.png"），丢掉。
    inside_tag <- ti > 0L && t_end[ti] >= pos
    # io - ic 就是 <a> 深度；原来逐标签 max(0, depth±1) 夹到非负，
    # 等价于这里用 io <= ic 判"深度为 0"。
    keep[j] <- !inside_tag && io <= ic
  }

  sel <- which(keep)
  if (length(sel) == 0L) return(html)

  out <- character(2L * length(sel) + 1L)
  k <- 0L; prev <- 1L
  for (j in sel) {
    if (h_start[j] > prev) {
      k <- k + 1L; out[k] <- substr(html, prev, h_start[j] - 1L)
    }
    k <- k + 1L
    out[k] <- dsapp_file_link_html(substr(html, h_start[j], h_end[j]), input_id, title)
    prev <- h_end[j] + 1L
  }
  if (prev <= n_html) { k <- k + 1L; out[k] <- substr(html, prev, n_html) }
  paste(out[seq_len(k)], collapse = "")
}

#' 流式正文的"尾巴"切片
#'
#' ★★ V15.11：`output$streaming` 每一拍都会重发一次这一格的 HTML，而正文是
#'    越长越长的 —— 整条发就是**长度的平方**（见 DSAPP_STREAM_BUDGET_B 那段
#'    的实测数字）。这里负责把"这一拍发哪一段"切出来：正文比窗口短就整条返回
#'    （调用方据此走**和以前完全一样**的老路），长了就只取末尾。
#'
#' @param txt   正文（`draft()`）
#' @param chars 窗口最多多少**字符**（字节预算换算成字符是调用方的事：
#'   同样 1000 字，一张表和一个段落渲染出来能差好几倍）
#' @return list(text = 要渲染的那一段, cut = 是否切掉了前文, chars = 这一段的字符数)
dsapp_stream_tail <- function(txt, chars) {
  n <- suppressWarnings(as.integer(nchar(txt)))
  chars <- suppressWarnings(as.integer(chars))
  if (is.na(n)) return(list(text = txt, cut = FALSE, chars = 0L))
  if (is.na(chars) || chars < 1L) chars <- 1L
  if (n <= chars) return(list(text = txt, cut = FALSE, chars = n))

  seg <- substr(txt, n - chars + 1L, n)
  # 行对齐：丢掉切出来的第一行（它多半是半行，半行的 Markdown 结构会变样）。
  # ⚠️ 切片里一个换行都没有（一整个大表格行、或者一段没有换行的长文）就原样
  #    留着 —— 宁可显示半行，也不要一个空窗口。
  nl <- regexpr("\n", seg, fixed = TRUE)
  if (nl > 0L && nl < nchar(seg)) seg <- substr(seg, nl + 1L, nchar(seg))
  list(text = seg, cut = TRUE, chars = nchar(seg))
}

#' 流式正文这一拍到底发不发（V15.13）
#'
#' ★★★ 这是「做任何操作都很卡」的根，**别把调用点改回无条件发送**。
#'
#' `output$streaming` 是个 renderUI：写一次 `draft()` 就把**整段已生成正文**
#' 重新渲染成一个 HTML 包发下去，Shiny 没有输出级 diff。而泵是 5 拍/秒，于是
#' 正文越长、每秒灌给浏览器的字节越多 —— 线上实测 **31.7 KB/s** 持续灌一条
#' 只能送 **3.65 KB/s** 的链路（超订 8 倍），发送队列永远排不空，用户点什么
#' 都排在积压后面。这就是那两句「频繁断联」+「做任何操作都很卡」。
#'
#' 所以这里不按"每拍多少字节"限（那条预算在正文短于窗口时根本不生效，见
#' R/config.R 里 DSAPP_STREAM_RATE_B 那段），按**每秒多少字节**限：先估这一拍
#' 要发多少字节（窗口最多渲染 DSAPP_STREAM_WIN_MAX 字），再算"最早什么时候
#' 能发下一拍"。
#'
#' ⚠️ **不发不等于丢字**：调用点在这一步**之前**就把新文本并进 `st$acc` 了，
#'    这里只决定"要不要把画面刷新一遍"。一轮结束时走的是 `output$history`
#'    （读库重渲染），和这一格没关系。最坏情况只是正文一顿一顿地出来。
#' ⚠️ 第一拍永远立刻发：新的一轮 `pub_at` 是 0（`%||% 0` 兜的），
#'    `now - 0` 远大于需要的间隔。
#' ⚠️ 判据是**估的字节**而不是字符数：同样 1000 字，一张表和一个段落渲染出来
#'    差好几倍（和 DSAPP_STREAM_BUDGET_B 同一条理由）。
#'
#' @param n_chars 已经生成的正文**字符数**（`nchar(st$acc)`，不是这一拍新加的）
#' @param pub_at  上一次真发出去的时刻（`as.numeric(Sys.time())`）；没发过给 0
#' @param now     现在（同上口径）
#' @return TRUE = 这一拍可以写 draft()
dsapp_stream_due <- function(n_chars, pub_at, now) {
  # ⚠️ 一律先压成长度 1：`nchar()` 给的是标量，但脏输入（NA / NULL / 负数 /
  #    长度 >1）必须都当 0 处理 —— 在 `if` 里拿长度 >1 的条件会直接抛错，
  #    而这里抛错的后果是**整个流式输出停住**，比"多发一拍"贵得多。
  n <- suppressWarnings(as.numeric(n_chars))
  if (!length(n) || is.na(n[1]) || n[1] < 0) n <- 0 else n <- n[1]
  est_b <- DSAPP_STREAM_BYTES_PER_CHAR * min(n, DSAPP_STREAM_WIN_MAX) +
    DSAPP_STREAM_OVERHEAD_B
  last <- suppressWarnings(as.numeric(pub_at))
  if (!length(last) || is.na(last[1]) || last[1] < 0) last <- 0 else last <- last[1]
  (now - last) * DSAPP_STREAM_RATE_B >= est_b
}

#' 历史要渲染**哪一段**消息（V15.11）
#'
#' 从最新一条往回数，边数边累加正文字符，超过 `budget` 就停；但无论如何
#' 至少渲染 `min_n` 条 —— 用户正在看的是最后那一轮，宁可这一包超一点，
#' 也不能让它从眼前消失（见 R/config.R 里 DSAPP_HIST_MIN_MSG 的说明）。
#'
#' @param chars  每条消息**要渲染出去的全部文字**的字符数。⚠️ V15.12 起调用
#'   方把思维链也算进来了（`nchar(content) + nchar(reasoning)`）—— 这个函数
#'   只认数字，加不加是调用方的事，但**漏掉的那部分照样会发出去**，预算就白
#'   定了（漏过两次：内联图片、思维链）。
#' @param extra  用户点了几次「显示更早的消息」（0 = 只用基础预算）
#' @return list(start=从第几条开始渲染, hidden=前面藏了几条, shown=渲染几条)
#'
#' 三条规则，从强到弱：
#'   ① 最后 DSAPP_HIST_FLOOR_MSG 条**永远**渲染 —— 用户正在看的这一轮，
#'      少了它页面看着就是"话没说完"（这一段里有工具气泡，所以不能只保底
#'      一两条：最后一条可能正好是个执行结果）。
#'   ② 倒数 min_n 条以内，只要累计不超过 hard 上限（预算的 hard_mult 倍）
#'      就接着往回收。**这条上限是防病态的**：连续几条几万字的回复，光靠
#'      ①/② 也能凑出几 MB —— 那正是这一版要修的东西。
#'   ③ 再往前的，只按预算收。
#'
#' ⚠️ extra 是**按预算**加的，不是"再加 15 条"：用户那些消息一条 2 万字、
#'    渲染出来 50 KB 上下，"15 条"就是 700 KB ≈ 14 秒 —— 一次点击就能把
#'    这一包顶回 pong 判据（10 秒）之上，等于点"看更多"点出一次黑屏。
#'    按预算加，每点一次多 100 KB 出头（≈2.5 秒）。
dsapp_hist_window <- function(chars, extra = 0L,
                              budget = DSAPP_HIST_BUDGET_C,
                              min_n = DSAPP_HIST_MIN_MSG,
                              hard_mult = DSAPP_HIST_HARD_MULT) {
  n <- length(chars)
  if (n == 0L) return(list(start = 1L, hidden = 0L, shown = 0L))
  chars <- suppressWarnings(as.numeric(chars))
  chars[is.na(chars) | chars < 0] <- 0
  extra <- suppressWarnings(as.integer(extra))
  if (is.na(extra) || extra < 0L) extra <- 0L
  budget <- suppressWarnings(as.numeric(budget))
  if (is.na(budget) || budget < 0) budget <- 0
  min_n <- max(1L, suppressWarnings(as.integer(min_n)))
  if (is.na(min_n)) min_n <- 1L
  budget <- budget * (1 + extra)             # 点一次 = 多一份预算
  hard <- budget * max(1, suppressWarnings(as.numeric(hard_mult)))
  if (is.na(hard)) hard <- budget

  used <- 0
  start <- n
  for (i in n:1) {
    depth <- n - i + 1L                      # 这条是倒数第几条
    tot <- used + chars[i]
    take <- depth <= DSAPP_HIST_FLOOR_MSG || # ①
            (depth <= min_n && tot <= hard) || # ②
            tot <= budget                      # ③
    if (!take) break
    used <- tot
    start <- i
  }
  list(start = as.integer(start),
       hidden = as.integer(start - 1L),
       shown = as.integer(n - start + 1L))
}

#' 渲染完整消息
#'
#' @return tagList，可直接放进 renderUI
dsapp_render_message <- function(content, message_id, executable = TRUE,
                                 file_names = NULL, file_input = NULL,
                                 file_title = "点击下载 %s",
                                 running_id = NULL, ran_ids = NULL,
                                 img_session = NULL, img_sid = NULL,
                                 img_cfg = NULL, alert = TRUE) {
  segs <- dsapp_split_segments(content)
  if (length(segs) == 0) return(NULL)

  # ★ V15.3 item 6：正文里的图片要能显示出来。
  #   给了 session 才走带图的渲染（`dsapp_md_chat_html`），没给就退回原来的
  #   `dsapp_md_html()` —— 邮件/导出那几条路没有会话，行为一个字不变。
  use_img <- !is.null(img_session)
  if (is.null(img_cfg)) img_cfg <- dsapp_config()

  items <- lapply(segs, function(s) {
    if (s$type == "text") {
      if (!nzchar(trimws(s$text))) return(NULL)
      # 转义 → commonmark → 链接协议白名单，三步的理由都在
      # dsapp_md_html() 上面（V11 起这段归它了，文件预览的 .md 分支要的
      # 是同一件事，各写一份迟早有一边忘了转义）。
      #
      # ★ V13.12 item 6：整段结果按 (正文, 产物名单, 点击目标) 缓存。
      #   产物名单也算进 key —— 它是会变的（新文件一落盘就该变成链接），
      #   漏掉它就会出现"文件明明生成了，正文里那几个名字还是点不动"。
      #
      # ⚠️★ V15.3 item 6：**sid 必须进 key**。带图的渲染会给每张图注册一个
      #    会话私有的 dataobj 地址，那个地址里带着**会话 token 和一次性
      #    nonce** —— 跨会话复用这条缓存，等于把 A 会话的地址发给了 B 会话，
      #    而 B 会话拿它去取是取不到的（症状：这个对话里图全裂）。
      #    同一条消息在同一个会话里重渲染（滚回去看）命中缓存，地址仍然有效。
      dsapp_memo("segtext",
                 digest::digest(list(s$text, file_names, file_input, file_title,
                                     if (use_img) img_sid else NULL),
                                algo = "xxhash64"),
                 function() {
                   html <- if (use_img)
                     dsapp_md_chat_html(s$text, img_session, img_sid, img_cfg)
                   else dsapp_md_html(s$text)
                   # ⚠️ 文件名链接必须排在 sanitize **之后**：它自己的
                   #    href="#" 过不了那道协议白名单，先加就会被自己人剥掉。
                   #    （dsapp_md_chat_html 内部已经消毒过了，这里接在它后面。）
                   HTML(dsapp_linkify_files(html, file_names, file_input, file_title))
                 })
    } else {
      dsapp_code_card(s, message_id, executable, running_id = running_id,
                      ran_ids = ran_ids, alert = alert)
    }
  })

  tagList(items)
}

#' 用户消息渲染
#'
#' ★ V13.12 item 11：这里**改成走 Markdown 了**。
#'
#' 用户原话：「对话框里用户发送的内容涉及 markdown 格式不能正常渲染，而是
#' 以富文本格式显示了，请修正」。
#'
#' ---- 为什么改（原来那条注释说的是反话）--------------------------------------
#'
#' 原来这里是一行 `tags$div(class = "dsapp-user-text", content)`，注释写着
#' "这里不用 commonmark —— 用户提问里的 # 和 * 是字面意思"。那个判断在
#' **用户自己随手打一句话**的场景下是成立的，但下面这几种消息也是用户消息：
#'
#'   · 「总结并生成报告」发出去的那一整段（带 ``` 围栏、`**加粗**`、
#'     编号列表）—— 见 prompts.R 的 dsapp_report_prompt；
#'   · 文献速递的关键词与要求；
#'   · 用户从别处粘进来的 Markdown（表格、代码、报告草稿）。
#'
#' 这些在气泡里全是**带标记字符的原文**：`**做了什么 / 数据是什么**` 连着
#' 星号一起显示，围栏 ``` 也照印。用户点一次「生成报告」，先看到的就是
#' 那么一屏东西。
#'
#' ---- 安全上没有放松 ---------------------------------------------------------
#'
#' 走的还是 dsapp_md_html()：**先 dsapp_escape 再 commonmark**，最后过一遍
#' 链接协议白名单。用户输入仍然是不可信输入，一个字都没少转义。
#' （htmltools 对裸字符串本来就会转义，所以旧写法也不是 XSS；这里换的是
#' "渲染不渲染"，不是"安不安全"。）
#'
#' ---- 两个刻意的选择 ---------------------------------------------------------
#'
#' ⚠️ 1. **不切代码块、不生成执行卡片**。助手气泡走的是 dsapp_render_message()，
#'       它会把 ``` 围栏变成带【确认执行】的活卡片。用户气泡**绝不能**走那条
#'       路：用户那句"帮我看看这段 ```rm -rf ...``` "会变成一颗他自己点一下
#'       就能跑的按钮。所以这里只用 dsapp_md_html()，围栏照常渲染成一段
#'       静态的 <pre><code>。
#'
#' ⚠️ 2. `hardbreaks = TRUE`。见 dsapp_md_hardbreaks()：用户敲的换行要留住，
#'       否则这次改动会顺手把"我以前打的换行"吃掉 —— 那是拿一个 bug 换另一个。
#'
#' ⚠️ 3. **围栏要先切出来**，不能整段丢给 dsapp_md_html()。这是本文件开头
#'       那段注释记的老坑：dsapp_md_html() 是"先转义、再 commonmark"，而
#'       commonmark 自己也会转义代码块里的 `<` 和 `&` —— 代码过一次
#'       commonmark 就成了**二次转义**：
#'
#'           ```\nx <- c(1,2)\n```  →  x &amp;lt;- c(1,2)
#'
#'       助手气泡躲过这一劫是因为它走 dsapp_split_segments() 把围栏分出去了。
#'       用户气泡现在也要走同一条路：文本段交给 Markdown，代码段自己转义一次。
dsapp_render_user_message <- function(content, img_session = NULL,
                                      img_sid = NULL, img_cfg = NULL) {
  if (is.null(content) || !nzchar(content)) return(NULL)

  # ★★ V15.10 item 2（性能）：整条用户气泡按 **(正文, 会话 sid)** 缓存。
  #
  #    2026-10-02 量出来的账（线上那个 45 条 / 203 KB 的会话，重画一遍
  #    历史 0.460 s）：
  #        assistant  16 条  135727 字符  0.122 s
  #        tool       14 条   20239 字符  0.012 s
  #        user       15 条   59665 字符  0.329 s  ← **71%**
  #    助手消息的正文段早就按 `segtext` 缓存了（本文件 1512 行），用户消息
  #    这一路却一条缓存都没有：重画一次历史，15 条用户消息就要把
  #    commonmark + 消毒 + 链接白名单整个再跑一遍（~0.045 s/条）。
  #
  #    ⚠️ 而用户消息是**全应用里最该缓存的东西**：落库之后内容永不再变，
  #       连"新文件落盘要变成链接"这种事都没有（用户气泡里不过滤产物名）。
  #       历史重画的触发源却一个都不少：产物名单每 3 秒轮询、hist_ver、
  #       msg_rev、agent 每变一次状态。每次都要白跑一遍这 0.33 s。
  #
  #    ⚠️★ sid 必须进 key，理由和 segtext 那条一字不差：带图的渲染会给
  #       每张图注册一个**会话私有**的 dataobj 地址（那里带着会话 token），
  #       跨会话复用这条缓存等于把 A 会话的地址发给 B 会话 —— 症状是
  #       这个对话里图全裂。同一个会话里重画（滚回去看）命中缓存，地址
  #       仍然有效。
  use_img <- !is.null(img_session)
  dsapp_memo("userbubble",
             digest::digest(list(content, if (use_img) img_sid else NULL),
                            algo = "xxhash64"),
             function() .dsapp_user_bubble(content, use_img, img_session,
                                           img_sid, img_cfg))
}

#' 用户气泡的实际渲染（外面套着 dsapp_render_user_message 的缓存）
#' @noRd
.dsapp_user_bubble <- function(content, use_img, img_session, img_sid, img_cfg) {
  segs <- dsapp_split_segments(content)
  if (length(segs) == 0) return(NULL)

  # ★ V15.3 item 6：用户消息里也可能有图 —— 从产物清单里复制的
  #   `![](figures/volcano.png)`、或者粘贴的一段带图片的相对路径 Markdown。
  #   同 dsapp_render_message()：给了 session 才走带图那条路。
  if (is.null(img_cfg)) img_cfg <- dsapp_config()

  items <- lapply(segs, function(s) {
    if (identical(s$type, "code")) {
      # ⚠️ 只是 <pre><code>，**不是** dsapp_code_card()。见上面第 1 条：
      #    用户气泡里绝不能出现能点的执行按钮。
      #
      # ⚠️ 必须用 HTML() 拼字符串，理由和 dsapp_code_card() 里那条一字不差
      #    （见本文件 297 行）：htmltools 会在 <pre> 内部插入换行和缩进，
      #    而 <pre> 里所有空白都是要显示的 —— 结果每段代码第一行凭空多出
      #    一个空行加 6 个空格。转义由我们自己做，**且只做一次**。
      return(tags$pre(class = "dsapp-user-pre",
                      HTML(paste0("<code>", dsapp_escape(s$code %||% ""),
                                  "</code>"))))
    }
    if (!nzchar(trimws(s$text %||% ""))) return(NULL)
    if (use_img) {
      HTML(dsapp_md_chat_html(s$text, img_session, img_sid, img_cfg,
                              hardbreaks = TRUE))
    } else {
      HTML(dsapp_md_html(s$text, hardbreaks = TRUE))
    }
  })

  tags$div(class = "dsapp-user-text", tagList(items))
}

# =============================================================================
# 执行过程卡片（V9 item 2 / 8）
# =============================================================================

#' 把 tool 消息的正文切成小节
#'
#' dsapp_agent_tool_text() 写出来的正文长这样：
#'
#'   【执行结果 · 任务 #12】
#'   状态：失败（程序自己报错退出）
#'   语言：R
#'   退出码：1
#'   耗时：12.4 秒
#'
#'   --- stderr（报错在这里，先读它）---
#'   Error in Read10X(...) : 找不到文件
#'
#'   --- stdout（末尾）---
#'   [1] 载入完成
#'
#'   --- 本次产出的文件 ---
#'   - volcano.png  1.2 MB
#'
#' 卡片要把它拆成"标题 / 元信息 / 报错 / 输出 / 产物"分别排版，而不是
#' 一整块等宽文本 —— 用户的原话是「任务系统定位只是一个记录运行日志的地方，
#' 请把执行过程详细地在言出法随页面展示」（V9 item 2）。一整块文本不是展示，
#' 是转储。
#'
#' @return list(head=, meta=字符向量, secs=以标签为名的 list, note=)
#' @noRd
dsapp_tool_sections <- function(content) {
  txt <- content %||% ""
  lines <- strsplit(txt, "\n", fixed = TRUE)[[1]]
  if (!length(lines)) return(list(head = "", meta = character(0), secs = list(), note = ""))

  head <- lines[[1]]
  rest <- lines[-1]

  # 小节分隔行固定是 `--- 标签 ---`。标签里带着中文括号与 `**`，所以这里
  # 只认"以 `--- ` 开头、以 `---` 结尾"这个形状，中间一律当标签。
  #
  # ★ V15.5 item 12：结尾那个空格是**可选的**。
  #   原来写的是 `^--- .+ ---$`（空格必需），而正文里有两种形态一直并存：
  #     `--- stdout（末尾）---`      ← 有空格，能切开
  #     `--- 产出有问题（平台体检，…）---` ← **没有**空格（标签自己以 `）` 收尾，
  #                                          写的时候自然就没再加一个）
  #   后一种切不开，后果是**整条工具消息被解析成一整块正文**：那一节的
  #   `dsapp_sec_get(secs, "产出有问题")` 返回 NULL，卡片上那条红着脸的
  #   「产出有问题」**从来没渲染过**（V13.12 起就是这样，编译器不会报，
  #   自检也没人验到渲染那一层）。放宽一个 ` ?` 就把两种都收进来。
  #   ⚠️ 代价：正文里真出现一行 `--- xxx ---`（模型 print 出来的分隔线）时
  #      仍然会被当成小节 —— 这件事放宽前就存在，不是这次引入的。
  is_sep <- grepl("^--- .+ ?---$", rest)
  idx <- which(is_sep)

  meta_end <- if (length(idx)) idx[1] - 1L else length(rest)
  meta <- rest[seq_len(max(0L, meta_end))]
  meta <- meta[nzchar(trimws(meta))]

  secs <- list()
  if (length(idx)) {
    for (k in seq_along(idx)) {
      # ⚠️ 收尾那个 `---` 前面的空格同样要**可选**，和上面 is_sep 对齐：
      #    不一起放宽的话，`--- 产出有问题（…）---` 切出来的标签会拖着
      #    一串 `---`，界面上那一节的标题就变成「产出有问题（…）---」。
      #    （前缀查找（dsapp_sec_get）不受影响 —— 它在乎的是开头。）
      lab <- sub("^--- ", "", sub(" ?---$", "", rest[idx[k]]))
      from <- idx[k] + 1L
      to <- if (k < length(idx)) idx[k + 1L] - 1L else length(rest)
      body <- if (to >= from) rest[from:to] else character(0)
      secs[[lab]] <- paste(body, collapse = "\n")
    }
  }

  # 备注/平台提示这类收尾行落在最后一个小节里时会被整段吞掉，这里不额外
  # 拆 —— 它们本来就该跟着那个小节显示，硬拆反而会丢上下文。

  list(head = sub("^【", "", sub("】$", "", head)), meta = meta, secs = secs, note = "")
}

#' 按标签前缀取一个小节（标签带着解释性后缀，前缀才是稳定的键）
#' @noRd
dsapp_sec_get <- function(secs, prefix) {
  if (!length(secs)) return(NULL)
  hit <- names(secs)[startsWith(names(secs), prefix)]
  if (!length(hit)) return(NULL)
  secs[[hit[1]]]
}

#' 从 tool 消息正文里提取"这次产出了哪些文件"
#' @noRd
dsapp_sec_files <- function(secs) {
  txt <- dsapp_sec_get(secs, "本次产出的文件")
  if (is.null(txt) || !nzchar(trimws(txt))) return(character(0))
  rows <- trimws(strsplit(txt, "\n", fixed = TRUE)[[1]])
  rows <- rows[startsWith(rows, "- ")]
  if (!length(rows)) return(character(0))
  # 每行是 "- 名字  1.2 MB"，名字里可以有空格，所以从**行尾**剥体积。
  # 体积那一段固定以 B/KB/MB/GB 结尾，且和名字之间至少两个空格。
  out <- sub("\\s{2,}[0-9.]+\\s?(B|KB|MB|GB|TB)$", "", sub("^- ", "", rows))
  out[nzchar(out)]
}

#' 执行产物的可点列表
#'
#' 每个名字点一下先看预览（和文件页、对话底部那张产物卡片走**同一个**
#' input）—— 不另开一条下载路径：多一条路径就多一处要跟着 dsapp_ws_path
#' 的校验规则一起改的地方。
#' @noRd
dsapp_run_files_ui <- function(files, preview_input) {
  if (!length(files)) return(NULL)

  # ★ V15.5 item 3：按"给人看 / 给机器看"分两组显示。判据是 executor.R 的
  #   dsapp_artifact_is_human()，和 agent.R 回喂正文里那份清单**同一条** ——
  #   两边说法不一致时，用户看到的和模型看到的对不上，谁也不知道信哪个。
  #
  #   用户原话：「整理完之后居然返给用户的是一份 json 文件，完全没有人类
  #   可读性」。他那次看到的就是这一排：卡片写着"产出 N 个文件"，点开是
  #   一个 json —— 界面把中间产物和交付物摆成了同一种东西，用户当然会
  #   以为那就是成果。
  #
  # ⚠️ 中间产物**不删**，只降级成一行灰字、**仍然可点**。删掉会带来一个更
  #    难解释的问题："文件页里明明有，对话里却找不到入口"；而且 json 里可能
  #    真有他要的那个数字。这里要改的是**它被叫什么**，不是它存不存在。
  human <- dsapp_artifact_is_human(files)

  chip <- function(nm, muted = FALSE) {
    cls <- paste(c("dsapp-run-file", if (muted) "text-muted"), collapse = " ")
    if (is.null(preview_input)) return(tags$span(class = cls, nm))
    tags$a(class = paste(cls, "dsapp-file-link"), href = "#",
           title = sprintf("点击预览 %s", nm),
           onclick = dsapp_fire(preview_input, nm), nm)
  }
  group <- function(keep, label, muted) {
    if (!any(keep)) return(NULL)
    div(class = "dsapp-run-files",
      tags$span(class = paste("dsapp-run-files-h", if (muted) "text-muted"),
                label),
      lapply(files[keep], chip, muted = muted))
  }

  tagList(
    group(human, sprintf("产出 %d 个文件", sum(human)), FALSE),
    # ⚠️ 一个交付物都没有时不能说"另有 N 个"——"另有"是接在上一句后面的，
    #    单独出现读起来像漏了一行。
    group(!human,
          if (any(human))
            sprintf("另有 %d 个中间文件（过程产物，不是给用户看的结论）",
                    sum(!human))
          else
            sprintf("%d 个中间文件（过程产物，不是给用户看的结论）",
                    sum(!human)),
          TRUE)
  )
}

#' 产物体检结论那张**红着脸**的卡片
#'
#' ★ V13.12 item 8 起就有这一段（"这些文件里没有数据，不能当作结果交出去"），
#' V15.5 item 12 起它装**两类**问题（判据见 executor.R 的 dsapp_bad_artifacts）：
#'   ① 文件里没有数据（老问题）
#'   ② 图里的中文画成了方框（item 12）
#'
#' ⚠️ 标题和下面那段解释必须跟着**内容**走。原来两句都是写死的"没有数据 / 上游
#'    接口没返回数据"，一张方块图会被解释成参数问题 —— 用户照着这句话去查
#'    筛选条件，永远查不出真正的原因（字体），比不显示更坏。
#' ⚠️ 抽成独立函数是为了**能被断言**（它是"写进去了但页面上看不见"的重灾区：
#'    V13.12 起这一节因为小节分隔行写成了 `）---`，dsapp_tool_sections 切不开，
#'    从来没渲染过）。现在 selftest 直接喂两段文字进来验标题分叉。
#' @noRd
dsapp_run_badart_ui <- function(bad_body) {
  if (is.null(bad_body) || !nzchar(trimws(bad_body))) return(NULL)
  # 判据和 dsapp_font_glyph_check() 写出来的那句话对齐（"方框" / "missing
  # from font"），任一个命中就按字体那一类说 —— 正反两个方向都不会误判：
  # 空表那条文案里没有这两个词。
  is_font <- grepl("方框", bad_body, fixed = TRUE) ||
             grepl("missing from font", bad_body, fixed = TRUE)
  div(class = "dsapp-run-badart",
    div(class = "dsapp-run-badart-h",
      icon("triangle-exclamation"),
      if (is_font) " 图里有字没画出来（显示成方框）"
      else " 这次产出的文件里没有数据"),
    tags$pre(class = "dsapp-run-pre dsapp-run-badart-pre",
             dsapp_escape(trimws(bad_body))),
    if (is_font) div(class = "dsapp-run-badart-note",
      "图生成了、也存下来了，但图里的中文变成了一个个空心方框 —— ",
      "画图时用的字体没有中文字形（matplotlib 不会自动换字体）。",
      "由 AI 自己改字体、重新出图，不用你做什么。")
    else div(class = "dsapp-run-badart-note",
      "文件已经生成、也能打开，但里面只有表头。",
      "上游接口对这套参数没返回数据，或者脚本的筛选条件把数据全滤掉了 —— ",
      "两种都由 AI 自己查、自己改，不用你做什么。")
  )
}

#' 一行的元信息（标题 · 语言 · 目标 · 耗时 · 退出码 · 完成时间）
#'
#' ⚠️ 全部来自**任务行**，不解析正文里那几行。正文是给模型看的，卡片是给
#'    人看的，两者的措辞会各自演化；从正文里反解数字的话，改一处文案
#'    卡片上的数字就会静默消失。正文只在没有任务行时兜底。
#' @noRd
dsapp_run_meta <- function(t) {
  if (is.null(t) || !nrow(t)) return(NULL)
  get1 <- function(nm) {
    v <- t[[nm]]
    if (is.null(v) || !length(v)) return(NA)
    v[[1]]
  }
  chr <- function(x) { x <- as.character(x %||% ""); if (is.na(x)) "" else x }

  bits <- c(
    chr(get1("title")),
    chr(get1("lang")),
    chr(get1("target")),
    if (!is.na(get1("exit_code"))) sprintf("退出码 %d", as.integer(get1("exit_code"))),
    {
      st <- chr(get1("started_at")); fi <- chr(get1("finished_at"))
      if (nzchar(st) && nzchar(fi)) {
        secs <- dsapp_duration_between(st, fi)
        if (!is.na(secs) && secs >= 0) sprintf("耗时 %s", dsapp_fmt_duration(secs))
      }
    },
    if (nzchar(chr(get1("finished_at"))))
      sprintf("完成于 %s", dsapp_fmt_time(chr(get1("finished_at"))))
  )
  bits <- bits[!is.na(bits) & nzchar(bits)]
  if (!length(bits)) return(NULL)
  div(class = "dsapp-run-meta", paste(bits, collapse = " · "))
}

#' 让模型接着看的入口（V9 item 8）
#'
#' 用户的原话是「失败的任务需要在言出法随界面给出反馈，可以参考 claude 的
#' 反馈方式」。Claude 的反馈不只是"红了"，而是**报错原文 + 下一步能做什么**。
#' 只标红不给出路的话，用户看到一句 "Error in ..." 之后仍然不知道该干什么。
#'
#' ⚠️ 按钮只是把话**填进输入框**，不直接发。直接发的话会绕过用户对
#'    「要花一次 token、要说什么」的决定权 —— 而这段报错可能很长，
#'    用户未必想原样发出去。
#' @noRd
dsapp_run_fix_btn <- function(t, err, prefill_input) {
  if (is.null(prefill_input)) return(NULL)
  tid <- if (is.null(t) || !nrow(t)) "?" else as.character(t$id[1])
  err <- err %||% ""
  # 只带末尾 1500 字符：报错的重心在**最后几行**（真正的错误 + 调用栈最内层），
  # 前面几千行通常是正常日志。整段塞进输入框的话，用户还得自己删。
  if (nchar(err) > 1500) err <- paste0("（前文已省略）\n", substr(err, nchar(err) - 1499L, nchar(err)))
  msg <- sprintf(
    "任务 #%s 执行失败了。报错原文：\n\n```\n%s\n```\n\n请帮我定位原因，并给出修好的代码。",
    tid, trimws(err))
  tags$button(
    class = "dsapp-btn dsapp-run-fix", type = "button",
    # ★ V15.4 item 2 前半：补一句 title。上面写着"只是填进输入框、不直接发"
    #   是刻意的（见头注），但**按钮上没写** —— 用户点完只看到输入框里多了
    #   一屏字，很容易读成"点了没反应"。旁边"重试这一步"（真跑）和它并排
    #   之后，这个区别更需要说出来。
    title = "把这段报错填进下面的输入框，你确认后再发（不会替你发出去）",
    onclick = dsapp_fire(prefill_input, msg),
    icon("wand-magic-sparkles"), " 让 AI 分析这个报错"
  )
}

#' 「重新发送」：把这一条**填回输入框**，不替用户发出去
#'
#' ★★ Test_V15.4 item 4。用户原话：
#'    「重新发送的话应该直接返回到用户的输入框中」。
#'
#' 全仓在这之前**没有**"重新发送"这个功能（`R/` + `www/app.js` 里
#' `重发/resend/retry` 全是注释和提示文案）。但机制是现成的：
#' `dsapp_run_fix_btn()` 那颗「让 AI 分析这个报错」就是同一条路 ——
#' 把话填进输入框、**不**直接发，走 `dsapp_fire(prefill_input, msg)`。
#'
#' ⚠️ **复用同一个 input id，不要新开一条通道。** 接收端
#'    （`R/mod_chat.R` 的 `observeEvent(input$prefill_input, ...)`）里有一段
#'    "框里有内容就追加、同一段不重复追加"的保护，那是防"用户打了一半的
#'    中文被无声抹掉"的（V13.7 item 4）。新开一条通道就得把那段保护再实现
#'    一遍，而漏掉它的症状是**用户正在打的字消失**，不报错。
#'    框里有草稿时追加、用户自己删 —— 那比丢字好。
#'
#' @param prefill_input 输入框那条通道的 input id；NULL 时按钮不出现
#'   （模块挂载点没给这个参数时不该凭空冒出一颗点了没反应的按钮）。
#' @param text 要填回去的原文。
dsapp_resend_btn <- function(prefill_input, text,
                             label = "重新发送", title = NULL) {
  if (is.null(prefill_input)) return(NULL)
  txt <- as.character(text %||% "")[1] %||% ""
  if (is.na(txt) || !nzchar(trimws(txt))) return(NULL)
  tags$button(
    class = "dsapp-btn dsapp-resend", type = "button",
    title = title %||% "把这一条填回输入框，改完再发",
    onclick = dsapp_fire(prefill_input, txt),
    icon("rotate-right"), " ", label)
}

#' 失败卡片上的「坏在哪」：一句**人话**（★ V15.4 item 2 前半）
#'
#' 用户原话（2026-09-29）：
#'   「你看下最新的"绘制国旗"，任务，报错了，但是却并没有告诉用户做操作和选择」。
#'
#' 那一次任务 #132 是**平台判定的"模型自己代码写错了"**、自动修开着，所以走的
#' 是下面那条 `quiet_fail` 静默分支 —— 整个卡片对用户说的话只有一行：
#'
#'     这一段没跑通，AI 已经在自动重试了 —— 你不用做什么。
#'
#' 这句话**既没说坏在哪，也没有任何可点的东西**。用户看到的是一个红着的
#' 「失败」徽标，一句"你不用做什么"，然后就是不知道还要不要等、要不要
#' 说句话踢一脚 —— 那轮对话里他连着打了两个「继续」和一个「制作完了吗」，
#' 就是这个状态。本函数补上前半句：**坏在哪**。
#'
#' ⚠️ 刻意**不**在这里重新判一遍失败类型。判据只有 `dsapp_env_failure()`
#'    一处（见下面 dsapp_run_card 里那段说明），这里只负责把它的结论
#'    （`env$label`）和报错正文里最有信息量的那一行拼成一句话。
#'
#' ⚠️ 报错的**重心在最后几行**（真正的错误在最内层），前面几千行通常是
#'    正常日志 —— 和 `dsapp_run_fix_btn()` 只带末尾 1500 字符是同一个道理。
#'    但也不能无脑取最后一行：R 的 `Execution halted`、`Warning message:` 这类
#'    是**收尾噪音**，它出现在最后恰恰是因为它不重要。
#'
#' @return 一句话（字符串）；实在拼不出来时返回 NULL（调用方不渲染）。
#' @noRd
dsapp_fail_plain <- function(env, err) {
  lab <- as.character(env$label %||% "")[1] %||% ""
  if (is.na(lab)) lab <- ""

  tail_line <- ""
  err <- err %||% ""
  if (nzchar(err)) {
    ls <- trimws(strsplit(err, "\n", fixed = TRUE)[[1]])
    ls <- ls[nzchar(ls)]
    # 从后往前找第一行"不是收尾噪音"的。不要把这份名单写长 —— 每加一条都是
    # 在替将来某个解释器做决定，而漏掉一条的后果只是多显示一行收尾噪音。
    noise <- "^(Execution halted|Warning message|In addition|\\}|\\]|Command exited)"
    for (k in rev(seq_along(ls))) {
      if (!grepl(noise, ls[k])) { tail_line <- ls[k]; break }
    }
    if (nchar(tail_line) > 160L) tail_line <- paste0(substr(tail_line, 1, 159), "…")
  }

  if (nzchar(lab) && nzchar(tail_line)) return(sprintf("%s —— %s", lab, tail_line))
  if (nzchar(lab))                     return(lab)
  if (nzchar(tail_line))               return(tail_line)
  NULL
}

#' 失败卡片上的「重试这一步」（★ V15.4 item 2 前半）
#'
#' 用户要的"操作和选择"里，**这一颗是真能跑的那颗**：拿当时那次任务留在库里的
#' 代码，走和对话页手动执行完全相同的路再跑一遍（`engine$start()` 里那道静态
#' 扫描照样过，结果照样写回这条对话）。
#'
#' 为什么不是"把代码填回输入框让用户自己点运行"：失败的那一段代码在**上面**
#' 那条助手消息里，用户得先找到它、再找那颗 ▶ —— 而那正是他说"没有告诉我
#' 做操作"的地方。
#'
#' ⚠️ 它和 `dsapp_run_fix_btn()`（把报错填回输入框、**不**直接发）是两个不同
#'    的东西，别合并：那一颗要花一次 token、要用户对"发什么"有决定权；
#'    这一颗只是把**已经跑过的那段代码**再跑一遍，不经过模型、不花钱。
#'
#' @param t 任务行（要用它的 id 回库取代码）。
#' @param retry_input 重试那条通道的 Shiny input id；NULL 时按钮不出现。
#' @noRd
dsapp_retry_btn <- function(t, retry_input) {
  if (is.null(retry_input)) return(NULL)
  tid <- if (is.null(t) || !nrow(t)) NA_integer_
         else suppressWarnings(as.integer(t$id[1]))
  if (is.na(tid)) return(NULL)
  tags$button(
    class = "dsapp-btn dsapp-run-retry", type = "button",
    title = "用当时那段代码再跑一遍（不经过模型，结果照旧写进这个对话）",
    onclick = dsapp_fire(retry_input, tid),
    icon("rotate-right"), " 重试这一步"
  )
}

#' 执行结果卡片（V9 item 2 / 8）
#'
#' 取代原来那个"首行标题 + 一整块 <pre>"的渲染。
#'
#' 版式（失败时）：
#'   ✗ 执行结果 · 任务 #12                    [失败]
#'   单细胞聚类_降维分析 · R · 服务器 · 耗时 12.4 秒 · 退出码 1 · 完成于 …
#'   ┌ 报错 ─────────────────────────────────┐
#'   │ Error in Read10X(...) : 找不到文件      │
#'   └───────────────────────────────────────┘
#'   这个任务没有跑通。 [让 AI 分析这个报错]
#'   ▸ 完整输出（还有 128 行）
#'   产出 3 个文件：volcano.png  markers.csv  ...
#'   到任务页查看完整日志 →
#'
#' @param t      db_tasks_meta() / db_task_get() 的单行；NULL 时退化成纯文本
#' @param files  这次产出的文件名（可点预览）
#' @param preview_input 预览用的 Shiny input id；NULL 则不可点
#' @param prefill_input 把报错填回输入框用的 input id；NULL 则该按钮不出现
#' @param retry_input 「重试这一步」那条通道的 input id（★ V15.4 item 2 前半）；
#'   NULL 则那颗按钮不出现
#' @param autofix 「出错自动修」开着吗（V13.10 item 4）
#'
#' ★ V13.10 item 4：`autofix = TRUE` 且这次失败是**代码自己的锅**（syntax /
#'   code_bug，见 envfix.R 的 self_fix）时，这张卡不再摆出"等你来处理"的
#'   架势：报错收进折叠块、那颗「让 AI 分析这个报错」按钮不出现，只留一行
#'   灰字说清"已经自动重试了"。
#'
#'   ⚠️ 是**收起来**，不是删掉。用户原话是"不用记录和提示信息"，但历史卡片
#'      是**已经发生过的事**的记录，把它抹干净会变成另一种撒谎：任务明明
#'      失败过、产出是空的，页面却什么都不说，回头对不上账。折叠起来既
#'      不打扰，又翻得到。
#' @noRd
dsapp_run_card <- function(t, content = "", files = character(0),
                           preview_input = NULL, prefill_input = NULL,
                           retry_input = NULL, autofix = FALSE) {
  parts <- dsapp_tool_sections(content)
  secs  <- parts$secs

  status <- ""
  if (!is.null(t) && nrow(t)) {
    v <- as.character(t$status[1] %||% "")
    status <- if (is.na(v)) "" else v
  }
  running <- identical(status, "running")
  failed  <- nzchar(status) && !status %in% c("success", "running")

  err_body <- dsapp_sec_get(secs, "stderr")
  out_body <- dsapp_sec_get(secs, "stdout")
  warn_body <- dsapp_sec_get(secs, "平台提示")
  # ★ V13.12 item 8：产物体检的结论（"这几个文件里没有数据"）。
  #   和下面 warn_body 那段一样，**不**跟 item 4 一起收起来 —— 它不是
  #   "运行过程中的警告"，而是"这一屏的结论底下没有数据"。用户报的就是
  #   这个（生成出来的文件只有表头），收起来等于把问题本身藏了。
  bad_body <- dsapp_sec_get(secs, "产出有问题")

  # V11 item 8：这段报错是不是环境问题。
  #
  # ⚠️ 重新判一次，**不去解析**回喂里那段「平台判定」的文字。那段是写给模型
  #    的（里面有"你自己就能修""不要转手给用户"这种对着模型说的话），把它
  #    摊在界面上，用户看到的是别人家的信；而从自己的输出里再抠出标签，等于
  #    把"渲染"和"措辞"焊死在一起 —— 上面那句话哪天改一个字，这里就跟着坏，
  #    而且不报错（抠不到就是空标签）。判据只有一处：dsapp_env_failure()。
  env <- tryCatch(dsapp_env_failure(stderr = err_body, status = status),
                  error = function(e) list(is_env = FALSE))

  # ★ V13.10 item 4：AI 自己造的错（语法/变量名/类型），而且自动修开着 ——
  #   这张卡就**不该问用户任何事**。用户原话：「语法错误不要交由用户解决，
  #   请自行处理，甚至不用记录和提示信息」。
  #
  #   ⚠️ 判据用 dsapp_env_self_fix() 而不是只看 kind：那个函数就是"该谁修"
  #      的唯一定义处，将来加规则不用回来改这里。autofix 关着的时候它是
  #      FALSE —— 用户明确说了是"我开启出错自动修之后"才这样，关着还硬要
  #      装作没看见，就变成没人管了。
  quiet_fail <- isTRUE(autofix) && dsapp_env_self_fix(env)

  err_body <- if (is.null(err_body)) "" else trimws(err_body)
  out_body <- if (is.null(out_body)) "" else trimws(out_body)
  # 平台没给 stderr 但任务确实失败了 —— 空着的报错区比没有更让人困惑，
  # 这里如实说一句，而不是画一个空框。
  if (failed && !nzchar(err_body)) {
    err_body <- "平台没有拿到任何报错输出（进程可能被系统直接杀掉，或解释器没起来）。"
  }

  # 正文里"空"是字面量「（空）」（agent.R 的 clip 写的），别把它当报错显示
  if (identical(err_body, "（空）")) err_body <- ""
  if (identical(out_body, "（空）")) out_body <- ""

  # ★ V13.12 item 4：stderr 里绝大多数行是**警告**，不是报错。
  #
  # 用户原话：「分析过程中的 warring 和报错没有必要返回给用户」。
  # R 把 warning() 全写进 stderr，和 stop() 同一个流 —— 于是"任务成功、
  # 结果完全正确、只打了两行警告"在界面上是一屏红字加一颗「让 AI 分析这个
  # 报错」的按钮。用户看到的是"失败了"，而它根本没失败。
  #
  # ⚠️ 判据在 envfix.R 的 dsapp_stderr_split()，这里只负责"分开之后怎么摆"。
  #    不在这里写正则：分类规则和"这句话该谁看"是一件事，散成两处必然对不上。
  #
  # ⚠️ `failed` 要传进去。失败时那个函数有一道兜底：剥完只剩警告就把原文
  #    整个还回来 —— 宁可多显示几行，也不能出现"任务失败、界面一个字没有"。
  sp <- tryCatch(dsapp_stderr_split(err_body, failed = failed),
                 error = function(e) list(keep = err_body, noise = "",
                                          n_noise = 0L))
  err_keep  <- if (is.null(sp$keep)) "" else trimws(sp$keep)
  err_noise <- if (is.null(sp$noise)) "" else trimws(sp$noise)
  n_noise   <- as.integer(sp$n_noise %||% 0L)

  # 「被停掉的」不是一个待修的 bug（V9 item 8）。中止会把原因写进 stderr
  # （app.R 的 e$abort），于是它和真报错长得一模一样 —— 而这两件事该说的话
  # 完全不同：一个是"这段代码有问题，让我看看"，另一个是"你自己停的，
  # 没跑完" 配一个「让 AI 分析这个报错」按钮只会让人以为哪里出错了。
  stopped <- failed &&
    grepl("已手动停止|已被中止|被中断|对话已删除|应用重启|页面关闭", err_body)

  # ★ V15.4 item 2 前半：失败时那句"坏在哪"（NULL = 拼不出来，不渲染）。
  #   ⚠️ 用 err_keep 而不是 err_body：err_body 里混着 R 的警告，而警告不是
  #      失败的原因 —— 拿它当"坏在哪"的答案会把用户带偏（见上面
  #      dsapp_stderr_split 那段）。被停掉的那一类也不说：那不是"坏"，
  #      原因上面那行已经写清楚了。
  plain_fail <- if (failed && !stopped) dsapp_fail_plain(env, err_keep) else NULL

  # ★ V15.4 item 2 前半：两处提示行共用。先算一次 —— 后半句「一直没动静的话，
  #   可以点它再跑一遍」是**指着这颗按钮**说的，按钮不在（模块没给挂载点）
  #   就一个字都不能留，否则是一句指着空气的话。
  retry_btn <- if (failed && !stopped) dsapp_retry_btn(t, retry_input) else NULL

  head_txt <- if (nzchar(parts$head)) parts$head
              else if (!is.null(t) && nrow(t)) sprintf("执行结果 · 任务 #%s", t$id[1])
              else "执行结果"

  # 输出很长时折起来。判据是行数不是字符数：用户翻的是行，不是字节。
  n_out <- if (nzchar(out_body)) length(strsplit(out_body, "\n", fixed = TRUE)[[1]]) else 0L
  out_open <- n_out > 0 && n_out <= 12L

  tagList(
    div(class = paste0("dsapp-run",
                       if (failed) " dsapp-run-err" else if (running) " dsapp-run-live" else ""),
      div(class = "dsapp-run-head",
        if (running) tags$span(class = "spinner-border spinner-border-sm")
        else icon(if (failed) "circle-xmark" else "circle-check"),
        tags$span(class = "dsapp-run-title", head_txt),
        if (nzchar(status)) dsapp_status_badge(status)
      ),
      dsapp_run_meta(t),

      # ★ 自修类失败（quiet_fail）：报错**收进折叠块**，不占版面也不晃眼。
      #   ⚠️ 仍然留着 —— 见上面 dsapp_run_card 的参数注释，"抹干净"是另一种
      #      撒谎：任务失败过、产出是空的，页面却一个字不说，回头对不上账。
      #   ⚠️ V13.12 item 4：折叠块里放 `err_body`（含警告）而不是 `err_keep`。
      #      这一块是"翻旧账"用的，用户点开就是要看当时到底打了什么。
      if (nzchar(err_body) && quiet_fail) tags$details(class = "dsapp-run-errfold",
        tags$summary("这一轮的报错（AI 已接手，不用你处理）"),
        tags$pre(class = "dsapp-run-pre", dsapp_escape(err_body))
      ),

      # ★ V13.12 item 4：**只有真报错**才配得上这个红框。
      #   原来判的是 `nzchar(err_body)` —— 而 err_body 里混着 R 的警告，
      #   于是"成功但有两行 warning"和"真的挂了"长得一模一样。
      if (nzchar(err_keep) && !quiet_fail) div(class = "dsapp-run-errbox",
        div(class = "dsapp-run-errbox-h", icon("triangle-exclamation"), " 报错"),
        tags$pre(class = "dsapp-run-pre", dsapp_escape(err_keep))
      ),

      # ★ V13.12 item 4：警告**单独一处、折叠起来、不叫「报错」**。
      #
      #   为什么不是直接删掉：R 的警告有时候是**真信号**（"NAs introduced by
      #   coercion" 常常能解释一个看着不对的结果），用户排查时翻得到才有用。
      #   而且任务成功时它本来也不该占版面 —— 折起来默认不开，最省事。
      #
      #   ⚠️ 措辞里不能出现"报错""失败"。这一段和上面那个红框是**两件事**，
      #      共用一套说法的话，用户看到"运行过程中的报错"照样以为任务挂了。
      if (nzchar(err_noise)) tags$details(class = "dsapp-run-warnfold",
        tags$summary(sprintf("运行过程中的 %d 条警告（不影响结果）",
                             if (n_noise > 0L) n_noise else 1L)),
        tags$pre(class = "dsapp-run-pre", dsapp_escape(err_noise))
      ),

      if (failed && stopped) div(class = "dsapp-run-hint dsapp-run-hint-muted",
        "这个任务是被停掉的，没有跑完 —— 上面的「报错」是停止的原因，不是代码的问题。"
      ),

      # V11 item 8：环境问题单独说一句。
      #
      # 用户的原话是「因为环境配置等原因导致任务失败应该让AI自动调试，只有思路
      # 选择等场景需要用户做对应的反馈」—— 那就得**在界面上**把这两类分开。
      # 不分的话，缺一个包和一列名字写错长得一模一样（都是一屏红字加一个
      # 「让 AI 分析这个报错」的按钮），用户只能自己猜这次该不该他动手。
      # ⚠️ `!quiet_fail`：自动修开着时，自修类连"你不用做什么"这句都不说
      #    （dsapp_env_user_note 返回空串），框还在的话就成了一个空壳子。
      if (failed && !stopped && isTRUE(env$is_env) && !quiet_fail) div(class = "dsapp-run-env",
        div(class = "dsapp-run-env-h",
          icon("screwdriver-wrench"), " 环境问题",
          if (nzchar(env$label %||% "")) tags$span(class = "dsapp-run-env-tag",
                                                   env$label)
        ),
        div(class = "dsapp-run-env-note", dsapp_env_user_note(env, autofix = autofix))
      ),

      # ★ quiet_fail：不再是"等你点一下"的红字提示，换成一行灰字。
      #   用户原话是"不要交由用户解决" —— 那就**不能**在下面挂一颗
      #   「让 AI 分析这个报错」的按钮：那颗按钮的存在本身就是在说
      #   "这件事归你管"。
      #
      # ★ V15.4 item 2 前半：这一支原来**只有**上面那半句。用户看完成品
      #   （任务 #132，见 dsapp_fail_plain 的头注）给的反馈是"报错了，
      #   但是却并没有告诉用户做操作和选择"。补两样，都是**陈述**不是派活：
      #     · dsapp_fail_plain()  —— 坏在哪（一句人话）；
      #     · 「重试这一步」        —— 唯一的"选择"。它**不**推翻上面那条
      #       用户要求：静默分支的默认动作仍然是"什么都不用做"，
      #       这颗按钮是"AI 那边没动静时你自己也能推一把"的出口。
      #   ⚠️ 那句「AI 已经在自动重试了」是**卡片写下时**的判断，而这个
      #      分支的卡片是历史消息、不会自己更新 —— 循环停了、或者这个会话
      #      根本没有在跑（手动模式）时它照样这么写。正因为如此才必须有
      #      那颗按钮：一句自己没法兑现的承诺，用户手上得有个替代动作。
      if (failed && !stopped && quiet_fail) div(class = "dsapp-run-hint dsapp-run-hint-muted",
        div(class = "dsapp-run-hint-line",
          icon("rotate"), " 这一段没跑通，AI 已经在自动重试了 —— 你不用做什么。"),
        if (!is.null(plain_fail))
          div(class = "dsapp-run-plain", plain_fail),
        if (!is.null(retry_btn)) div(class = "dsapp-run-ops",
          retry_btn,
          span(class = "dsapp-run-ops-note", "一直没动静的话，可以点它再跑一遍。"))
      ),

      if (failed && !stopped && !quiet_fail) div(class = "dsapp-run-hint",
        div(class = "dsapp-run-hint-line",
          "这个任务没有跑通。上面是它输出的报错原文。你可以："),
        if (!is.null(plain_fail))
          div(class = "dsapp-run-plain", plain_fail),
        if (!is.null(retry_btn) || !is.null(prefill_input)) div(class = "dsapp-run-ops",
          retry_btn,
          dsapp_run_fix_btn(t, err_body, prefill_input),
          # ⚠️ 这句话只在**两颗都在**时才说 —— 说的是它俩的区别，
          #    少一颗就成了指着空气说话。
          if (!is.null(retry_btn) && !is.null(prefill_input))
            span(class = "dsapp-run-ops-note",
                 "「重试」只是把那段代码再跑一遍；要让 AI 改代码，用右边那颗。"))
      ),

      if (nzchar(out_body)) tags$details(class = "dsapp-run-out", open = if (out_open) "" else NULL,
        tags$summary(sprintf("执行输出（%d 行）", n_out)),
        tags$pre(class = "dsapp-run-pre", dsapp_escape(out_body))
      ),

      # ★ V13.12 item 8：产物体检结论。这是**红着脸**说的那一条。
      #
      #   用户原话：「这个任务生成出来的很多文件只有表头，看一下是哪里出了
      #   问题」。它不是"运行过程中的警告"（item 4 收起来的那种），而是
      #   "这一屏的分析结论底下没有数据" —— 收起来等于把问题本身藏了。
      #   判据在服务端（executor.R 的 dsapp_artifact_check），这里只负责
      #   把它摆在用户眼前，并且**说清楚平台接下来会怎么办**（AI 自己去
      #   修，不用你管）—— 见 agent.R 里那段回喂的措辞。
      dsapp_run_badart_ui(bad_body),

      # ⚠️ 这一段**不**跟着 V13.12 item 4 一起收起来，是有意的。
      #    它装的不是"分析过程中的警告"，而是代码扫描器在**执行之前**报的
      #    那几条（"向外发送数据，请确认目标地址可信""递归删除，请确认路径
      #    正确"）。它们要用户做的判断是"这段代码该不该跑"，和运行时报了
      #    几行 warning 完全是两件事；收起来等于把"数据正在离开这台机器"
      #    这个信号也一起藏了。见 R/scanner.R 顶部那两段。
      if (!is.null(warn_body) && nzchar(trimws(warn_body))) div(class = "dsapp-run-warn",
        icon("circle-info"), " ",
        paste(trimws(strsplit(warn_body, "\n", fixed = TRUE)[[1]]), collapse = "；")
      ),

      dsapp_run_files_ui(if (length(files)) files else dsapp_sec_files(secs), preview_input)
    )
  )
}

#' 正在执行的任务面板（V9 item 2）
#'
#' 用户的原话是「任务系统定位只是一个记录运行日志的地方，请把执行过程详细地
#' 在言出法随页面展示」。一个 RunUMAP 能跑十几分钟，这段时间里对话页上原来
#' 只有一个转圈 —— 用户只能切到「历史任务」页去 tail 日志，而那正是他希望不必
#' 做的事。
#'
#' ⚠️ 只在**确实在跑、而且属于当前对话**时渲染（判断在调用方）。引擎是全局
#'    单槽的，不判对话的话，甲会在自己的页面上看到乙的任务、还能把它停掉。
#'
#' @param t 运行中那一行的轻量元信息（db_tasks_meta）
#' @param out_tail / err_tail 子进程输出文件的末尾若干行
#' @param actions ★ Test_V15.3 item 4：这一处该显示的动作按钮（由调用方
#'   `run_actions_ui()` 渲染好递进来）。原来这里是写死的第二颗「停止任务」，
#'   现在全应用只有一颗停止按钮，见 mod_chat.R 的 action_host()。
#' @param tasks_input 「到任务页」派发的 input id
#' @noRd
dsapp_live_card <- function(t, out_tail = "", err_tail = "", elapsed = NA_real_,
                            actions = NULL, tasks_input = NULL) {
  tid <- if (is.null(t) || !nrow(t)) "?" else as.character(t$id[1])
  out_tail <- out_tail %||% ""
  err_tail <- err_tail %||% ""

  tagList(
    div(class = "dsapp-run dsapp-run-live",
      div(class = "dsapp-run-head",
        tags$span(class = "spinner-border spinner-border-sm"),
        tags$span(class = "dsapp-run-title", sprintf("任务 #%s 正在执行", tid)),
        dsapp_status_badge("running")
      ),
      if (!is.null(t) && nrow(t)) div(class = "dsapp-run-meta",
        paste(c(as.character(t$title[1] %||% ""),
                as.character(t$lang[1] %||% ""),
                as.character(t$target[1] %||% "")),
              collapse = " · "),
        # ★ V13.12 item 20：耗时交给前端自己走（app.js 读 data-secs）。
        #   ⚠️ 它**不能**留在服务端这一份里：这个数每秒都在变，留着它，
        #      整张卡片的内容指纹就每秒都变，"有新输出才重画"等于没做。
        if (!is.na(elapsed)) tags$span(
          class = "dsapp-elapsed", `data-secs` = sprintf("%.1f", elapsed),
          `data-fmt` = "dur",
          sprintf(" · 已跑 %s", dsapp_fmt_duration(elapsed)))),

      # ⚠️ 输出为空时也要说一句。不说的话，用户看到的是一个空框，而"空的"
      #    和"读不到"（工作区被删、文件还没建）在界面上长得一模一样。
      div(class = "dsapp-run-out dsapp-run-out-live",
        div(class = "dsapp-run-out-h",
          icon("terminal"), " 实时输出",
          # ⚠️ 这句话必须跟**实际行为**对得上。它原来写的是"每 2 秒刷新"——
          #    而"每 2 秒刷新"正是 V13.12 item 20 要取消的那个机制（用户原话
          #    「分析进行时页面还是会刷新，取消这个机制」），改完还留着这句
          #    就是一句假话。现在的真话是：有新输出才往下接，没有就不动。
          tags$span(class = "dsapp-run-out-tip",
                    "有新输出就往下接；完整日志在「历史任务」页")),
        if (nzchar(out_tail)) tags$pre(class = "dsapp-run-pre", dsapp_escape(out_tail))
        else div(class = "dsapp-run-pre dsapp-run-pre-empty",
                 "（子进程还没有输出。正在装包或读大文件时，这一步可能要几分钟。）")
      ),

      # 报错单独一块、红色。跑的时候 stderr 往往先于"失败"出现（比如一个
      # 没找到的包），先给用户看见，不必等任务收尾。
      if (nzchar(trimws(err_tail))) div(class = "dsapp-run-errbox",
        div(class = "dsapp-run-errbox-h", icon("triangle-exclamation"), " 标准错误"),
        tags$pre(class = "dsapp-run-pre", dsapp_escape(err_tail))
      ),

      div(class = "dsapp-run-actions",
        # ★ Test_V15.3 item 4：这里原来是第二颗「停止任务」按钮，和输出框下沿
        #   那颗「停止」长得几乎一样 —— 用户原话「停止按钮重复了」。现在
        #   全应用只有**一颗**停止按钮，由调用方通过 actions 递进来（见
        #   mod_chat.R 的 run_actions_ui / action_host）。
        #   ⚠️ 别在这里再补一颗"就地停止"：那正是这一版要拆掉的东西。
        actions,
        if (!is.null(tasks_input)) tags$button(
          class = "dsapp-btn", type = "button",
          onclick = dsapp_fire(tasks_input, tid),
          icon("list-check"), " 到「历史任务」页看完整日志")
      )
    )
  )
}

#' 「这个对话正在后台继续」横幅（V13.7 item 5）
#'
#' ★ 和隔壁 dsapp_live_card() 的分工：
#'   · live_card 讲的是**这个页面正在驱动**的那个任务（它自己能轮询、能刷输出）
#'   · 这一张讲的是**另一个进程在替这个对话干活**。页面这边看不见它、
#'     也轮询不到它，只能读 agent_runs 那一行
#'   两者可能同时出现（用户回来了，后台循环还在跑，顺手又跑了个任务）——
#'   那不是重复，说的确实是两件事。
#'
#' ⚠️ 停止按钮**不能**接 engine$abort()。后台循环活在另一个进程里，掐掉
#'    当前这个任务它只会当成一次失败、接着跑下一轮 —— 用户按了停止，界面上
#'    的任务没了，token 却还在烧，而且再也没有地方能停它。真正能让它停下的
#'    只有 dsapp_arun_stop()：改库里的状态，子进程每一轮开头读一次。
#'
#' ⚠️ 两档预设（mode）说的**不是**同一句话，必须分开写。都写成"AI 正在替你
#'    接着分析"的话，选了「只让当前任务跑完」的用户会以为模型还在往下做，
#'    在那儿等一个永远不会来的下一轮。
#'
#' @param r     dsapp_arun_get() 读出来的那一行
#' @param actions ★ Test_V15.3 item 4：这一处该显示的动作按钮（由调用方
#'   `run_actions_ui()` 渲染好递进来）。原来这里是写死的第三颗「停止后台运行」，
#'   现在全应用只有一颗停止按钮。
dsapp_detach_banner <- function(r, actions = NULL) {
  if (is.null(r)) return(NULL)
  mode <- as.character(r$blob$mode %||% "full")
  full <- identical(mode, "full")

  elapsed <- tryCatch({
    st <- as.character(r$started_at %||% "")
    if (!nzchar(st) || is.na(st)) NA_real_
    else as.numeric(difftime(Sys.time(), as.POSIXct(st, tz = "UTC"),
                             units = "secs"))
  }, error = function(e) NA_real_)

  tid <- suppressWarnings(as.integer(r$task_id %||% NA))
  note <- as.character(r$note %||% "")

  tagList(
    div(class = "dsapp-run dsapp-run-detach",
      div(class = "dsapp-run-head",
        tags$span(class = "spinner-border spinner-border-sm"),
        tags$span(class = "dsapp-run-title",
          if (full) "AI 正在后台接着这个对话往下跑"
          else "这个任务正在后台跑完"),
        tags$span(class = "dsapp-run-meta-inline", "页面关了也不会中断")
      ),
      div(class = "dsapp-run-meta",
        paste(Filter(nzchar, c(
          if (!is.na(elapsed)) sprintf("已跑 %s", dsapp_fmt_duration(elapsed)),
          if (!is.na(tid)) sprintf("当前任务 #%d", tid),
          # ★ V13.17 item 31：把用户选的那个自动结束时间**显示出来**。
          #
          # ⚠️ 这一条不是装饰。以前这里写的是"跑完会自己停下来" —— 那句话在
          #    wall_limit 写死的时候是够的（反正只有两小时，跑完就完了）。
          #    现在时长是用户自己选的，而且可达 8 小时：一句"会自己停下来"
          #    什么也没说，用户要么守在屏幕前不敢走，要么第二天回来发现
          #    半夜停了却不知道为什么。
          # ⚠️ 走 r$blob（库里的快照），**不是**读界面上的滑块 —— 这一行讲的
          #    是**那个后台进程**在按什么跑，而用户此刻完全可以把滑块拖到别的
          #    位置。读滑块的话横幅会显示一个那个进程根本不知道的数。
          # ⚠️ 老行（V13.17 之前写的）blob 里没这个键，%||% 退回默认的 7200 ——
          #    那正是老行当时实际用的值，显示出来是**对的**，不是兜底。
          if (full) sprintf("跑完会自己停下来（最长 %s）",
                            dsapp_wall_label(r$blob$wall_limit %||%
                                               DSAPP_AGENT_WALL_DEF))
          else "任务跑完就结束，不会往下走新的分析")),
          collapse = " · ")),

      # note 是后台进程自己写的一句话（失败原因、参数用了默认值之类）。
      # 有就照实显示 —— 后台没有别的地方能让用户看到它。
      if (nzchar(note)) div(class = "dsapp-run-note", note),

      # ★ Test_V15.3 item 4：这里原来是第三颗红色「停止后台运行」。同上，
      #   现在走统一的 actions —— 全应用一颗停止按钮。
      div(class = "dsapp-run-actions", actions)
    )
  )
}

#' 从 tool 消息的首行里取出任务号
#'
#' 首行固定形如「【执行结果 · 任务 #12】」（见 dsapp_agent_tool_text）。
#' 「【平台提示】」「【执行结果 · 未执行】」这类没有任务号，返回 NULL ——
#' 调用方据此走纯文本渲染。
#'
#' ⚠️ 锚在**首行**上，不在整段里找。整段搜的话，正文里引用到的别的任务号
#'    （模型常写"承接任务 #7 的结果"）会把这张卡片接到另一个任务上去 ——
#'    而接错的表现是"卡片显示的是别人的输出"，比不显示卡片更糟。
#' @noRd
dsapp_tool_task_id <- function(content) {
  h <- strsplit(content %||% "", "\n", fixed = TRUE)[[1]]
  if (!length(h)) return(NULL)
  m <- regmatches(h[[1]], regexpr("任务\\s*#\\s*([0-9]+)", h[[1]]))
  if (!length(m) || !nzchar(m)) return(NULL)
  id <- suppressWarnings(as.integer(sub(".*#\\s*", "", m)))
  if (is.na(id)) NULL else id
}
