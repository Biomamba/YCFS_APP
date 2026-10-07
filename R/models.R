# =============================================================================
# 模型目录
# =============================================================================
# V2 的模型下拉框只有硬编码的 deepseek-chat / deepseek-reasoner 两项。
# 用户的反馈是"模型选择有误，请按 deepseek 历史上真实所有的可通过 api key
# 调用的模型名称，以及其它国产大模型名称"。
#
# ---- 这个文件解决的是哪一半问题 ----------------------------------------------
#
# 要分清楚两件事：
#
#   (a) 厂商的 base_url 和「去哪儿申请 Key」  —— 这个只能人工维护，
#       官方文档里没有机器可读的接口。所以写在下面的目录里。
#
#   (b) 当前可用的 model 名称                —— 这个**不该**由我们维护。
#
# 模型名是厂商随时会改的东西。把 (b) 也写死在代码里，今天写对了明天还是错，
# 这正是 V2 的问题所在。所以设置页做成：**填好 Key 之后点「获取可用模型」，
# 直接问厂商的 /models 接口**，那才是权威且永远最新的。下面的
# fallback_models 只在用户还没填 Key、或厂商不支持 /models 时用来占位。
#
# ---- ⚠️ 2026-09-12 的实测结果：deepseek-chat 已经没了 ------------------------
#
# 这条值得单独写出来，因为它正是"写死模型名"会怎么坑人的活例子。
#
# V2 里那两个模型名，deepseek-chat 和 deepseek-reasoner，**已经全部下线**。
# 我直接拉取了官方价格页（https://api-docs.deepseek.com/zh-cn/quick_start/pricing）
# 和 create-chat-completion 接口文档核对，当前 model 参数的取值只有两个：
#
#     deepseek-flash      （模型版本 DeepSeek-V4.1-Flash，1M 上下文）
#     deepseek-v4-pro     （模型版本 DeepSeek-V4-Pro-0813）
#
# 现在传 deepseek-chat 会直接报错。所以下面 deprecated 表里它们排在头两个。
#
# ---- deprecated 为什么要带「替代品」-----------------------------------------
#
# 用户从旧教程/旧代码里抄来 deepseek-coder、deepseek-chat，调用报 400。
# 界面上如果能直接告诉他"这个名字下线了，现在用 deepseek-flash"，比让他自己
# 猜强得多。更进一步：如果用户浏览器里存的还是旧名字，我们可以**直接替他换掉**，
# 而不是让他对着一个必然失败的请求发呆 —— 见 dsapp_model_migrate()。
# =============================================================================

#' 目录核验日期
#'
#' 界面上会显示出来。模型名变动很快，让用户知道这份清单是什么时候对过的，
#' 比让他盲信一个静态列表要好。
DSAPP_CATALOG_VERIFIED <- "2026-10-04"

DSAPP_MODEL_CATALOG <- list(

  # ---------------------------------------------------------------------------
  # ★ V13.12 item 5：用户点名要「DeepSeek 排第一」。
  #
  #   ⚠️ 位置就是需求的一部分。下拉框的顺序**原样**来自这个 list 的 names
  #      （见 dsapp_vendor_choices），所以"排第几"在这里就等于"写成第几个
  #      元素"，**不需要也不该有任何额外的排序代码** —— 加一个 sort 或者
  #      优先级字段，就等于让"目录里的物理顺序"和"用户看到的顺序"变成两个
  #      可以不一致的真相源，而下一个人只会改其中一个。
  #
  #   本版整体顺序（V13.12 item 5 明确指定了前三）：
  #     ① DeepSeek 深度求索   ② 中转站大全   ③ 0DaysSCI   ④… 其余按原样
  deepseek = list(
    label    = "DeepSeek 深度求索",
    base_url = "https://api.deepseek.com",
    key_url  = "https://platform.deepseek.com/api_keys",
    key_note = "注册后在「API keys」页创建，形如 sk- 开头的一串。",
    openai_compatible = TRUE,
    supports_models_api = TRUE,
    # DeepSeek 是唯一一家在 OpenAI 兼容格式下还提供 thinking / reasoning_effort
    # 的，见下面的 thinking 段。其它厂商暂时没有对应参数。
    supports_thinking = TRUE,
    fallback_models = c("deepseek-flash", "deepseek-v4-pro"),
    note = paste0(
      "思考模式默认开启。deepseek-flash 便宜且支持图像理解；",
      "deepseek-v4-pro 更强但不支持图像。",
      "另有 Anthropic 格式端点 https://api.deepseek.com/anthropic。"),
    deprecated = list(
      `deepseek-chat` = list(
        to  = "deepseek-flash",
        why = "已于 2026-07-24 下线，现在调用会直接报错"),
      `deepseek-reasoner` = list(
        to  = "deepseek-flash",
        why = paste0("已于 2026-07-24 下线。现在没有单独的推理模型了 —— ",
                     "deepseek-flash 默认就开思考模式")),
      `deepseek-coder` = list(
        to  = "deepseek-flash",
        why = "早已并入对话模型，不再单独提供"),
      `deepseek-coder-v2` = list(
        to  = "deepseek-flash", why = "早已并入对话模型"),
      `deepseek-v2` = list(
        to  = "deepseek-flash", why = "已下线"),
      `deepseek-v2.5` = list(
        to  = "deepseek-flash", why = "已下线"),
      `deepseek-v3` = list(
        to  = "deepseek-flash",
        why = "V3 系列已被 V4 取代，没有独立的 deepseek-v3 模型名"),
      `deepseek-r1` = list(
        to  = "deepseek-flash",
        why = "R1 系列已被 V4 取代，没有独立的 deepseek-r1 模型名"),
      # 这两个名字**还能调用**，但后端已经换人了 —— 属于"能用但名不副实"，
      # 所以给提示而不是报错
      `deepseek-v4-flash` = list(
        to  = "deepseek-flash",
        why = paste0("仍可调用，但该模型已下线，请求会被路由到 DeepSeek-V4.1-Flash，",
                     "按 Flash 价格计费。建议直接改成 deepseek-flash")),
      `deepseek-v4-flash-vision-exp` = list(
        to  = "deepseek-flash",
        why = paste0("仍可调用，但该模型已下线，请求会被路由到 DeepSeek-V4.1-Flash"))
    )
  ),

  # ---------------------------------------------------------------------------
  # ★ V13.12 item 5：新增「中转站大全」，排第二。
  #
  #   ⚠️ key_url（注册/领 Key 的跳转链接）和 base_url（接口地址）**不在同一个
  #      域名下**，这不是笔误：`api.ocean-way.top` 是站点的注册入口（带 aff
  #      邀请参数），`uumi.lol` 是它给出来的兼容接口地址。两个都是用户给的
  #      原文，别自作主张把其中一个改成另一个的域名。
  #
  #   ⚠️ 模型清单**故意留空**，和 0daysci / custom 一样 —— 中转平台挂哪些
  #      模型、叫什么名字是平台自己定的，写死在代码里必然过期。填好 Key
  #      之后点「获取模型」拉真实清单（V13.12 item 1 起，这个动作是按
  #      **接口地址**发的，所以中转站也拉得到）。
  #
  #   ⚠️ aggregator = TRUE，但 DSAPP_OWN_PATTERNS 里**不加**它的条目 ——
  #      它对谁家的模型都转售，加进去 own_pat 会命中一堆别家的名字。
  relay = list(
    label    = "中转站大全",
    aggregator = TRUE,
    base_url = "https://uumi.lol/v1",
    key_url  = "https://api.ocean-way.top/sign-up?aff=SdNE",
    key_note = paste0("在上面的链接注册后创建 API Key。",
                      "本站是聚合平台：一把 Key 能调它上面挂的各家模型。"),
    openai_compatible = TRUE,
    supports_models_api = TRUE,
    fallback_models = character(0),
    note = paste0("聚合平台 —— 可用模型以平台为准：填好 Key 之后点「获取模型」，",
                  "下拉框会按原厂分组列出真实可用的模型名。",
                  "接口地址默认 https://uumi.lol/v1；",
                  "换别家中转站时直接改「接口地址」那一栏再点「获取模型」。")
  ),

  # ---------------------------------------------------------------------------
  # ★ V13.6 item 4：用户点名要加的供应商（V13.12 item 5 起**排第三**）。
  #
  #   ⚠️ base_url 用用户给的原文 `https://api.0daysci.com`，**不带 /v1**。
  #      这一条是问过用户的，别按"OpenAI 兼容一般都带 /v1"的惯例自作主张加上。
  #      万一哪天真 404：中转站的兼容前缀确实多半在 /v1，而设置页的接口地址
  #      是**可改的**（dsapp_vendor_base_url 收 override），用户改成
  #      https://api.0daysci.com/v1 就能用 —— 所以 note 里把这句话写给他了，
  #      比让他在一屏 404 前面猜要好。
  #
  #   ⚠️ 模型清单**故意留空**，和 custom 那家一样。中转平台挂哪些模型、叫什么
  #      名字是平台自己定的，写死在代码里必然过期 —— 而这个文件开头的整段
  #      说明讲的就是"过期清单比没有清单更坏"。所以走「获取模型」拉真实清单：
  #      supports_models_api = TRUE 就是为了这个。
  #      代价是**填完 Key 必须先点一次「获取模型」**才能选模型，note 里明说了。
  #
  #   aggregator = TRUE 只是让模型下拉按原厂分组（它对谁家的模型都转售，
  #   认不出"自家"模型）。DSAPP_OWN_PATTERNS 里**不加**它的条目 —— 加了的话
  #   own_pat 会命中一堆别家的名字，把它们全标成"本平台"。
  `0daysci` = list(
    label    = "0DaysSCI",
    aggregator = TRUE,
    base_url = "https://api.0daysci.com",
    # 用户给的原文：获取 API 的跳转链接。
    #
    # ⚠️ 只填 key_url，**不填 invite_url**。这两个字段的区别是"要不要先登录"：
    #    invite_url 是给还没账号的人点的（注册页），key_url 是控制台（点进去
    #    会撞登录墙）。这家用户只给了一个链接，而它本身就是注册页 ——
    #    填进 key_url 之后，界面上那句「官网申请」会退回用它渲染
    #    （见 mod_model.R 里 apply_url 的兜底），正好是想要的效果；
    #    再填一遍 invite_url 只会让同一个地址在界面上出现两次。
    key_url  = "https://www.0daysci.com/register?aff=UcNr",
    key_note = paste0("在上面的链接注册后，到控制台创建 API Key（一般形如 sk- 开头）。",
                      "本站是聚合平台：一把 Key 能调它上面挂的各家模型。"),
    openai_compatible = TRUE,
    supports_models_api = TRUE,
    fallback_models = character(0),
    note = paste0("聚合平台 —— 可用模型以平台为准：填好 Key 之后点「获取模型」，",
                  "下拉框会按原厂分组列出真实可用的模型名。",
                  "接口地址默认 https://api.0daysci.com；",
                  "若报 404，把它改成 https://api.0daysci.com/v1 再试",
                  "（部分中转站的兼容前缀在 /v1）。")
  ),

  # ---------------------------------------------------------------------------
  # ⚠️ 百炼是**聚合平台**（aggregator）：一把 Key、一个地址，既能调通义自家的
  #    模型，也能调 DeepSeek / Kimi / GLM / MiniMax 等别家的（见下面
  #    dsapp_vendor_model_groups 的整个说明）。方舟 / 千帆 / TokenHub 同理。
  qwen = list(
    label    = "阿里通义千问 Qwen",
    own_label = "通义千问",
    aggregator = TRUE,
    base_url = "https://dashscope.aliyuncs.com/compatible-mode/v1",
    key_url  = "https://bailian.console.aliyun.com/",
    key_note = paste0("阿里云百炼控制台 → 右上角「API-KEY」→ 创建。",
                      "需要先开通百炼服务。注意 Key 与地域绑定，",
                      "Key 的地域必须和接口地址一致，否则报 401。"),
    openai_compatible = TRUE,
    supports_models_api = FALSE,   # 兼容模式下 /models 不可靠，用下面的清单
    fallback_models = c("qwen3.8-max", "qwen3.8-flash", "qwen3.7-plus",
                        "qwen3.7-flash", "qwen-long", "qwen-max",
                        "qwen-plus", "qwen-turbo"),
    note = paste0("推荐：qwen3.8-max（最强）/ qwen3.7-plus（均衡）/ ",
                  "qwen3.8-flash（便宜）。",
                  "百炼是聚合平台，同一把 Key、同一个地址也能调 DeepSeek、",
                  "Kimi、GLM、MiniMax 等别家的模型 —— 模型下拉里按原厂分了组。",
                  # ⚠️ 两条都是"不照做就一定失败"的，所以写在面板上而不是
                  #    只写在开发笔记里（见 DSAPP_RESOLD_MODELS 上面那段）。
                  "⚠️ 别家的模型要先去百炼控制台搜厂商名点「立即开通」，",
                  "没开通直接报错。",
                  "⚠️ 带 `厂商/` 前缀的那些（kimi/kimi-k3、ZHIPU/GLM-5.3）",
                  # ★ 这一段里的 `**...**`（还有前面那条 `⚠️`）**故意留成字面量**，
                  #   由展示处 dsapp_md_inline() 转成 <strong>。别在这里就地转：
                  #   ① dsapp_md_inline() 返回的是 htmltools 的 HTML 对象，而它是
                  #      paste0() 的一个参数 —— paste0 会 as.character() 把它压成
                  #      普通字符串，**类就没了**，界面上看到的是一对尖括号
                  #      （2026-09-16 实测：`<strong>只在华北2（北京）</strong>`）。
                  #   ② 这是**顶层**代码（DSAPP_MODEL_CATALOG 是 source 时就求值的
                  #      常量），而 models.R 在 app.R 的清单里排在 utils.R 后面没
                  #      问题、按 list.files() 的字母序（models.R 在 utils.R 前）
                  #      就是 could not find function —— selftest 和后台子进程
                  #      走的正是字母序那条路。
                  "是原厂直供，**只在华北2（北京）**可用，前缀不能省 —— ",
                  "漏了会报 InvalidModelId —— 看着像「模型不存在」，",
                  "其实是名字不对。")
  ),

  # ---------------------------------------------------------------------------
  zhipu = list(
    label    = "智谱 GLM（BigModel）",
    base_url = "https://open.bigmodel.cn/api/paas/v4",
    key_url  = "https://bigmodel.cn/usercenter/proj-mgmt/apikeys",
    # ⚠️ invite_url 和 key_url 是**两个不同的页面**，别合并成一个字段：
    #    这个是"还没有账号，去注册"（带邀请码，注册双方都有额度），
    #    那个是"已经有账号，去拿 Key"。合成一个的话，已经有账号的人
    #    每次点「申请」都会被丢回注册页。
    invite_url = "https://www.bigmodel.cn/invite?icode=uGoVkyfgBMhneusLOZCgY2czbXFgPRGIalpycrEwJ28%3D",
    key_note = "注册后在「API Keys」页复制，形如 xxxxx.xxxxx。",
    openai_compatible = TRUE,
    supports_models_api = FALSE,
    fallback_models = c("glm-5.3", "glm-5.2", "glm-5.1", "glm-5-turbo",
                        "glm-5", "glm-4.7", "glm-4.7-flash", "glm-4.6",
                        "glm-4.5-air", "glm-4.5-flash"),
    note = paste0("glm-5.3 是当前默认模型；glm-4.7-flash / glm-4.5-flash 免费。",
                  "glm-4.6v、glm-5v-turbo 是视觉模型，glm-4-voice 是语音模型，",
                  "都不在这个对话接口里。")
  ),

  # ---------------------------------------------------------------------------
  moonshot = list(
    label    = "Kimi 月之暗面（Moonshot）",
    base_url = "https://api.moonshot.cn/v1",
    key_url  = "https://platform.kimi.com/console/api-keys",
    key_note = "开放平台 →「API Key 管理」→ 新建。",
    openai_compatible = TRUE,
    supports_models_api = TRUE,
    fallback_models = c("kimi-k3", "kimi-k2.7-code", "kimi-k2.6"),
    note = paste0("域名已迁移：platform.moonshot.cn 现在会跳到 platform.kimi.com。",
                  "国际站接口地址是 https://api.moonshot.ai/v1。"),
    deprecated = list(
      `moonshot-v1-8k`  = list(to = "kimi-k3", why = "已于 2026-08-31 下线"),
      `moonshot-v1-32k` = list(to = "kimi-k3", why = "已于 2026-08-31 下线"),
      `moonshot-v1-128k` = list(to = "kimi-k3", why = "已于 2026-08-31 下线"),
      `kimi-latest`     = list(to = "kimi-k3", why = "已于 2026-08-31 下线"),
      `kimi-k2.5`       = list(to = "kimi-k3", why = "已于 2026-08-31 下线")
    )
  ),

  # ---------------------------------------------------------------------------
  doubao = list(
    label    = "字节豆包 Doubao（火山方舟）",
    own_label = "豆包",
    aggregator = TRUE,
    base_url = "https://ark.cn-beijing.volces.com/api/v3",
    key_url  = "https://console.volcengine.com/ark",
    # 同上：短链是注册入口，console.volcengine.com 是已有账号的控制台。
    invite_url = "https://volcengine.com/L/yI2tkEV2pds/",
    key_note = "火山方舟控制台 →「API Key 管理」。",
    openai_compatible = TRUE,
    supports_models_api = TRUE,
    fallback_models = c("doubao-seed-2-1-pro-260628",
                        "doubao-seed-2-1-turbo-260628",
                        "doubao-seed-2-0-pro-260215"),
    note = paste0("用之前要先去方舟控制台「开通模型服务」，否则报错。",
                  "现在可以直接传模型名了，不再强制要求 ep- 开头的接入点 ID。",
                  "上海地域的地址是 ark.cn-shanghai.volces.com/api/v3。",
                  # ⚠️ 这里原来写的是「DeepSeek、Kimi 等」—— **Kimi 是错的**。
                  #    2026-09-16 逐条核过方舟的官方模型列表：按「提供方」列
                  #    统计只有字节跳动 / 深度求索 / 智谱（外加两家做 3D 的），
                  #    全量检索 kimi / minimax / 阶跃 / 零一 / llama **零命中**。
                  #    这种"照抄别家平台"的错误最坑：用户会去方舟找一个
                  #    根本不存在的模型。
                  "方舟上还有别家的模型（DeepSeek、智谱 GLM），下拉里按原厂分组。",
                  # ⚠️ 同上：`**` 留字面量，展示处转。
                  "⚠️ 方舟的模型名都**带日期后缀**（deepseek-v4-pro-ga-260813）：",
                  "订阅套餐文档里那种不带日期的写法官方明说不能用于 API 调用。")
  ),

  # ---------------------------------------------------------------------------
  ernie = list(
    label    = "百度文心 ERNIE（千帆）",
    own_label = "文心 ERNIE",
    aggregator = TRUE,
    base_url = "https://qianfan.baidubce.com/v2",
    key_url  = "https://console.bce.baidu.com/iam/#/iam/apikey/list",
    key_note = "百度智能云 →「IAM → API Key」里创建，直接当 Bearer 用。",
    openai_compatible = TRUE,
    supports_models_api = FALSE,
    fallback_models = c("ernie-5.1", "ernie-5.0", "ernie-5.0-thinking-latest",
                        "ernie-4.5-turbo-128k", "ernie-x1.1"),
    note = paste0("走的是 v2 端点。旧的 V1 接口已于 2026-08-31 下线，",
                  "ernie-4.0 / 3.5 / speed / lite 那些旧名字都不能用了。",
                  "千帆是聚合平台，同一把 Key 也能调 DeepSeek、Kimi、GLM 等",
                  "别家的模型 —— 下拉里按原厂分了组。"),
    # ⚠️ 千帆有一类模型**不能直接传裸模型名**：自导入的（HuggingFace / Llama
    #    之类）必须先建「自定义接入点 / 在线推理服务」，用服务详情里的
    #    API 名称当 model。这条不影响下拉里的候选，但用户拿不到名字时
    #    唯一能查的就是这句提示。
    extra_note = paste0("不在预置列表里的模型（自己导入的）要先在千帆建",
                        "「在线推理服务」，用服务详情里的 API 名称当模型名。"),
    deprecated = list(
      `ernie-4.0-8k`   = list(to = "ernie-5.0", why = "V1 接口已下线"),
      `ernie-3.5-8k`   = list(to = "ernie-5.0", why = "V1 接口已下线"),
      `ernie-speed-8k` = list(to = "ernie-5.0", why = "V1 接口已下线"),
      `ernie-lite-8k`  = list(to = "ernie-5.0", why = "V1 接口已下线")
    )
  ),

  # ---------------------------------------------------------------------------
  hunyuan = list(
    label    = "腾讯混元 Hunyuan（TokenHub）",
    own_label = "混元 Hunyuan",
    aggregator = TRUE,
    base_url = "https://tokenhub.tencentmaas.com/v1",
    key_url  = "https://console.cloud.tencent.com/tokenhub/apikey",
    key_note = "腾讯云控制台 → TokenHub →「API Key」。",
    openai_compatible = TRUE,
    supports_models_api = TRUE,
    fallback_models = c("hy3", "hy4-preview", "hunyuan-role-latest"),
    note = paste0("⚠️ 接口地址换了：旧的 api.hunyuan.cloud.tencent.com 平台",
                  "已于 2026-09-30 全面停服，别再用了。现在走 TokenHub。",
                  "TokenHub 也代理别家的模型，下拉里按原厂分组。"),
    deprecated = list(
      `hunyuan-turbos-latest` = list(to = "hy3", why = "2026-06-22 下线"),
      `hunyuan-large`         = list(to = "hy3", why = "2026-06-22 下线"),
      `hunyuan-standard`      = list(to = "hy3", why = "2026-06-22 下线"),
      `hunyuan-lite`          = list(to = "hy3", why = "2026-06-22 下线")
    )
  ),

  # ---------------------------------------------------------------------------
  spark = list(
    label    = "讯飞星火 Spark",
    base_url = "https://spark-api-open.xf-yun.com/v1",
    key_url  = "https://console.xfyun.cn/",
    key_note = paste0("讯飞开放平台 → 创建应用 → 拿到 APIKey 和 APISecret，",
                      "拼成「APIKey:APISecret」整串当 Bearer 用。"),
    openai_compatible = TRUE,
    supports_models_api = FALSE,
    fallback_models = c("4.0Ultra", "generalv3.5", "max-32k", "lite"),
    note = paste0("注意接口地址末尾要带斜杠。深度推理的 X 系列模型名都叫 spark-x，",
                  "靠不同地址区分：X2 用 /x2/，X1.5 用 /v2/，X2-Flash 用 /agent/v1/。")
  ),

  # ---------------------------------------------------------------------------
  minimax = list(
    label    = "MiniMax",
    base_url = "https://api.minimax.cn/v1",
    key_url  = "https://platform.minimaxi.com/user-center/basic-information/interface-key",
    key_note = "开放平台 →「账户管理」→「接口密钥」。",
    openai_compatible = TRUE,
    supports_models_api = TRUE,
    fallback_models = c("MiniMax-M3", "MiniMax-M2.7", "MiniMax-M2.5", "MiniMax-M2"),
    note = "国际站接口地址是 https://api.minimax.io/v1。",
    deprecated = list(
      `MiniMax-Text-01` = list(to = "MiniMax-M3", why = "已下线"),
      `abab6.5s-chat`   = list(to = "MiniMax-M3", why = "已下线")
    )
  ),

  # ---------------------------------------------------------------------------
  stepfun = list(
    label    = "阶跃星辰 StepFun",
    base_url = "https://api.stepfun.com/v1",
    key_url  = "https://platform.stepfun.com/interface-key",
    key_note = "开放平台 →「接口密钥」→ 新建。",
    openai_compatible = TRUE,
    supports_models_api = TRUE,
    fallback_models = c("step-3.7-flash", "step-3.5-flash"),
    note = "另有 Anthropic 格式端点 https://api.stepfun.com/v1/messages。",
    deprecated = list(
      `step-1-8k`  = list(to = "step-3.7-flash", why = "2026-07-08 下线"),
      `step-1-32k` = list(to = "step-3.7-flash", why = "2026-07-08 下线"),
      `step-2-16k` = list(to = "step-3.7-flash", why = "2026-07-08 下线"),
      `step-2-mini` = list(to = "step-3.7-flash", why = "2026-07-08 下线")
    )
  ),

  # ---------------------------------------------------------------------------
  baichuan = list(
    label    = "百川智能 Baichuan",
    base_url = "https://api.baichuan-ai.com/v1",
    key_url  = "https://platform.baichuan-ai.com/console/apikey",
    key_note = "开放平台 →「API Key」→ 新建。",
    openai_compatible = TRUE,
    supports_models_api = FALSE,
    fallback_models = c("Baichuan4-Turbo", "Baichuan4-Air", "Baichuan4"),
    note = paste0("Baichuan-M 系列是医疗大模型，调用 M3-Plus / M2-Plus 会",
                  "自动触发医疗搜索并按次另外计费，通用场景请用 Baichuan4-Turbo。")
  ),

  # ===========================================================================
  # ★ V16.3 item 1 —— 用户原话：「还有哪些可支持的国内、国际模型厂商，
  #   也帮我更新进去」。下面这一大段就是这一次补的（国内 10 家 + 国际 17 家）。
  #
  # ---- 这些 base_url 是怎么来的：**实测**，不是从文档抄的 ---------------------
  #
  #   判据是**拼接之后那条路存不存在**：
  #
  #       POST {base_url}/chat/completions
  #
  #   因为应用每一次请求都这么发（dsapp_vendor_base_url 只 sub 掉尾斜杠，
  #   **不补也不猜**任何前缀），所以"base_url 对不对"唯一有意义的判据就是这条
  #   路径。401/403/400/405 = 存在（缺鉴权 / 缺 body / 不收 GET）；404 = 写错了。
  #
  #   ⚠️ 每一个 host 都配了一条**对照探针**（同样 POST 到一个不存在的路径）：
  #      对照也返回同一个码的，说明这个 host 对任何路径都这么答，该家的判据
  #      **作废**（下面标了「兜底」的那几家就是），它们的 base_url 以官方文档
  #      原文为准。没有对照的话，"401"既可能是"路径在、缺 Key"，也可能是
  #      "整个站都在拒绝你"—— 这两件事的结论完全相反。
  #
  #   凡本机（昆明联通）连不上的国际厂商，路径判据天然失效，写的是官方文档
  #   口径的地址，并在 note 里注明「需先配代理」—— 正好和本版 item 2 那组
  #   代理设置是一套东西。
  #
  # ---- ⚠️ **故意不收**的几家，以及为什么（免得下一个人再研究一遍）-----------
  #
  #   · Anthropic —— api.anthropic.com 只有 /v1/messages，**没有**
  #                  /v1/chat/completions，而本应用只会发后者，收了必 404。
  #                  想用 Claude 请走下面的 OpenRouter / DeepInfra / Novita。
  #   · Cohere —— 兼容层地址是 /compatibility/v1，而且多方报告它**拒绝
  #                  stream_options 字段**，本应用每次请求都发它
  #                  （stream:true + stream_options.include_usage）→
  #                  收了就是"一发就 400"。没人实测过，宁可不收。
  #   · Azure OpenAI / Google Vertex / Cloudflare Workers AI —— base_url 里带
  #                  {resource} / {PROJECT} / {account_id} 这类**必须替换的占位
  #                  符**，Vertex 还要 OAuth access token（1 小时过期）而不是
  #                  静态 Key。这一类的正确用法是「自定义 / 中转代理」那一栏。
  #   · 澜舟科技 / 西湖心辰 / 紫东太初 / 移动 MoMA / 联通元景 —— 平台是真的，
  #                  但**查不到面向公众的自助 OpenAI 兼容接入点**（toB 交付型、
  #                  或控制台未公开）。记在这里是"待查"，不是"不存在"。
  #   · 科大讯飞 Astron —— 那是讯飞的**智能体产品线**（AstronClaw 之类），不是
  #                  模型 API 平台；讯飞的模型 API 就是上面已有的 spark。
  #   · 昆仑万维 Skywork / 元象 Xverse —— 接口现状无法证实（skywork 全 503、
  #                  xverse 连对照路径都是 404）。宁可不收。
  #
  # ---- 模型的静态清单：只在两种情况下才填 -------------------------------------
  #
  #   ① 这家不支持 /models（不填用户就没有任何可选项）
  #   ② 这一天**当场量到过**（实测 200，或官方文档原文）
  #
  #   其余的**一律留空**，让用户点「获取模型」现拉 —— 本文件开头整段讲的就是
  #   "写死的模型名必然过期"。留空不会让下拉框变空：mod_model.R 里那条闸门
  #   会明确告诉用户"先去点一下获取模型"。
  # ===========================================================================

  # ---------------------------------------------------------------------------
  # 国内 · 聚合 / 推理平台
  siliconflow = list(
    label    = "硅基流动 SiliconFlow",
    aggregator = TRUE,
    base_url = "https://api.siliconflow.cn/v1",
    key_url  = "https://cloud.siliconflow.cn/account/ak",
    key_note = "注册后「账户管理 → API 密钥」创建。",
    openai_compatible = TRUE,
    supports_models_api = TRUE,
    fallback_models = character(0),
    note = paste0("聚合平台：一把 Key 调它上面挂的各家开源模型。",
                  "国际站是 https://api.siliconflow.com/v1 —— ",
                  "和国内站是**两套账号**，Key / 余额 / 模型名都不互通。")
  ),

  # ---------------------------------------------------------------------------
  ppio = list(
    label    = "PPIO 派欧云",
    aggregator = TRUE,
    base_url = "https://api.ppio.com/openai",
    key_url  = "https://ppio.com/settings/key-management",
    key_note = "注册并实名后，在「API 密钥管理」创建。",
    openai_compatible = TRUE,
    supports_models_api = TRUE,
    # 2026-10-04 实测 GET /models 返回 200、84 条，下面这几个是当天清单里的原文
    fallback_models = c("deepseek/deepseek-v4-flash", "deepseek/deepseek-v4-pro",
                        "qwen/qwen3.8-max", "qwen/qwen3.8-flash",
                        "zai-org/glm-5.3", "moonshotai/kimi-k3",
                        "minimax/minimax-m3", "xiaomimimo/mimo-v2.6-pro"),
    note = paste0("⚠️ 基础地址是 **/openai**，不是 /v1。",
                  "它的 /models **不用 Key 就能列**（2026-10-04 实测 84 条），",
                  "所以随时点「获取模型」都能拿到当天完整的清单。")
  ),

  # ---------------------------------------------------------------------------
  luchentech = list(
    label    = "潞晨科技 LuchenTech",
    aggregator = TRUE,
    base_url = "https://api.luchentech.com/inference/v1",
    key_url  = "https://cloud.luchentech.com/",
    key_note = "登录潞晨 AI 平台，在控制台创建 API 密钥。",
    openai_compatible = TRUE,
    supports_models_api = TRUE,
    fallback_models = character(0),
    note = paste0("⚠️ 地址里有 **inference** 那一段，别漏。",
                  "模型名是 `厂商/模型` 的写法（如 moonshotai/kimi-k2.7-code），",
                  "前缀不能省。")
  ),

  # ---------------------------------------------------------------------------
  infini = list(
    label    = "无问芯穹 Infini-AI",
    aggregator = TRUE,
    base_url = "https://cloud.infini-ai.com/maas/v1",
    key_url  = "https://cloud.infini-ai.com/",
    key_note = "控制台「API 密钥管理」创建；复制时可能要求绑定手机号并二次验证。",
    openai_compatible = TRUE,
    supports_models_api = TRUE,
    fallback_models = character(0),
    note = paste0("接口地址是 /maas/v1。部分模型另有 Anthropic Messages 兼容接口。",
                  "⚠️ 它的 Key 只能禁用、不能删除。")
  ),

  # ---------------------------------------------------------------------------
  # 国内 · 模型厂商
  mimo = list(
    label    = "小米 MiMo",
    base_url = "https://api.xiaomimimo.com/v1",
    key_url  = "https://platform.xiaomimimo.com/",
    key_note = "在 MiMo 开放平台创建 API Key。",
    openai_compatible = TRUE,
    supports_models_api = TRUE,
    fallback_models = character(0),
    note = paste0("模型名以「获取模型」返回的为准 —— 别的平台上叫 mimo-v2.5 / ",
                  "mimo-v2.6，那些是**第三方平台的命名**，不能当官方 id 填。")
  ),

  # ---------------------------------------------------------------------------
  sensenova = list(
    label    = "商汤日日新 SenseNova",
    base_url = "https://token.sensenova.cn/v1",
    key_url  = "https://platform.sensenova.cn/console",
    key_note = "注册后在控制台复制 API Key。",
    openai_compatible = TRUE,
    supports_models_api = TRUE,
    fallback_models = character(0),
    note = paste0("现役模型：SenseNova U1 Pro / U1.5 Lite / 6.8 Flash Lite。",
                  "旧教程里的 https://api.sensenova.cn/compatible-mode/v1 仍能调用，",
                  "但那个地址**没有 /models**（会 404），列模型要用上面这个地址。")
  ),

  # ---------------------------------------------------------------------------
  longcat = list(
    label    = "美团龙猫 LongCat",
    base_url = "https://api.longcat.chat/openai/v1",
    key_url  = "https://longcat.chat/platform/api_keys",
    key_note = paste0("开放平台「API Keys」页新建。",
                      "Key 只在创建时显示一次，记得当场保存。"),
    openai_compatible = TRUE,
    supports_models_api = TRUE,
    fallback_models = c("LongCat-2.5-Preview", "LongCat-2.0"),
    note = paste0("⚠️ 这家的兼容前缀是 **/openai/v1**（两段），",
                  "别照搬别家的 /v1 —— 那个会 404。",
                  "另有 Anthropic 格式端点 https://api.longcat.chat/anthropic。")
  ),

  # ---------------------------------------------------------------------------
  minicpm = list(
    label    = "面壁智能 MiniCPM（ModelBest）",
    base_url = "https://api.modelbest.cn/v1",
    key_url  = "https://platform.modelbest.cn/console/",
    key_note = "注册后在控制台创建 API Key。",
    openai_compatible = TRUE,
    supports_models_api = TRUE,
    fallback_models = character(0),
    note = paste0("模型名以「获取模型」返回的为准 —— ",
                  "官方文档页是 SPA，静态清单抄下来必然过期。")
  ),

  # ---------------------------------------------------------------------------
  pangu = list(
    label    = "华为盘古 Pangu（ModelArts MaaS）",
    base_url = "https://api.modelarts-maas.com/v1",
    key_url  = "https://console.huaweicloud.com/modelarts/",
    key_note = "华为云控制台 → ModelArts → 在线推理，获取 API Key 与调用地址。",
    openai_compatible = TRUE,
    supports_models_api = TRUE,
    fallback_models = character(0),
    note = paste0("缺 Key 时它返回的是 **400** 而不是 401（华为的风格），",
                  "别把「Failed to get the authorization header」当成接口不存在。",
                  "⚠️ 华为云的推理服务常绑地域，报错时先去控制台核对调用地址。")
  ),

  # ---------------------------------------------------------------------------
  zhinao = list(
    label    = "360 智脑",
    base_url = "https://api.360.cn/v1",
    key_url  = "https://ai.360.cn/",
    key_note = "在 360 智脑开放平台申请 API Key。",
    openai_compatible = TRUE,
    supports_models_api = TRUE,
    fallback_models = character(0),
    note = paste0("官方称支持 OpenAI API 用户无痛迁移。",
                  "官网上列的名字有 360gpt2-pro / 360gpt-turbo / 360gpt-pro-trans / ",
                  "360gpt-turbo-32k-agent，但它们**是不是 API 传参用的名字没证实**，",
                  "所以没写进静态清单 —— 填好 Key 后点「获取模型」为准。")
  ),

  # ---------------------------------------------------------------------------
  # 国际 · 原厂
  openai = list(
    label    = "OpenAI",
    base_url = "https://api.openai.com/v1",
    key_url  = "https://platform.openai.com/api-keys",
    key_note = "登录后在「API keys」页创建。",
    openai_compatible = TRUE,
    supports_models_api = TRUE,
    fallback_models = character(0),
    note = paste0("⛔ 大陆直连不通（2026-10-04 实测超时），要先用上面那组",
                  "「代理」设置连上境外网络再点「获取模型」。",
                  "官方支持的国家/地区里**不包含中国大陆和香港**，账号风险请自行判断。")
  ),

  # ---------------------------------------------------------------------------
  gemini = list(
    label    = "Google Gemini",
    base_url = "https://generativelanguage.googleapis.com/v1beta/openai",
    key_url  = "https://aistudio.google.com/apikey",
    key_note = "在 Google AI Studio 里创建 API Key。",
    openai_compatible = TRUE,
    # 兼容层的 /models 历史上被下线过、也出现过整体 501 —— 宁可走静态清单
    supports_models_api = FALSE,
    fallback_models = c("gemini-3.6-flash", "gemini-3.5-flash", "gemini-flash-latest"),
    note = paste0("⚠️ 地址是 **/v1beta/openai**（两段都要）。",
                  "⛔ 大陆直连不通，需先配代理；官方可用地区也不含中国大陆与香港。",
                  "2.5 系列将于 2026-10-20 弃用，所以清单里没有它。")
  ),

  # ---------------------------------------------------------------------------
  xai = list(
    label    = "xAI Grok",
    base_url = "https://api.x.ai/v1",
    key_url  = "https://console.x.ai/",
    key_note = "登录 xAI 控制台创建 API Key。",
    openai_compatible = TRUE,
    supports_models_api = TRUE,
    fallback_models = character(0),
    note = paste0("⛔ 大陆直连不通（实测超时），要先用上面那组「代理」设置。",
                  "Grok 的模型名换代很快，以「获取模型」为准。")
  ),

  # ---------------------------------------------------------------------------
  mistral = list(
    label    = "Mistral AI",
    base_url = "https://api.mistral.ai/v1",
    key_url  = "https://console.mistral.ai/api-keys",
    key_note = "登录 Mistral 控制台创建 API Key。",
    openai_compatible = TRUE,
    supports_models_api = TRUE,
    fallback_models = character(0),
    note = paste0("⛔ 大陆直连不通，需先配代理。",
                  "另有区域端点 api.eu.mistral.ai / api.us.mistral.ai。")
  ),

  # ---------------------------------------------------------------------------
  groq = list(
    label    = "Groq",
    aggregator = TRUE,
    base_url = "https://api.groq.com/openai/v1",
    key_url  = "https://console.groq.com/keys",
    key_note = "登录 Groq 控制台「API Keys」页创建。",
    openai_compatible = TRUE,
    supports_models_api = TRUE,
    # 官方模型页（console.groq.com/docs/models）当前在列的 id，2026-10-04 核对。
    # ⚠️ 故意**没有**放已弃用的那几个（gemma2-9b-it / llama3-70b-8192 /
    #    llama3-8b-8192 / llama-guard-* / moonshotai/kimi-k2-instruct /
    #    compound-beta*）—— 它们最容易被从旧文章里抄进来。
    #    也没放 whisper-* 和 *-prompt-guard-*：那是语音和安全分类模型，不能对话。
    fallback_models = c("llama-3.3-70b-versatile", "llama-3.1-8b-instant",
                        "openai/gpt-oss-120b", "openai/gpt-oss-20b",
                        "qwen/qwen3.8-27b"),
    note = paste0("⚠️ 地址是 **/openai/v1**（两段）—— 只写 /v1 会 404。",
                  "⛔ 大陆直连被 Cloudflare 地区封锁（实测 403 Forbidden；",
                  "同一时刻从境外出口请求返回的是「Invalid API Key」，",
                  "所以那是地区封锁不是鉴权错误），需先配代理。")
  ),

  # ---------------------------------------------------------------------------
  cerebras = list(
    label    = "Cerebras",
    aggregator = TRUE,
    base_url = "https://api.cerebras.ai/v1",
    key_url  = "https://cloud.cerebras.ai",
    key_note = "登录 Cerebras Cloud，左侧「API Keys」创建。",
    openai_compatible = TRUE,
    supports_models_api = TRUE,
    # 官方 Model Catalog 当前**只有这两个**（其余要 Dedicated Inference）
    fallback_models = c("gpt-oss-120b", "qwen-3.8-27b"),
    note = paste0("⛔ 大陆直连被地区封锁（实测 Cloudflare error code 1009 ——",
                  "该码的含义就是「本站封禁了你所在的地区」），需先配代理。",
                  "它的文档站 inference-docs.cerebras.ai 倒是能直连。")
  ),

  # ---------------------------------------------------------------------------
  sambanova = list(
    label    = "SambaNova",
    aggregator = TRUE,
    base_url = "https://api.sambanova.ai/v1",
    key_url  = "https://cloud.sambanova.ai/apis",
    key_note = "登录 SambaNova Cloud 创建 API Key。",
    openai_compatible = TRUE,
    supports_models_api = TRUE,
    # 2026-10-04 实测 GET /models 返回 200、6 条，照抄（大小写敏感）
    fallback_models = c("DeepSeek-V3.2", "DeepSeek-V3.1",
                        "Meta-Llama-3.3-70B-Instruct", "MiniMax-M3",
                        "gemma-4-31B-it", "gpt-oss-120b"),
    note = paste0("✅ 大陆**可以直连**（实测）。",
                  "它的 /models **不用 Key 就能读**，所以上面那份清单也是现拉得到的。",
                  "模型名大小写敏感，照抄别改。")
  ),

  # ---------------------------------------------------------------------------
  fireworks = list(
    label    = "Fireworks AI",
    aggregator = TRUE,
    base_url = "https://api.fireworks.ai/inference/v1",
    key_url  = "https://app.fireworks.ai/settings/users/api-keys",
    key_note = "登录 Fireworks 控制台，在 API Keys 页创建。",
    openai_compatible = TRUE,
    supports_models_api = TRUE,
    fallback_models = character(0),
    note = paste0("⚠️ 地址里有 **inference** 那一段 —— ",
                  "实测 https://api.fireworks.ai/v1/models 返回的是 ",
                  "「Path not found」，是真实 404；旧写法别用。",
                  "✅ 大陆可以直连。",
                  "模型名很长，形如 accounts/fireworks/models/xxx，前缀不能省 —— ",
                  "以「获取模型」为准。")
  ),

  # ---------------------------------------------------------------------------
  together = list(
    label    = "Together AI",
    aggregator = TRUE,
    base_url = "https://api.together.ai/v1",
    key_url  = "https://api.together.xyz/settings/api-keys",
    key_note = "登录后在 Settings → API Keys 创建。",
    openai_compatible = TRUE,
    supports_models_api = TRUE,
    fallback_models = character(0),
    note = paste0("⛔ 大陆直连被 Cloudflare 地区封锁（实测 403），需先配代理。",
                  "⚠️ 官方文档已改用 api.together.ai，但官方 SDK 里默认还是旧的 ",
                  "api.together.xyz —— 两个域名都活着，别做严格校验。",
                  "模型清单以「获取模型」为准。")
  ),

  # ---------------------------------------------------------------------------
  perplexity = list(
    label    = "Perplexity",
    base_url = "https://api.perplexity.ai",
    key_url  = "https://www.perplexity.ai/settings/api",
    key_note = "登录后在 Settings → API 里创建。",
    openai_compatible = TRUE,
    # ⚠️ 这家的路径是**互斥**的：对话在**没有** /v1 的地址上，
    #    而 /v1/models 是另一套（Agent API）的口径 —— 写上去必然 404。
    supports_models_api = FALSE,
    fallback_models = c("sonar", "sonar-pro", "sonar-reasoning-pro",
                        "sonar-deep-research"),
    note = paste0("⚠️ 地址**不带 /v1**（对话路径就在根上）—— 加了 /v1 会 404。",
                  "这家的模型名是固定的几个 sonar 系列，所以静态清单是准的。",
                  "⛔ 大陆直连不通，需先配代理。")
  ),

  # ---------------------------------------------------------------------------
  # 国际 · 聚合平台
  openrouter = list(
    label    = "OpenRouter",
    aggregator = TRUE,
    base_url = "https://openrouter.ai/api/v1",
    key_url  = "https://openrouter.ai/settings/keys",
    key_note = "注册后在「Keys」页创建。",
    openai_compatible = TRUE,
    supports_models_api = TRUE,
    # 2026-10-04 实测 466 条。这里**故意只放它没对大陆封锁的那一类** ——
    # OpenAI / Anthropic / Google / xAI 的模型大陆用户调了会 403（见 note）。
    fallback_models = c("qwen/qwen3.8-max-prime", "z-ai/glm-5.3-flashx",
                        "xiaomi/mimo-v2.6-pro", "inclusionai/ling-3.1-flash"),
    note = paste0("聚合平台：一把 Key 调它上面几百个模型（实测 466 条）。",
                  "⚠️⚠️ 站点本身大陆能连，但它**按上游厂商的条款**对大陆/香港",
                  "用户**封了 OpenAI / Anthropic / Google / xAI 的模型** —— ",
                  "调这些会返回 403 Author Banned。清单里那几个是没封的类型。")
  ),

  # ---------------------------------------------------------------------------
  deepinfra = list(
    label    = "DeepInfra",
    aggregator = TRUE,
    base_url = "https://api.deepinfra.com/v1/openai",
    key_url  = "https://deepinfra.com/dash/api_keys",
    key_note = "登录后在控制台的 API Keys 页创建。",
    openai_compatible = TRUE,
    supports_models_api = TRUE,
    # 2026-10-04 实测 183 条，下面这几个是当天清单里的原文
    fallback_models = c("deepseek-ai/DeepSeek-V4.1-Flash", "Qwen/Qwen3.8-Max",
                        "Qwen/Qwen3.8-27B", "zai-org/GLM-5.3-Flash",
                        "anthropic/claude-opus-5", "google/gemini-3.7-flash",
                        "openai/gpt-oss-120b-Ultra",
                        "meta-llama/Meta-Llama-3.1-8B-Instruct-Turbo",
                        "nvidia/NVIDIA-Nemotron-3-Super-120B-A12B"),
    note = paste0("⚠️ 地址是 **/v1/openai**（两段，顺序和别家相反）。",
                  "✅ 大陆可以直连；/models **不用 Key 就能读**（实测 183 条）。",
                  "清单里还混着画图和向量化模型，只有能对话的才选。")
  ),

  # ---------------------------------------------------------------------------
  novita = list(
    label    = "Novita AI",
    aggregator = TRUE,
    base_url = "https://api.novita.ai/openai/v1",
    key_url  = "https://novita.ai/settings/key-management",
    key_note = "注册后在「Key Management」页创建。",
    openai_compatible = TRUE,
    supports_models_api = TRUE,
    # 2026-10-04 实测 121 条，下面这几个是当天清单里的原文
    fallback_models = c("deepseek/deepseek-v4-pro-0813", "deepseek/deepseek-v4-flash",
                        "moonshotai/kimi-k3", "zai-org/glm-5.3",
                        "qwen/qwen3.8-max", "minimax/minimax-m3",
                        "xiaomimimo/mimo-v2.6-pro", "stepfun/step-3.7-flash",
                        "tencent/hy3"),
    note = paste0("⚠️ 地址是 **/openai/v1**（旧写法 /v3/openai 别再用）。",
                  "✅ 大陆可以直连。它的 /models 会**把已退役的模型也列出来**，",
                  "所以清单只当参考，能不能调通以实际为准。")
  ),

  # ---------------------------------------------------------------------------
  nebius = list(
    label    = "Nebius Token Factory",
    aggregator = TRUE,
    base_url = "https://api.tokenfactory.nebius.com/v1",
    key_url  = "https://tokenfactory.nebius.com",
    key_note = "登录 Token Factory 控制台创建 API Key。",
    openai_compatible = TRUE,
    supports_models_api = TRUE,
    fallback_models = character(0),
    note = paste0("⚠️ 旧域名 api.studio.nebius.* 已废，用上面这个。",
                  "⚠️⚠️ **合规提醒**（不是网络问题）：Nebius 的制裁政策把中国",
                  "列入 High Risk Jurisdictions，用之前请自行确认你的账号合规。")
  ),

  # ---------------------------------------------------------------------------
  siliconflow_intl = list(
    label    = "硅基流动 SiliconFlow（国际站）",
    aggregator = TRUE,
    base_url = "https://api.siliconflow.com/v1",
    key_url  = "https://cloud.siliconflow.com/account/ak",
    key_note = "国际站注册后「账户管理 → API 密钥」创建。",
    openai_compatible = TRUE,
    supports_models_api = TRUE,
    fallback_models = character(0),
    note = paste0("⚠️ 和上面那个国内站是**两套账号**：Key / 余额 / 模型名都不互通，",
                  "别把国内站申请的 Key 填到这儿（会报鉴权失败）。")
  ),

  # ---------------------------------------------------------------------------
  bedrock = list(
    label    = "AWS Bedrock",
    aggregator = TRUE,
    base_url = "https://bedrock-mantle.ap-northeast-1.api.aws/v1",
    key_url  = "https://console.aws.amazon.com/bedrock/home#/api-keys",
    key_note = paste0("在 Bedrock 控制台创建 **API key**（形如 ABSK 开头），",
                      "不是 IAM 的 AK/SK。"),
    openai_compatible = TRUE,
    supports_models_api = TRUE,
    fallback_models = character(0),
    note = paste0("⚠️ 地址里的 **ap-northeast-1**（东京）是地域，",
                  "换成你开通的那个即可 —— 东京离国内最近。",
                  "走这个兼容接口**不用 SigV4 签名**，只要那把 ABSK Key 做 Bearer，",
                  "所以能直接用。✅ 大陆可以直连（实测）。")
  ),

  # ---------------------------------------------------------------------------
  huggingface = list(
    label    = "Hugging Face Inference",
    aggregator = TRUE,
    base_url = "https://router.huggingface.co/v1",
    key_url  = "https://huggingface.co/settings/tokens",
    key_note = "在 HF 的「Access Tokens」页建一个带推理权限的 token。",
    openai_compatible = TRUE,
    supports_models_api = TRUE,
    fallback_models = character(0),
    note = paste0("它是个**路由器**：一个地址转发到十几家推理服务商。",
                  "只支持对话，没有向量化接口。",
                  "⛔ 大陆直连不通，需先配代理。")
  ),

  # ---------------------------------------------------------------------------
  # 零一万物已经停服，默认从下拉框里排除（enabled = FALSE）。
  #
  # 留着这条记录而不是直接删掉，是因为一定会有用户拿着从旧文章抄来的
  # yi-lightning 来问为什么报错 —— 查得到"这家已经停了"比查不到要好。
  # dsapp_vendor() 对它的兜底行为也和别的厂商一致。
  yi = list(
    label    = "零一万物 Yi（已停服）",
    base_url = "",
    key_url  = "",
    key_note = "该平台已停止服务，无法申请。",
    openai_compatible = TRUE,
    supports_models_api = FALSE,
    fallback_models = character(0),
    enabled  = FALSE,
    note = paste0("⛔ 该厂商已停服，请勿选择。模型广场与 API 已于 2026-09-03 ",
                  "停止服务（接口返回 HTTP 410）。请改用 DeepSeek、通义千问等。"),
    deprecated = list(
      `yi-lightning` = list(to = "deepseek-flash",
                            why = "零一万物平台已停服，请改用其它厂商"),
      `yi-large`     = list(to = "deepseek-flash",
                            why = "零一万物平台已停服，请改用其它厂商")
    )
  ),

  # ---------------------------------------------------------------------------
  custom = list(
    label    = "自定义 / 中转代理",
    base_url = "",
    key_url  = "",
    key_note = paste0("任何 OpenAI 兼容的服务都行：填完整的 base_url（到 /v1 为止），",
                      "Key 填它要求的那串。"),
    openai_compatible = TRUE,
    supports_models_api = TRUE,
    fallback_models = character(0)
  )
)

# ---------------------------------------------------------------------------
# 查询
# ---------------------------------------------------------------------------

#' 取某个厂商的配置
#'
#' 未知厂商名兜底到 deepseek —— 宁可给一个能用的默认值，
#' 也不要让整页因为一个空指针白屏。
dsapp_vendor <- function(vendor) {
  # ⚠️ NULL / 空串要在这里挡掉，不能指望 [[ 自己处理。
  #
  # `DSAPP_MODEL_CATALOG[[NULL]]` 不是"取不到"，是**直接抛异常**：
  #     Error in ...[[NULL]] : attempt to select less than one element in get1index
  #
  # 谁会传 NULL 进来：Shiny 的 input$vendor 在**控件还没渲染出来**时就是
  # NULL。V5 之前主界面是静态 UI，所有控件一开始就在 DOM 里，所以 input$vendor
  # 从第一拍就有值，这个坑一直没露头。V5 把 app_ui 改成 uiOutput("app_root")
  # 之后（登录前渲染的是注册页），设置页的控件根本不存在，input$vendor 是
  # NULL —— 而 mod_settings_server 是照常注册并启动的，于是它的
  # observeEvent(model_choices()) 第一次跑就抛异常，整页变成
  # "An error has occurred"，连注册页都进不去。
  #
  # 语义上这也是对的：不认识的厂商名和没给厂商名，都该回落到默认厂商。
  if (is.null(vendor) || !length(vendor) || !nzchar(as.character(vendor)[1])) {
    return(DSAPP_MODEL_CATALOG$deepseek)
  }
  DSAPP_MODEL_CATALOG[[as.character(vendor)[1]]] %||% DSAPP_MODEL_CATALOG$deepseek
}

#' 厂商是不是启用状态
dsapp_vendor_enabled <- function(vendor) {
  isTRUE(dsapp_vendor(vendor)$enabled %||% TRUE)
}

#' 库里存的那个厂商名，**归一化成这一刻真正该用的那一个**（Test_V15.4 item 1）
#'
#' 存进去的时候是启用的，不代表现在还是 —— 比如某家停服时把 `enabled` 改成
#' 了 FALSE。那个名字直接拿去用有两个后果：下拉框的 `selected` 指向一个**不
#' 存在的选项**（控件显示空白），以及服务端以为"当前厂商 = 那家"，于是后面
#' 每一步都按一个已经不存在的前提走。
#'
#' ⚠️⚠️ 这个函数存在的**唯一**理由是：**UI 侧和服务端侧必须用同一个答案**。
#'    从前这条回落只写在 UI 里（`mod_model_ui()` 那两行），服务端读设置时
#'    照抄库里的原值 —— 于是两边不一致，而这不一致会自己长成一个破坏性动作：
#'
#'      控件里选中的是 "deepseek"（回落后的），state$vendor 是 "yi"（库里的）
#'      → 浏览器把 "deepseek" 报上来 → 切厂商 observer 认为**用户换了厂商**
#'        （oldv="yi" ≠ newv="deepseek"）→ dsapp_api_key_activate(uid,"deepseek")
#'      → deepseek 名下没有钥匙串行 → 那一支把 `users.llm_api_key` 写成 NULL。
#'
#'    用户什么也没干，Key 就没了，而且界面上看不出是谁干的。**别把这条回落
#'    再抄回任何一侧**，两边都调这个函数。
dsapp_vendor_active <- function(vendor) {
  v <- trimws(as.character(vendor %||% "")[1] %||% "")
  if (!nzchar(v)) return("deepseek")
  # ⚠️ `%in% names(...)` 这一句不能省。`dsapp_vendor_enabled()` 对**不认识的
  #    名字**返回 TRUE —— 它内部走 dsapp_vendor()，而那个函数对不认识的名字
  #    回落到 deepseek 的目录项（enabled = TRUE）。于是"目录里已经没有的厂商
  #    名"会原样通过这个判据，而它进不了下拉框的 choices → selectInput 的
  #    selected 指向一个不存在的选项 → **控件显示空白**。
  #    那正是用户说的"模型被去激活了"的样子，而库里的值看着完全正常。
  #    ⚠️ 这也修好了另一条更安静的路：`dsapp_vendor_base_url("不认识的")`
  #       拿到的是 deepseek 的地址，于是请求发到 deepseek、用的是别家的 Key。
  if (!v %in% names(DSAPP_MODEL_CATALOG)) return("deepseek")
  if (!dsapp_vendor_enabled(v)) return("deepseek")
  v
}

#' 厂商的 base_url
#'
#' override 非空时优先 —— 用户可能在设置页手改成了中转地址。
dsapp_vendor_base_url <- function(vendor, override = NULL) {
  if (!is.null(override) && nzchar(trimws(override %||% ""))) {
    return(sub("/+$", "", trimws(override)))
  }
  sub("/+$", "", dsapp_vendor(vendor)$base_url %||% "")
}

#' 厂商下拉框的选项
#'
#' 停服的厂商不进下拉框（选它只会得到 410）。
dsapp_vendor_choices <- function() {
  # ⚠️ 这里必须按**元素**判断，不能写成 vapply(目录, dsapp_vendor_enabled, ...)：
  # vapply 传给函数的是目录里的每个 list，而 dsapp_vendor_enabled() 收的是
  # 厂商名（字符串），会把 list 当成下标去索引，报
  # "invalid subscript type 'list'"。
  enabled <- vapply(DSAPP_MODEL_CATALOG,
                    function(v) isTRUE(v$enabled %||% TRUE), logical(1))
  keep <- names(DSAPP_MODEL_CATALOG)[enabled]
  labels <- vapply(DSAPP_MODEL_CATALOG[keep], function(v) v$label, character(1))
  stats::setNames(keep, labels)
}

#' 静态 fallback 模型清单
dsapp_vendor_models <- function(vendor) {
  dsapp_vendor(vendor)$fallback_models %||% character(0)
}

# ---------------------------------------------------------------------------
# 模型名的"原厂"归属（V13 item 7）
# ---------------------------------------------------------------------------
#
# 用户的原话：「千问AI平台是可以提供其它厂商的api接口的，可以在子菜单中优先
# 显示它自己的接口，同时也把所有选项提供出来。其它厂商有类似功能也请一并更新」。
#
# 说的是百炼 / 方舟 / 千帆 / TokenHub 这类**聚合平台**：一把 Key、一个地址，
# 既能调自家模型，也能调别家的。原来的模型下拉是**一个平铺的清单**，
# 于是有两个具体问题：
#
#   1. 自家的模型混在几十个名字里，最常用的那个反而要翻
#   2. 看不出「这个名字是谁家的」—— 用户在百炼里找 DeepSeek，心里想的是
#      "我要用 DeepSeek"，而界面上只有一串 deepseek-v3.1-250821 这样的名字
#
# 所以这个表只做一件事：**给一个模型名，说出它是谁家的**。据此把下拉分成
# 「本平台」+ 若干原厂组。
#
# ⚠️ 表是**按前缀**匹配的，而且是"先长后短"的顺序，不能随便调。
#    `^qwen` 和 `^qwq` 不冲突，但 `^hy` （混元）会和 `^hunyuan` 撞 —— 短的
#    那个必须排在长的后面，否则 hunyuan-turbos 会被归成 hy 那一组（结果一样，
#    但 `^gpt` 和 `^gpt-oss` 这种就会分错家）。
#    另外 `^o[0-9]` （OpenAI 的 o3/o4）写法很松，只放在最后兜底。
#
# ⚠️ 认不出来**不等于**要丢掉。见 dsapp_vendor_model_groups 的说明：认不出来
#    的落进「其它」，一律照常列出来。厂商上新模型的速度永远快过这张表。
DSAPP_MODEL_FAMILIES <- list(
  # 故意不锚定：别名和蒸馏版的名字里都带 deepseek
  # （deepseek-v3.1-250821、DeepSeek-R1-Distill-Qwen-7B 都要归到这家）
  list(pattern = "deepseek",        label = "DeepSeek 深度求索"),
  list(pattern = "^kimi|^moonshot", label = "Kimi 月之暗面"),
  list(pattern = "^glm|^charglm|^cogview|^cogvideo", label = "智谱 GLM"),
  list(pattern = "^minimax|^abab",  label = "MiniMax"),
  list(pattern = "^ernie|^wenxin",  label = "百度文心 ERNIE"),
  list(pattern = "^hunyuan|^hy[0-9-]", label = "腾讯混元 Hunyuan"),
  list(pattern = "^doubao|^seed[-_]?oss|^seed[0-9]", label = "字节豆包 Doubao"),
  list(pattern = "^step[-0-9]",     label = "阶跃星辰 StepFun"),
  list(pattern = "^baichuan",       label = "百川智能 Baichuan"),
  # ⚠️ spark 家那几个短名字（lite / max-32k）**不**放进这张表：
  #    它们太泛，会把别家的同名模型误判成讯飞的。讯飞自家的识别放在
  #    DSAPP_OWN_PATTERNS 里 —— 那里只在"就是讯飞这个厂商"的前提下才用得上。
  list(pattern = "^spark|^generalv", label = "讯飞星火 Spark"),
  list(pattern = "^llama|^meta-llama", label = "Meta Llama"),
  list(pattern = "^mistral|^mixtral|^codestral", label = "Mistral"),
  list(pattern = "^gemma|^gemini",  label = "Google Gemma / Gemini"),
  list(pattern = "^claude",         label = "Anthropic Claude"),
  list(pattern = "^gpt-|^gpt[0-9]|^chatgpt|^davinci|^text-embedding", label = "OpenAI"),
  list(pattern = "^o[1-9](-|$)",    label = "OpenAI o 系列"),
  list(pattern = "^qwen|^qwq|^qvq|^tongyi", label = "阿里通义千问 Qwen"),
  # ⚠️★ V16.3 item 1：下面这几家是补国际厂商时一起补的。它们全都是**原厂**，
  #    而原厂模型几乎只会以"别家模型"的身份出现在聚合平台（OpenRouter /
  #    DeepInfra / Novita …）的清单里 —— 那些平台的 DSAPP_OWN_PATTERNS 是空的，
  #    所以认得出来就不会掉进「其它」组。纯展示，认不出来也不会丢模型。
  #    冲突核对：^grok / ^command / ^sonar / ^nvidia / ^nova 与上面任何一条
  #    前缀都不重叠；^gpt-oss-120b 仍归 OpenAI（^gpt- 在前），不会跑到 NVIDIA 去。
  list(pattern = "^grok",           label = "xAI Grok"),
  list(pattern = "^nvidia|^nemotron", label = "NVIDIA Nemotron"),
  list(pattern = "^command|^c4ai|^north-", label = "Cohere"),
  list(pattern = "^sonar|^pplx",    label = "Perplexity"),
  list(pattern = "^nova|^titan",    label = "Amazon Nova / Titan"),
  # 下面几家是 2026-09-16 对着聚合平台的官方模型列表补的：它们只以
  # 「别家模型」的身份出现在百炼 / TokenHub 上，自家目录里没有。
  list(pattern = "^mimo",           label = "小米 MiMo"),
  list(pattern = "^unisound",       label = "云知声 Unisound"),
  list(pattern = "^internvl",       label = "上海 AI Lab InternVL"),
  list(pattern = "^bge-|^bce-|^tao-", label = "智源 BAAI 向量模型"),
  list(pattern = "^hyper3d|^hitem3d", label = "3D 生成（影眸 / 数美）")
)

#' 厂商自己部署 vs 原厂直供：百炼和 TokenHub 用 `前缀/` 区分
#'
#' 同一个模型在百炼上有两条链路，命名不同：百炼自己部署的是**裸名**
#' （`kimi-k3`），原厂或第三方推理商直供的是**带前缀**的（`kimi/kimi-k3`、
#' `ZHIPU/GLM-5.3`、`siliconflow/deepseek-v3.2`）。前缀值就是官方的
#' `inference_providers` 枚举。TokenHub 上只有 DeepSeek 一家是这种写法
#' （`deepseek/deepseek-flash`）。
#'
#' 分组时前缀本身不参与「这是谁家的模型」的判断 —— 决定原厂的是斜杠后面
#' 那一段。不剥掉的话 `ZHIPU/GLM-5.3` 会落到「其它」去：`^glm` 匹配不上
#' 以 `zhipu/` 开头的字符串，而它明明是智谱的。
dsapp_model_strip_provider <- function(name) {
  nm <- as.character(name %||% "")[1]
  # 只剥**一层**、且斜杠两边都不为空。`deepseek/` 这种尾巴上没东西的
  # 名字（真出现过）剥完会变成空串，那还不如不剥。
  sub("^[^/]+/(.+)$", "\\1", nm)
}

#' 一个模型名是谁家的
#'
#' @return 家族名（字符串）；认不出来返回 NULL。**认不出来不是错误** ——
#'         调用方必须把它照常列出来，见 dsapp_vendor_model_groups。
dsapp_model_family <- function(name) {
  nm <- tolower(trimws(dsapp_model_strip_provider(name)))
  if (!nzchar(nm)) return(NULL)
  for (f in DSAPP_MODEL_FAMILIES) {
    if (grepl(f$pattern, nm)) return(f$label)
  }
  NULL
}

#' 厂商自己的模型名长什么样（用来把"自家的"从聚合清单里挑出来）
#'
#' 聚合平台的 /models 返回的是**一个大杂烩**，里面既有自家的也有别家的。
#' 这张表说得出"哪些名字是它自家的"，剩下的按 dsapp_model_family 归堆。
#'
#' ⚠️ 认不出来的一律**当成别家的**，因为自家的名字在 fallback_models 里
#'    一定列过（那是这家平台的主推清单）。反过来判会让别家的模型跑到
#'    「本平台」组里去，比漏判更误导。
#' 聚合平台上**别家**的模型（静态占位）
#'
#' ⚠️ 这几个名字是**占位**，和 fallback_models 是同一个性质：模型名是厂商随时
#'    会改的东西，写死在代码里必然过期。点一次「获取模型」拿回来的活清单会
#'    整个替换掉它（见 mod_model.R 的 model_choices()），所以这里的价值只有
#'    一个 —— 用户刚填完 Key、还没点那个按钮时，下拉里就能看出"这个平台
#'    不止有自家的模型"，而不是一片清一色的 qwen-*。
#'
#'    和 fallback_models 的区别是**给的顺序**：自家的排在前面，这些排在后面
#'    按原厂分堆。名字直接沿用对应厂商目录里当前推荐的那个，免得同一个模型
#'    在应用里有两个写法。
#' ★ 下面这些名字是 2026-09-16 对着四家的官方文档逐条核过的（不是博客、
#'   不是记忆）。四条最容易踩的规律，改这张表之前先读一遍：
#'
#'   1. **同一个模型，四家的字符串全不一样，绝不能跨平台抄。**
#'      同一个 DeepSeek V4 Pro：百炼 `deepseek-v4-pro`、方舟
#'      `deepseek-v4-pro-ga-260813`、TokenHub `deepseek-v4-pro`（另有
#'      `deepseek/deepseek-v4-pro` 的原厂直供档）、千帆 `deepseek-v4-pro`。
#'   2. **只有百炼用 `厂商/` 前缀表示「原厂直供」**（`kimi/kimi-k3`、
#'      `ZHIPU/GLM-5.3` —— 注意 ZHIPU 是全大写），前缀**不是**可选装饰，
#'      漏掉会拿到 InvalidModelId。TokenHub 只在 DeepSeek 一家上用
#'      `deepseek/` 前缀。方舟和千帆是纯裸名。
#'   3. **Kimi / MiniMax / 阶跃星辰只有百炼和 TokenHub 上有**，方舟和千帆
#'      都查不到 —— 别想当然地给它们也补一个。
#'   4. **Llama 和零一万物四家都不要写**：百炼那边已下线（限流页 RPM=0）、
#'      方舟 2025 年就关停了、千帆只在 V1 时代有过、TokenHub 从来没有。
DSAPP_RESOLD_MODELS <- list(
  # 阿里云百炼：四家里聚合度最高的，13 个第三方入口
  qwen = c(
    # DeepSeek：百炼自己部署的裸名 + 硅基流动/快手万擎直供的带前缀版
    "deepseek-v4-pro", "deepseek-v4-flash", "deepseek-v4.1-flash",
    "deepseek-v3.2", "deepseek-v3.1", "deepseek-r1",
    "siliconflow/deepseek-v3.2", "vanchin/deepseek-v4-pro",
    # Kimi：裸名是百炼部署，kimi/ 前缀是月之暗面直供
    "kimi-k3", "kimi-k2.7-code", "kimi-k2.6", "kimi/kimi-k3",
    # 智谱：裸名 vs ZHIPU/ 前缀是两个不同商品，价格和限流都不一样
    "glm-5.3", "glm-5.2", "glm-5.1", "glm-4.5-air", "ZHIPU/GLM-5.3",
    # MiniMax
    "MiniMax-M2.5", "MiniMax-M2.1", "MiniMax/MiniMax-M3",
    # 小米 MiMo、阶跃星辰、云知声：都只有直供的带前缀版
    "xiaomi/mimo-v2.5-pro", "stepfun/step-3.7-flash", "unisound/unisound-u2"
  ),
  # 火山方舟：标准 API 链路上的第三方只有深度求索和智谱两家。
  # ⚠️ 方舟的 model id **带日期后缀**，而且没有无日期的别名 ——
  #    无日期那种只出现在订阅套餐（Coding Plan）文档里，官方明文说
  #    「不可用于 API 调用」。所以这里一个别名都不要写。
  doubao = c(
    "deepseek-v4-pro-ga-260813", "deepseek-v4-flash-ga-260731",
    "deepseek-v4-pro-260425", "deepseek-v4-flash-260425",
    "deepseek-v4-1-flash-260910",
    "glm-5-3-flash-260828", "glm-5-2-260617"
  ),
  # 腾讯 TokenHub：四家里最"干净"的聚合 —— 所有模型同一组 Base URL，
  # 只换协议路径和 model。DeepSeek 有腾讯托管（裸名）和原厂直供
  # （`deepseek/` 前缀）两档，同格并列。
  hunyuan = c(
    "deepseek-v4-pro", "deepseek-v4-flash",
    "deepseek/deepseek-v4-pro", "deepseek/deepseek-flash",
    "kimi-k3", "kimi-k2.7-code", "kimi-k2.6",
    "glm-5.3", "glm-5.3-flash", "glm-5.2", "glm-5-turbo",
    "minimax-m3", "minimax-m2.7",
    "mimo-v2.5-pro"
  ),
  # 百度千帆：走 /v2 接口（V1 已于 2026-08-31 下线，ernie-4.0-8k 那批
  # 旧名字全部作废）。⚠️ 官方有两个「模型列表」页且互相打架，这里按
  # 2026-09-14 那版录的；真机上以 GET /v2/models 为准。
  # ⚠️ 千帆**没有** MiniMax —— 2026-07-09 就退役了，别再补。
  ernie = c(
    "deepseek-v4-pro", "deepseek-v4-pro-0813", "deepseek-v4-flash-0731",
    "deepseek-flash", "deepseek-ocr",
    "glm-5.3", "glm-5.3-flash", "glm-5.2", "glm-5.1",
    "kimi-k2.6",
    # 千帆转售的阿里 Qwen（会归到「阿里通义千问」那一堆里去）
    "qwen3.5-397b-a17b", "qwen3.5-27b"
  )
)

DSAPP_OWN_PATTERNS <- list(
  qwen    = "^qwen|^qwq|^qvq|^tongyi",
  doubao  = "^doubao|^seed[-_]?oss|^seed[0-9]|^skylark",
  ernie   = "^ernie|^wenxin",
  hunyuan = "^hunyuan|^hy[0-9-]",
  zhipu   = "^glm|^charglm|^cogview|^cogvideo",
  deepseek = "^deepseek",
  moonshot = "^kimi|^moonshot",
  minimax = "^minimax|^abab",
  stepfun = "^step[-0-9]",
  baichuan = "^baichuan",
  spark   = "^spark|^generalv|^4\\.0ultra|^max-32k|^lite$"
)

#' 这家厂商是不是"聚合平台"（一把 Key 能调别家的模型）
#'
#' 只用来决定设置页要不要多写一句说明。**不**影响任何可用性判断 ——
#' 猜错了最多是少一句提示，不会让人调不动模型。
dsapp_vendor_is_aggregator <- function(vendor) {
  isTRUE(dsapp_vendor(vendor)$aggregator)
}

#' 模型下拉的分组候选（本平台排第一组）—— V13 item 7
#'
#' 返回的形状直接就是 selectInput / selectizeInput 的 optgroup 入参：
#' 具名 list，名字是组标题，值是该组的模型名向量。没有的组不出现。
#'
#' @param vendor 厂商名
#' @param live   厂商 /models 接口返回的**活**清单；NULL / 空表示没拉到，
#'               退回目录里的静态清单。
#'
#' ⚠️ **一个模型名都不能丢**。
#'
#'    活清单是厂商当下真的给你用的东西，比目录里的静态清单权威。分组规则
#'    认不出来某个名字时（厂商新上的、或者名字改过），它落进「其它」组，
#'    而不是被过滤掉。丢掉的表现是"设置页里找不到我刚开通的那个模型"，
#'    而用户唯一的出路是手打模型名 —— 一个纯粹由展示逻辑造出来的坑。
dsapp_vendor_model_groups <- function(vendor, live = NULL) {
  v <- dsapp_vendor(vendor)
  flat <- as.character(live %||% character(0))
  flat <- flat[nzchar(flat)]
  if (!length(flat)) {
    # 没拿到活清单 —— 自家的 + 这个平台转售的别家模型（占位）。
    # 转售的那些只在这里补，活清单回来的话**不补** —— 那时候厂商自己说的
    # 才算数，凭代码里的猜测往候选里塞一个它其实没有的模型，用户选中后
    # 拿到的是 404。
    flat <- unique(c(as.character(v$fallback_models %||% character(0)),
                     as.character(DSAPP_RESOLD_MODELS[[as.character(vendor)[1]]]
                                  %||% character(0))))
  }
  if (!length(flat)) return(list())

  # ⚠️ 判"是不是自家的"之前先剥掉 `前缀/`。带前缀的名字按定义就是**别家
  #    直供**的（见 dsapp_model_strip_provider），拿它去比自家模式不仅
  #    可能误判，而且方向是反的：把 `qwen/xxx` 这种报成"本平台"。
  #    另外剥完再比也更稳 —— 自家模式写的是 `^qwen`，而百炼的活清单里
  #    自家的名字确实都是裸名，两边一致。
  bare <- vapply(flat, dsapp_model_strip_provider, character(1),
                 USE.NAMES = FALSE)
  own_pat <- DSAPP_OWN_PATTERNS[[as.character(vendor)[1]]]
  is_own <- if (is.null(own_pat)) rep(FALSE, length(flat))
            else grepl(own_pat, tolower(bare))

  own <- flat[is_own]
  rest <- flat[!is_own]

  out <- list()
  if (length(own)) {
    # 「（本平台）」只在**真的有别家可比**的时候才加。只有一组的时候加这个
    # 后缀是纯噪音 —— DeepSeek 那家的下拉里写「DeepSeek 深度求索（本平台）」
    # 会让人以为还有别的组可以选。
    lbl <- v$own_label %||% v$label %||% "本平台"
    if (length(rest)) lbl <- sprintf("%s（本平台）", lbl)
    out[[lbl]] <- own
  }
  if (length(rest)) {
    # 按原厂归堆，**保持厂商给的原始顺序** —— 同一家的模型顺序通常有意义
    # （新的在前、贵的在前），重排会把这个信息抹掉。
    fam <- vapply(rest, function(x) dsapp_model_family(x) %||% "其它", character(1))
    for (f in unique(fam)) out[[f]] <- rest[fam == f]
  }
  out
}

#' 分组候选拍平成一个向量（校验"这个名字在不在候选里"用）
dsapp_model_groups_flat <- function(groups) {
  as.character(unlist(groups, use.names = FALSE) %||% character(0))
}

#' 这家厂商支持 /models 接口吗
dsapp_vendor_has_models_api <- function(vendor) {
  isTRUE(dsapp_vendor(vendor)$supports_models_api)
}

#' 这家厂商支持思考模式开关 / 思考强度吗
#'
#' 目前只有 DeepSeek 在 OpenAI 兼容格式下提供了 thinking 和 reasoning_effort
#' 两个参数。别家调了会被忽略（有的还会报 400），所以设置页要据此隐藏控件。
dsapp_vendor_supports_thinking <- function(vendor) {
  isTRUE(dsapp_vendor(vendor)$supports_thinking)
}

# ---------------------------------------------------------------------------
# 已下线的模型名
# ---------------------------------------------------------------------------

#' 这个模型名是不是已经下线了
#'
#' 命中就返回 list(to = 替代模型, why = 原因)，没命中返回 NULL。
#' 设置页在用户手填模型名时调它 —— 从旧教程里抄 deepseek-chat 的人不少，
#' 直接告诉他换哪个，比让他对着 400 报错猜要好。
dsapp_model_deprecated <- function(vendor, model) {
  dep <- dsapp_vendor(vendor)$deprecated
  if (is.null(dep) || !nzchar(trimws(model %||% ""))) return(NULL)
  dep[[trimws(model)]]
}

#' 把一个过期的模型名换成现在能用的
#'
#' 用户在浏览器里存着 deepseek-chat、或者从旧笔记里粘过来，直接发请求必然报错。
#' 能确定替代品时就替他换掉，并在界面上说明换成了什么 —— 比让他对着一个
#' 必然失败的请求发呆要好。
#'
#' @return list(model = 可用的模型名, changed = 是否换过, why = 换的理由)
dsapp_model_migrate <- function(vendor, model) {
  model <- trimws(model %||% "")
  if (!nzchar(model)) {
    fb <- dsapp_vendor_models(vendor)
    return(list(model = if (length(fb)) fb[[1]] else "", changed = FALSE,
                why = ""))
  }
  hit <- dsapp_model_deprecated(vendor, model)
  if (is.null(hit) || !nzchar(hit$to %||% "")) {
    return(list(model = model, changed = FALSE, why = ""))
  }
  list(model = hit$to, changed = TRUE,
       why = sprintf("「%s」%s，已自动改用「%s」。", model, hit$why, hit$to))
}

#' 全部厂商里，这个模型名是不是已下线的
#'
#' 不知道厂商时用，给一个笼统的提示。
dsapp_model_deprecated_any <- function(model) {
  model <- trimws(model %||% "")
  if (!nzchar(model)) return(NULL)
  for (nm in names(DSAPP_MODEL_CATALOG)) {
    hit <- dsapp_model_deprecated(nm, model)
    if (!is.null(hit)) {
      return(sprintf("%s：%s", DSAPP_MODEL_CATALOG[[nm]]$label,
                     hit$why %||% "已下线"))
    }
  }
  NULL
}

# ---------------------------------------------------------------------------
# 思考模式 / 温度
# ---------------------------------------------------------------------------

#' 温度在这个组合下还生效吗
#'
#' ⚠️ 这个函数的语义在 2026-09 变过一次，值得写清楚。
#'
#' V2 时代的理解是"deepseek-reasoner 忽略 temperature"，其它模型能用。
#' 核对当前官方文档后实际情况是：
#'
#'   * DeepSeek 现在**默认就开思考模式**（thinking.type 默认 enabled，
#'     reasoning_effort 默认 high）
#'   * 官方原文：「思考模式不支持 temperature、presence_penalty、
#'     frequency_penalty 参数。请注意，为了兼容已有软件，设置参数不会报错，
#'     但也不会生效。」
#'
#' 也就是说，**在当前 DeepSeek 的默认设置下，温度滑块是完全无效的**。
#' 与其让用户拖半天发现没反应，不如直接灰掉，并把真正管用的那个旋钮
#' （reasoning_effort）摆出来。
#'
#' @param thinking 用户当前是不是开着思考模式
#' @param model    当前选中的模型名。判断"这个模型能不能调温度"要用它 ——
#'   同一条规则在不同模型上不一样，见 dsapp_model_temp_locked()。
dsapp_temperature_active <- function(vendor, thinking = TRUE, model = NULL) {
  # 只接受 temperature = 1 的模型：拖了也没有任何效果，滑块直接灰掉。
  # 放在最前面判：这类模型的"不能调"和思考模式无关，关掉开关也一样。
  if (dsapp_model_temp_locked(model)) return(FALSE)
  if (dsapp_vendor_supports_thinking(vendor)) {
    return(!isTRUE(thinking))
  }
  # 不支持思考模式的厂商：温度照常生效
  TRUE
}

# ---------------------------------------------------------------------------
# 只接受 temperature = 1 的模型
# ---------------------------------------------------------------------------

#' 哪些模型名属于"温度锁死在 1"的那一类
#'
#' ⚠️ 2026-09-16 线上报错换来的：
#'
#'     HTTP 400：invalid temperature: only 1 is allowed for this model
#'
#'   用户配的是月之暗面的 Key，界面上「测试连接」（列模型）却是**通过**的 ——
#'   因为那一步只发 GET /models，根本不带 temperature。一发真消息就 400。
#'   "能测通"和"能聊天"是两件事，这条规则补的正是它们之间的那道缝。
DSAPP_TEMP_LOCKED1 <- "^kimi|^moonshot"

#' 这个模型是不是只接受 temperature = 1
#'
#' ⚠️ 规则是**按模型**的，不是按厂商的。别写成"月之暗面不支持温度"：
#'    同一家不同代的模型规则不一样（moonshot-v1-* 那一代是能调温度的），
#'    以后还会变。按厂商一刀切，换个模型就错。
#'
#' ⚠️ 宁滥勿缺 —— 判错的代价是不对称的：
#'    * 把能调温度的模型误判成"锁死"：我们只是**不发**这个字段，服务端用
#'      它自己的默认值，请求照样成功，用户少一个旋钮而已；
#'    * 把锁死的模型误判成"能调"：用户一发消息就是 400，功能整个不能用。
#'    所以模式写得偏宽（`^kimi` 把 kimi 全家都罩上），而不是逐个模型列名单。
#'
#' ⚠️ 认的是**去掉 `厂商/` 前缀之后**的名字：聚合平台上转售的叫
#'    `kimi/kimi-k3`、`siliconflow/deepseek-v3.2`，前缀不是模型名的一部分
#'    （见 dsapp_model_strip_provider 的说明）。
dsapp_model_temp_locked <- function(model) {
  nm <- tolower(trimws(dsapp_model_strip_provider(model %||% "")))
  if (!nzchar(nm)) return(FALSE)
  grepl(DSAPP_TEMP_LOCKED1, nm)
}

# ---------------------------------------------------------------------------
# 生成参数的取值范围（V13.6 item 3）
# ---------------------------------------------------------------------------
#
# 用户的原话：「参数范围也需要自适应，避免输入不适用参数值的全款」。
# （「全款」是「情况」的同音错字。）
#
# ---- 改之前是什么样 ----
#
# 温度滑块和长度上限的 min/max **写死在 mod_model.R 的 UI 里**
# （0 ~ 1.5 / 512 ~ 65536），和厂商、模型没有半点关系。于是换一家厂商，
# 滑块量程一个字都不变：用户既看不出"这家支持到多少"，也没有任何东西
# 拦着他填一个越界的值 —— 唯一会告诉他的是发出去之后服务端回的 400，
# 而那条报错里通常只有一句 "invalid max_tokens"，指不到设置页的哪一格。
#
# ---- 现在的规矩 ----
#
# 范围按 **默认 → 厂商 → 模型** 三层叠出来：默认档管住"谁都没配"的情形，
# 厂商档按厂商收窄，模型档用模式匹配覆盖前两层（**后匹配的赢**，所以特例
# 写在后面）。UI 照着算出来的范围渲染控件，值在写进 state（= 真正发请求
# 时读的那个）之前再夹一次。
#
# 夹两次是有意的，两次管的不是一件事：
#   * 控件那一次是**提示** —— 滑块的量程就是范围，用户拖不到外面去；
#   * state 那一次是**保证** —— numericInput 的 min/max 只是浏览器侧的
#     校验，挡住不粘贴/不手打，更挡不住"改了范围之后还留着旧值"。
#
# ---- ⚠️ 表里为什么这么空 ----
#
# 只写**有出处**的数字。默认档就是应用从 V7 起一直在用的那一套，所以
# "表里查不到"= 行为逐字不变，不会因为加了这张表而悄悄改掉谁的量程。
#
# 厂商档空着**不是没做完**：某一家到底支持到多少，我没有可靠出处，与其
# 编一个看着专业的数字，不如让默认值继续生效。要收窄某一家，加一行就行
# —— 这是这张表存在的全部意义：
#
#     DSAPP_VENDOR_PARAMS$moonshot <- list(max_tokens = list(max = 32768))
#
# 按模型收窄同理（模式匹配的是**剥掉 `厂商/` 前缀**之后的小写名字）：
#
#     DSAPP_MODEL_PARAM_RULES <- list(
#       list(pattern = "^glm-4-9b", params = list(max_tokens = list(max = 8192))))
# =============================================================================
# ★★ V15.5 item 6：「单次使用上限」—— 一次请求总共能用多少 token
# =============================================================================
#
# 用户原话：「那不需要限制单次回复长度了，弄一个限制单次使用token的长度吧」。
#
# 改之前那一格叫「单次回复上限」，管的是 `max_tokens`（这一轮**回复**最多吐
# 多少 token）。它和"这次请求能带多少历史进去"是**两个量**，而后者在代码里
# 根本没有被建模：R/llm.R 的 `dsapp_build_context(hist, budget = 48000L)`
# 是一个写死的**字符**预算，调用点连厂商/模型都没传。
#
# 现在换成一个数：**一次请求（上下文 + 回复）合计最多用多少 token**。
# 它同时决定两件事，所以两者不可能对不上：
#   · 带多少历史进去 —— 见 R/llm.R 的 dsapp_build_context()；
#   · 这一轮回复最多多长 —— 上限减去实际带进去的，见下面的
#     dsapp_ctx_out_tokens()。
#
# ⚠️ 「回复长度不再单独设限」的意思**不是**把 max_tokens 设成一个很大的数：
#    总预算是个和，回复那一半必须是"剩下的额度"，否则两边各自都没超、加起来
#    超了上下文窗口 —— 而厂商拒的是整个请求，报的错还指向 max_tokens。
#
# ---- 跟随模型 --------------------------------------------------------------
#
# `DSAPP_CTX_FOLLOW`（0）是**默认值**，意思是"不用我设，按这个模型自己的
# 窗口来"。用户填了具体数字才盖掉它。界面上那一格留空 = 跟随。
#
# ⚠️ 哨兵取 0 而不是 NA，理由和 DSAPP_MAXTOK_UNLIMITED 一模一样（见那一节）：
#    这个值会被一路传到请求体、写进脱离会话的快照、在提示词里被格式化，NA
#    在每一处都有各自不同的退化行为，而 0 是一条判据走遍全部下游。
DSAPP_CTX_FOLLOW <- 0L

#' 上下文窗口：**模型本身的能力**（token）
#'
#' ⚠️ 这张表和 DSAPP_VENDOR_PARAMS 一样，**只写有出处的数字**。写错一个偏大的
#'    值，症状不是"报错"，是用户的合法请求被我们自己拦下（预算撑不到窗口，
#'    历史被悄悄丢掉）。所以查不到就退回 DSAPP_CTX_DEFAULT，那个数**不是能力**，
#'    是"我们不敢再往上猜"的保守值 —— 学到的真值（见下）会盖掉它。
DSAPP_CTX_DEFAULT <- 131072L   # 128K：查不到出处时的保守默认

# 一次回复至少要能写多少 token。它是 dsapp_ctx_out_tokens() 的下限，也是
# dsapp_ctx_out_reserve() 的下限 —— 定义在这里是因为下面两个函数都用它，
# 而它必须在**任何调用发生之前**就已经赋值。
#
# ⚠️ 它是个**理想值**，不是硬地板：窗口比 2*2048 还小时，照着它留就是"回复
#    额度比总量还大"，`out + used ≤ limit` 当场破掉。真正的下限是
#    dsapp_ctx_min_out(limit) = min(这个数, limit/2)，两个函数都走它。
DSAPP_CTX_MIN_OUT <- 2048L

# 用户能设的**最小**单次使用上限。
#
# ⚠️ 为什么不是 1024（滑块原来那一档）：低于这个数，"总量 = 历史 + 回复"
#    这条等式根本无解 —— 光系统提示就好几千 token，留给回复的额度会被压到
#    dsapp_ctx_min_out() 的地板上，于是 `out + used ≤ limit` 当场破掉。破了
#    的症状不是报错，是**每一次**请求都被厂商 400，用户以为是自己填错了。
#    4096 是让那条等式在所有下游都解得开的下界（回复至少 2048、历史至少
#    1792 字符），不是一个"看起来好看"的数。
DSAPP_CTX_MIN_TOTAL <- 4096L

DSAPP_CTX_VENDOR <- list(
  # DeepSeek 是唯一一家在**本仓注释里就有出处**的：R/models.R:30 写着
  # 「deepseek-flash（模型版本 DeepSeek-V4.1-Flash，1M 上下文）」，
  # R/llm.R:517 也写着同一句，用户 2026-09-30 第 6 条又确认了一次。
  deepseek = 1048576L
)

# 模型级覆盖（pattern 匹配剥掉 `厂商/` 前缀之后的小写名，同 dsapp_param_range）。
# 故意空着：现在没有第二个有出处的窗口值，编一个只会让预算莫名其妙地缩水。
DSAPP_CTX_MODELS <- list()

dsapp_context_window <- function(vendor, model = NULL) {
  v <- tolower(trimws(as.character(vendor %||% "")[1] %||% ""))
  nm <- tolower(trimws(dsapp_model_strip_provider(model %||% "")))
  w <- NULL
  if (nzchar(nm) && length(DSAPP_CTX_MODELS)) {
    for (rule in DSAPP_CTX_MODELS) {
      if (!is.character(rule$pattern) || length(rule$pattern) != 1L) next
      if (!grepl(rule$pattern, nm)) next
      w <- rule$window
    }
  }
  if (is.null(w)) w <- DSAPP_CTX_VENDOR[[v]]
  w <- suppressWarnings(as.numeric(w %||% NA_real_)[1])
  if (!is.finite(w) || w < 1024) w <- DSAPP_CTX_DEFAULT
  as.numeric(w)
}

#' 这个值是不是「跟随模型」
#'
#' ⚠️ **NULL 算**（和 dsapp_maxtok_is_unlimited 刻意相反）。那里 NULL 是"还没
#'    设过"，该用默认档；这里的默认档就是"跟随模型"，两者是同一件事。
dsapp_ctx_is_follow <- function(x) {
  if (is.null(x) || length(x) == 0L) return(TRUE)
  x <- suppressWarnings(as.numeric(x[1]))
  !is.finite(x) || x <= 0
}

#' 「跟随模型」时学到的窗口（厂商在 400 里说的那句）
#'
#' 复用 model_param_limits 那张表，param 写 "context_length"。查不到就 NULL。
dsapp_context_learned <- function(vendor, model = NULL) {
  lr <- tryCatch(dsapp_param_learned_get(vendor, model, "context_length"),
                 error = function(e) NULL)
  if (!is.list(lr)) return(NULL)
  v <- suppressWarnings(as.numeric(lr$max %||% NA_real_)[1])
  if (!is.finite(v) || v < 1024) return(NULL)
  as.numeric(v)
}

#' 这一次请求总共能用多少 token
#'
#' @param want 用户在「模型服务」页填的数；0/NULL = 跟随模型
#' @return 一个正数。**永远有值** —— 下游（预算、读条的分母）都需要一个分母。
dsapp_ctx_limit <- function(vendor, model = NULL, want = NULL) {
  # ⚠️ 三条路最后都过一遍 DSAPP_CTX_MIN_TOTAL。理由不是"厂商没有这么小的
  #    窗口"，而是**我们自己那套算术在它下面解不开**（见那个常量的说明）。
  #    真遇上一个 2K 窗口的模型，我们宁可发一个 4096 的请求让它 400 ——
  #    那时 item 7 会当场把厂商的原话摆给用户看；而按 2K 去算，症状是
  #    每一次请求都超限、每一句报错都指向 max_tokens，谁也看不出是我们算的。
  max(DSAPP_CTX_MIN_TOTAL,
      if (dsapp_ctx_is_follow(want)) {
        dsapp_context_learned(vendor, model) %||%
          dsapp_context_window(vendor, model)
      } else {
        as.numeric(want[1])
      })
}

#' 估算一段文本占多少 token
#'
#' ⚠️ 这是**估算**，不是分词。写这个函数而不是直接 `nchar`，是因为中文一个字
#'    大约就是一个 token，而英文是四个字符一个 —— 只用字符数的话，一篇中文
#'    报告会被低估成三分之一，读条和"还能不能塞下"全都会算错。
#'    界面上必须写成「≈」，见 R/mod_chat.R 里读条那段。
dsapp_ctx_token_est <- function(text) {
  if (is.null(text) || !length(text)) return(0)
  s <- paste(as.character(text), collapse = "")
  if (!nzchar(s)) return(0L)
  # CJK（含中文标点、全角符号）按 1 字 1 token，其余按 4 字符 1 token。
  n_cjk <- nchar(gsub("[^一-鿿　-〿＀-￯]", "",
                      s, perl = TRUE))
  n_oth <- nchar(s) - n_cjk
  as.integer(ceiling(n_cjk + n_oth / 4))
}

#' 给**回复**留多少 token
#'
#' 从单次使用上限里先划出这一块，剩下的才是历史能占的。
#'
#' ⚠️ 它是**一半，但有上下限**，不是"上限的一半"那么简单：
#'    · 下限 DSAPP_CTX_MIN_OUT：无论窗口多小，回复总得有地方写。一个 8K 的
#'      窗口如果按比例只留 2K 给回复，模型连一句完整的分析结论都写不完，
#'      表现是"每次都被截断"，而用户看不出是预算算的。
#'    · 上限 DSAPP_CTX_OUT_CAP：窗口 1M 时按比例要留 512K —— 没有意义。
#'      一次回复写不了十几万字，留那么多只是把历史预算白白砍掉一半。
#'      65536 和改这个之前 max_tokens 的默认档是同一个数。
DSAPP_CTX_OUT_CAP <- 65536L

#' 回复额度的**真实下限**：理想下限和总量的一半，取小的那个
#'
#' ⚠️ 少了 `min(..., lim/2)` 这一半，`out + used ≤ limit` 在小窗口上是假的：
#'    总量 1024 时按 DSAPP_CTX_MIN_OUT 留 2048，回复额度比总量还大 —— 而这
#'    恰恰是这个改动**唯一**要保证的事。界面上滑块允许拖到 1024，所以这条
#'    路是活的，不是理论值。
dsapp_ctx_min_out <- function(limit) {
  lim <- suppressWarnings(as.numeric(limit %||% NA_real_)[1])
  if (!is.finite(lim) || lim <= 0) return(DSAPP_CTX_MIN_OUT)
  as.integer(max(1L, min(DSAPP_CTX_MIN_OUT, floor(lim / 2))))
}

dsapp_ctx_out_reserve <- function(limit) {
  lim <- suppressWarnings(as.numeric(limit %||% NA_real_)[1])
  if (!is.finite(lim) || lim <= 0) return(DSAPP_CTX_OUT_CAP)
  as.integer(max(dsapp_ctx_min_out(lim),
                 min(DSAPP_CTX_OUT_CAP, floor(lim / 2))))
}

#' 字符预算 → 留多少字符给历史
#'
#' ⚠️ 这个数必须是 dsapp_ctx_token_est() 的**上界**，不是"典型值"。
#'    1.0 的意思是"一个字符最多算一个 token" —— 那是估算器的上界（CJK 1 字
#'    1 token，其余 4 字符 1 token，所以 token ≤ 字符永远成立）。按它算出来的
#'    预算，同一个估算器再算一遍**一定**装得下，`out + used ≤ limit` 才是真的。
#'
#'    ⚠️⚠️ 这里原来写的是 1.6（"中英混排的经验比"）。经验比不是上界：一篇
#'    纯中文的报告，按 1.6 算出来的字符预算，估算 token 是预算的**1.6 倍**，
#'    也就是窗口的 1.6 倍 —— 每一次请求都超限，而症状看起来像厂商的错。
#'    代价是英文对话少带一点历史（1.6 → 1.0 就是少带 37%），但在 128K 的
#'    默认窗口上仍有 65472 字符 ≈ 一万六千英文 token 的历史，够用；而"少带
#'    几轮历史"远比"整个请求被 400、用户一个字都看不到"轻。
#' ⚠️ 这里**没有**"最少 48000 字符"那种下限。原来是有的，那是对的（当时
#'    budget 写死就是这个数）；现在预算由窗口推出来，再加一个地板就等于
#'    "不管厂商说自己多大，我们都至少发 48000 字符" —— 在一个 8K 窗口的
#'    模型上，这一条会让**每一次**请求都超限，而且看起来像是厂商的错。
DSAPP_CTX_CHARS_PER_TOKEN <- 1.0

# 估算器每条消息都会 `ceiling()`（最多多算 1 个 token），留一点余量给它。
# 不留的话，`out + used ≤ limit` 会在"刚好塞满"时差出几条消息那么多个 token。
DSAPP_CTX_BUDGET_SLACK <- 256L

dsapp_ctx_char_budget <- function(limit, out_reserve) {
  lim <- suppressWarnings(as.numeric(limit %||% NA_real_)[1])
  if (!is.finite(lim) || lim <= 0) return(48000L)
  rs <- suppressWarnings(as.numeric(out_reserve %||% 0)[1])
  if (!is.finite(rs) || rs < 0) rs <- 0
  # ⚠️⚠️ 这里是 `max(0, …)`，**不是** `max(512, …)`。留一个 512 的地板，
  #     小窗口上它就直接顶穿 `lim - rs`（512 > 256 那种），预算反而比能装的
  #     还大 —— 同一个"地板顶穿"的坑，这一节上面刚踩过一次。宁可返回 0
  #     （这一轮不带历史），也不能返回一个装不下的数。
  inner <- max(0, lim - rs - DSAPP_CTX_BUDGET_SLACK)
  as.integer(max(0, floor(inner * DSAPP_CTX_CHARS_PER_TOKEN)))
}

#' 一批已经拼好的 messages 大概占多少 token
#'
#' ⚠️ 算的是**发出去的那一份**（system 提示 + 历史），不是库里的原始消息。
#'    两者能差一倍 —— system 提示里带着工作区文件清单、技能正文、执行模型
#'    说明，几万字符是常事。拿库里的历史去估，读条会常年偏低，低到超过上限
#'    那一刻才跳一下，而那正是"下一次发消息才知道"的老毛病（item 7）。
dsapp_ctx_used_tokens <- function(msgs) {
  if (!length(msgs)) return(0L)
  sum(vapply(msgs, function(m) dsapp_ctx_token_est(m$content %||% ""),
             integer(1)))
}

#' 给**回复**留多少 token
#'
#' 用户不再单独设回复长度了（V15.5 item 6），所以它是**算出来的**：
#' 总上限减去这一轮实际带进去的。
#'
#' @param limit 单次使用上限
#' @param in_tokens 已经拼好的 messages 的估算 token 数
#' @return 一个正数，至少 dsapp_ctx_min_out(limit)
dsapp_ctx_out_tokens <- function(limit, in_tokens) {
  lim <- suppressWarnings(as.numeric(limit %||% NA_real_)[1])
  used <- suppressWarnings(as.numeric(in_tokens %||% 0)[1])
  if (!is.finite(lim) || lim <= 0) return(DSAPP_CTX_OUT_CAP)
  if (!is.finite(used) || used < 0) used <- 0
  # ⚠️ 上限是**余量**（dsapp_ctx_out_reserve），不是"剩下的全部"。这两者
  #    不一样，而且差别在长窗口上很大：1M 的窗口、历史只占了 2 万，
  #    "剩下的全部"是 100 万 —— 发一个 max_tokens = 1028000 出去，绝大多数
  #    厂商会直接 400（它们自己那一侧另有上限），而用户会以为是我们算错了。
  #    余量是我们算历史预算时**已经留出来的那一块**，回复最多就用这么多，
  #    于是 input + output ≤ limit 这件事在两边是同一个数保证的。
  as.integer(max(dsapp_ctx_min_out(lim),
                 min(dsapp_ctx_out_reserve(lim), floor(lim - used))))
}

#' 单次使用上限在控件上的量程
#'
#' ★ V15.5 item 6 用户原话：「需要按照模型的能力自适应更改上下文长度的读条」。
#' 量程跟着**这个模型自己的窗口**走 —— deepseek 那一档给到 1M，查不到出处的
#' 厂商退回 DSAPP_CTX_DEFAULT（128K），而不是所有厂商一律摆一条 10M 的滑块。
#'
#' @return list(min, max, step)，形状和 dsapp_param_range() 一致，
#'   直接喂给 dsapp_maxtok_slider_max() / dsapp_maxtok_to_slider()。
dsapp_ctx_range <- function(vendor, model = NULL) {
  w <- dsapp_ctx_limit(vendor, model, NULL)   # NULL = 跟随模型 → 用窗口本身
  list(min = DSAPP_CTX_MIN_TOTAL, max = max(as.numeric(w), DSAPP_CTX_MIN_TOTAL),
       step = 1024)
}

#' 把用户填的单次使用上限夹进量程
#'
#' 和 dsapp_param_clamp() 是两件事：那一个是按**厂商参数**的量程夹（管
#' max_tokens / temperature），这一个按**模型上下文窗口**夹。
#' ⚠️ 哨兵 0（跟随模型）**原样返回**，不参与夹取 —— 它不是一个"很小的值"，
#'    它是"这一格交给模型自己"。夹一次它就会变成 1024，于是"跟随模型"静默
#'    变成"上限 1K"，一路发到厂商那边（这条坑 V13.14 已经在 max_tokens 上
#'    踩过一次，见 DSAPP_MAXTOK_UNLIMITED 那一段）。
dsapp_ctx_clamp <- function(vendor, model, value) {
  if (dsapp_ctx_is_follow(value)) return(DSAPP_CTX_FOLLOW)
  x <- suppressWarnings(as.numeric(value[1] %||% NA_real_))
  if (length(x) != 1L || !is.finite(x)) return(DSAPP_CTX_FOLLOW)
  r <- dsapp_ctx_range(vendor, model)
  x <- min(max(x, r$min), r$max)
  # 对齐到步长（从 min 起算）。不对齐的话滑块会顶着一个它自己走不到的位置，
  # 下一次拖动会跳一下 —— 看起来像应用把用户的值改了。
  x <- r$min + round((x - r$min) / r$step) * r$step
  min(max(x, r$min), r$max)
}

#' 一次请求的完整预算：上限 / 上下文占了多少 / 回复能写多长
#'
#' ★ V15.5 item 6 的**唯一**一处推导。发请求的地方和画读条的地方都调它 ——
#' 两处各算各的话，"读条说还剩 40%"和"实际发出去的 max_tokens"会慢慢对不上，
#' 而两边单看都对（这个仓库里同类分叉已经出现过不止一次）。
#'
#' @param msgs dsapp_scene_messages() 拼好的 messages
#' @param want 用户填的单次使用上限；NULL/0 = 跟随模型
#' @return list(limit, used, out, pct, label)
dsapp_ctx_plan <- function(msgs, vendor = NULL, model = NULL, want = NULL) {
  lim  <- dsapp_ctx_limit(vendor, model, want)
  used <- dsapp_ctx_used_tokens(msgs)
  out  <- dsapp_ctx_out_tokens(lim, used)
  # ⚠️ 推导出来的回复上限**也要过一遍 clamp**。用户手填的值在 mod_model 里
  #    夹过一次，而这个是算出来的，绕开了那一道 —— 学到过"这家 max_tokens
  #    最多 8192"的时候，推导值必须一起收，不然前面那道 clamp 白做了。
  #
  # ⚠️⚠️ 但 clamp 只能**往紧里收**。它自己带下限（DSAPP_PARAM_DEFAULTS 里
  #      max_tokens 的 min 是 1024），小窗口上算出来的额度可能比它还小 ——
  #      照单全收就是"夹回去"，把上面那条唯一的不变式（out + used ≤ limit）
  #      当场破掉，而症状是"小窗口的模型每次都 400"。所以这里只用它当
  #      上限：比 out 大就忽略，比 out 小才采纳。
  cap <- tryCatch(as.integer(dsapp_param_clamp(vendor, model, "max_tokens",
                                               out, default = out)),
                  error = function(e) out)
  if (is.finite(cap) && cap >= 1L && cap < out) out <- cap
  if (!is.finite(out) || out < 1L) out <- dsapp_ctx_min_out(lim)
  pct <- if (is.finite(lim) && lim > 0) {
    min(100L, as.integer(round(100 * used / lim)))
  } else 0L
  list(limit = lim, used = used, out = out, pct = pct)
}

DSAPP_PARAM_DEFAULTS <- list(
  temperature = list(min = 0, max = 1.5, step = 0.1),
  # ★ V15.5 item 6：第四个参数 —— **上下文窗口**（token）。
  #   ⚠️ 它必须在这里有一格，否则 dsapp_param_learn() 会在第一行
  #      （`base <- DSAPP_PARAM_DEFAULTS[[param]]` → NULL）直接 return(FALSE)，
  #      于是"学到了真窗口"这件事**静默不发生**：错误照报、界面上也没有
  #      任何异常，只有用户觉得"它怎么老是记不住"。
  #   min 取 1024：比这更小的"窗口"不可能是真的，写进去只会让量程打架。
  context_length = list(min = 1024, max = 10485760, step = 1024),
  # ---- max_tokens 的量程（V13.11 item 4）--------------------------------
  #
  # 用户原话：「单次 token 设置的太保守了，应该以 million 为单位」。
  # 追问过上限该定在哪一档，用户的答复是「**上限不设死，交给厂商报错**」——
  # 所以这里的 max 不是"我知道的最大值"，而是"输入框愿意义无反顾让你填到
  # 多少"。真实上限由厂商在**请求被拒**时告诉你（400 的原文会进对话，
  # 看得懂），而不是由这张表替它猜。
  #
  # ⚠️ min / step 都取 **1024（2 的幂）**，这不是随手写的：
  #      * 百万那几个整数（1048576 / 2097152 / 4194304）在 1024 步长下
  #        **正好落在格子上**（1048576 = 1024×1024）。步长取 512 或 1000
  #        的话，用户填 1048576 会被 dsapp_param_clamp() 悄悄挪成
  #        1048064 —— 而他只是填了个整数。
  #      * 滑块跨度从 1K 到 10M，分辨率仍然够（一格 1024，拖到头也就
  #        不到一万个格子）；数值输入框旁边的实时回显让拖动过程看得见。
  #
  # ⚠️ 别把 max 设成"无穷大"或 NA：r$max 会直接喂给 sliderInput 和
  #    numericInput 的 max=，NA 会让控件整块渲染不出来（见下面那条
  #    "表写歪了整条退回默认档"的兜底）。
  # ⚠️ 也别写成 10000000 —— 那个"整十的百万"在这里是**错的**：
  #    dsapp_fmt_tokens_short(10000000) 出来的是 "9.5M"（它是 9.54 个
  #    1048576），量程标签会印成"1K ~ 9.5M"这么个别扭数。
  #    10485760 = 1024 × 10240，既是 1048576 的整十倍（→ "10M"），又正好
  #    落在 1024 的步长格子上。
  max_tokens  = list(min = 1024, max = 10485760, step = 1024)
)

# ★ V13.11 item 4：这张表**现在是空的**，而且是故意的。
#
#   它原来只有一条 `deepseek = list(max_tokens = list(min = 512, max =
#   65536, step = 512))`，干的事是"给 DeepSeek 钉一个 64K 的硬上限"。
#   用户这一版明确要求上限不设死（见上面 DSAPP_PARAM_DEFAULTS 那段），
#   而表里那一行正是唯一一处"设死"——留着它，用户就会遇到
#   "我明明在别的厂商上能填 1M，切到 DeepSeek 又被夹回 64K"，
#   而他刚刚才说过不要这个行为。
#
#   ⚠️ **空表不代表这一层没用**：dsapp_param_range() 的三层叠加（默认档 →
#      厂商档 → 模型档）照旧在跑，selftest 里那几条是**临时往表里塞一条**
#      再验的（见"厂商档真的盖过了默认档"那条），所以这条路一直有人走。
#      以后哪家厂商的上限**有可靠出处**了（官方文档写死的数），往这里加；
#      没出处的别编 —— 编错了的表现是用户的合法请求被我们提前拦下。
DSAPP_VENDOR_PARAMS <- list()

# 空表。形状见上面注释里的例子 —— 故意留空，见"表里为什么这么空"。
DSAPP_MODEL_PARAM_RULES <- list()

# ---- 第四层：厂商在 400 里告诉我们的真实上限（Test_V15.3 item 2）-------------
#
# 用户原话：「运行时关于模型设置的问题报错 "HTTP 400：Field 'max_tokens'
# must be at most 65536" 能不能直接亮一个按钮『直接帮我设置』，然后用户点击后
# 就可以自动更改并应用新的模型服务配置」。
#
# 上面三张表（默认档 / 厂商档 / 模型档）都是**人写死的**，而它们之所以空着，
# 正是因为"真实上限由厂商在请求被拒时告诉你"（见 DSAPP_PARAM_DEFAULTS 那段）。
# 这一层就是把那句"告诉你"接住：**厂商说过一次，就别让它说第二次**。
#
# ⚠️ 它和上面三层的性质完全不同，混在一起读会误判：
#     · 上面三层是**编译期常量**，改它们要发版；
#     · 这一层是**运行期学到的**，来自库里的 model_param_limits 表，
#       进程启动时读一次（app.R 里 dsapp_param_learned_load()）。
#     · 所以它是四层里**最紧、优先级最高**的一层 —— 一个已经把你拒过的
#       上限，比任何人写死的数都权威。
#
# ⚠️ 为什么要有**进程内缓存**而不是每次查库：dsapp_param_range() 在热路径上
#    （每发一条消息、每次 agent 循环、起标题那次短请求都要过一遍
#    dsapp_param_clamp），而且它被一堆**没有数据库连接**的地方调用
#    （纯函数测试、run_scheduler.R）。所以这一层**只读内存、绝不碰库** ——
#    库那一边由 dsapp_param_learned_load() 显式灌进来。
.dsapp_param_learned_env <- new.env(parent = emptyenv())

#' 学到的上限在缓存里的键
#'
#' 归一化口径**必须和 dsapp_param_range() 的模型档一致**：厂商小写、
#' 模型名剥掉 `厂商/` 前缀再小写。两边不一致的症状是"明明学到了、就是不生效"，
#' 而且两处代码各自看都对。
dsapp_param_learned_key <- function(vendor, model, param) {
  v <- tolower(trimws(as.character(vendor %||% "")[1] %||% ""))
  m <- tolower(trimws(dsapp_model_strip_provider(
    as.character(model %||% "")[1] %||% "")))
  p <- tolower(trimws(as.character(param %||% "")[1] %||% ""))
  paste(v, m, p, sep = "\r")
}

#' 读一层学到的范围（只读内存）
#'
#' @return list(min, max) 或 NULL。两个分量都可能是 NA（那一侧没学到）。
#' ⚠️ **厂商或模型名为空时永远返回 NULL**：一条"没有厂商"的学习记录会套到
#'    所有厂商头上，那是拿一家的话去管另一家。
dsapp_param_learned_get <- function(vendor, model, param) {
  v <- trimws(as.character(vendor %||% "")[1] %||% "")
  m <- trimws(dsapp_model_strip_provider(as.character(model %||% "")[1] %||% ""))
  if (!nzchar(v) || !nzchar(m)) return(NULL)
  .dsapp_param_learned_env[[dsapp_param_learned_key(v, m, param)]]
}

#' 往缓存里放一条（**不写库**）
dsapp_param_learned_put <- function(vendor, model, param,
                                    max_value = NULL, min_value = NULL) {
  k <- dsapp_param_learned_key(vendor, model, param)
  .dsapp_param_learned_env[[k]] <- list(
    min = suppressWarnings(as.numeric(min_value %||% NA_real_)[1]),
    max = suppressWarnings(as.numeric(max_value %||% NA_real_)[1]))
  invisible(TRUE)
}

#' 清空进程内缓存（自检用；也是"库读不出来"时的兜底状态）
dsapp_param_learned_clear <- function() {
  ks <- ls(envir = .dsapp_param_learned_env)
  if (length(ks)) rm(list = ks, envir = .dsapp_param_learned_env)
  invisible(TRUE)
}

# ---- 「单次回复上限」滑块上的建议值（V13.10 item 6）------------------------
#
# 用户原话：「单次回复 token 上限需要同时有滑块和输入栏，并在滑块上设置
# 几个建议值」。
#
# ⚠️ 这是一串**档位**，不是"推荐值"。挑这几个数的理由是它们各自对应一种
#    真实用法，而不是等距排开好看：
#
#      4096    —— 一次普通问答、改一段代码。多数厂商的默认值就在这一档。
#      8192    —— 带一段长上下文的分析（贴一段报错、贴一个表头）。
#      32768   —— 长报告 / 大段代码重写。
#      131072  —— 128K：一次吐一整个多文件工程。
#      1048576 —— 1M：整篇长文档读进来、整篇吐出来。
#      4194304 —— 4M：天花板档，"我就是想看看它的极限在哪"。
#
# ★ V13.11 item 4 改的就是这一串：原来是 4K/8K/16K/32K/64K，**顶格只有 64K**
#   （旧默认档的上限），所以界面上根本看不出"还能往百万走"。用户原话是
#   「应该以 million 为单位」—— 现在每一档的**标签**就是 4K/8K/32K/128K/
#   1M/4M（见 dsapp_fmt_tokens_short 的 M 那一档），一眼能读出量级。
#   拆掉了 16K/64K 两档：相邻档位差 2 倍时按钮太多，而 6 个已经在 264px 宽
#   的左栏里换行了（.dsapp-maxtok-sug 允许换行，见 app.css）。留 4 倍一档。
#
# ⚠️ 这串数**不保证每个模型都用得上**。真正的量程来自 dsapp_param_range()，
#    有的模型上限只有 8192 —— 那么 32768 以上的档位会被
#    dsapp_maxtok_suggestions() 丢掉，界面上不会出现一个点了会被夹回去的
#    按钮（"点了之后数字变了但我设的不是那个"是最容易让人不信任控件的事）。
DSAPP_MAXTOK_SUGGEST <- c(4096L, 8192L, 32768L, 131072L, 1048576L, 4194304L)

#' 当前 (厂商, 模型) 下，滑块上该摆哪几个建议值
#'
#' 只留范围内、且能落到步长上的档位；范围本身错得离谱时返回空 —— 界面上
#' 少一行按钮，比摆一排点了没反应的按钮好。
#'
#' @param r dsapp_param_range(...) 的结果；NULL 时用默认档。
#' @return 数值向量（可能长度 0），从大到小**不排序**（保留 DSAPP_MAXTOK_SUGGEST
#'   的顺序，小的在前 —— 和滑块从左到右一致）。
dsapp_maxtok_suggestions <- function(r = NULL) {
  r <- r %||% DSAPP_PARAM_DEFAULTS$max_tokens
  lo <- suppressWarnings(as.numeric(r$min)[1])
  hi <- suppressWarnings(as.numeric(r$max)[1])
  st <- suppressWarnings(as.numeric(r$step %||% 1)[1])
  if (!is.finite(lo) || !is.finite(hi) || lo > hi) return(numeric(0))
  if (!is.finite(st) || st <= 0) st <- 1
  v <- as.numeric(DSAPP_MAXTOK_SUGGEST)
  v <- v[v >= lo & v <= hi]
  # 对齐步长：对不齐的档位（比如步长 1000、档位 4096）会被滑块顶到一个
  # 它自己走不到的位置，拖一下就跳 —— 见 dsapp_param_clamp 里同一段说明。
  v <- lo + round((v - lo) / st) * st
  v <- sort(unique(v[v >= lo & v <= hi]))
  v
}

#' 把 token 数写成给人看的形式（"8K" / "64K" / "1M" / "1.5M"）
#'
#' 只在**量级**说得清的地方用：建议值按钮、量程标签。**别拿它去显示用户
#' 当前的值** —— 那个要精确到个位，写成 "8K" 之后用户看不出自己设的到底
#' 是 8192 还是 8000。
dsapp_fmt_tokens_short <- function(n) {
  n <- suppressWarnings(as.numeric(n)[1])
  if (!is.finite(n)) return("—")
  # ★ V13.11 item 4：百万单开一条。用户原话「应该以 million 为单位」——
  #   1048576 写成 "1024K" 是能算出来，但没人那么读；而"以 K 为单位"正是
  #   这一版之前看不出"还能往百万走"的原因之一。
  #
  # ⚠️ 判据是 `%% 1048576 == 0` 而不是 `>= 1048576`：1.5M 这种也要出得来
  #    （它走下面的小数分支）。反过来 2097152 必须写成 "2M" 而不是 "2.0M"。
  if (isTRUE(n >= 1048576)) {
    m <- n / 1048576
    return(if (abs(m - round(m)) < 1e-9) sprintf("%dM", as.integer(round(m)))
           else sprintf("%.1fM", m))
  }
  if (n >= 1024 && n %% 1024 == 0) sprintf("%dK", as.integer(n / 1024))
  else format(as.integer(n), big.mark = ",")
}

# ---- 「不设上限」：滑块最右那一格（V13.14 item 22）-------------------------
#
# 用户原话：「单次回复上限的最右侧应该是"不设上限"」。
#
# ★ 它是一个**真实取值**，不是把滑块右端的字改一改就完事。
#   最右那格如果只是"看着写着不设上限"、实际发出去一个 10,486,784 的上限，
#   那就是这个界面里最坏的一种控件：用户读到什么，它就不做什么。所以：
#
#     滑块拉到最右 → state$max_tokens = DSAPP_MAXTOK_UNLIMITED
#                   → 请求体里**根本不带 max_tokens 这个字段**
#                   → 上限由厂商自己那套默认值说了算
#
#   "不设上限"能成立，靠的正是**不发这个字段**。任何我们填得出来的数字都
#   是一个上限（10485760 也是），只有不发才是真的把这件事交还给厂商。
#
# ⚠️ 哨兵取 **0**，不取 NA：
#     state$max_tokens 会被一路传到 llm.R 的请求体、写进脱离会话的快照
#     （R/detach.R）、在通知和提示词里被格式化。NA 在这些地方会静默退化成
#     "这一项没有"——`%||%` 挡不住 NA（它只挡 NULL），而"没有"在每一个下游
#     都有各自不同的默认值，等于每加一个下游就多一种行为。0 是一个真的数：
#     `!is.finite(x) || x <= 0` 一条判据走遍全部下游，而合法上限的下限是
#     1024（见 DSAPP_PARAM_DEFAULTS），0 永远撞不上。
#
# ⚠️ 空串也走同一条路（`as.numeric("")` 是 NA，带一条 warning）。输入栏被
#    用户清空，在服务端就是 NA —— 实测过 Shiny 1.10 的 numericInput 绑定，
#    清空之后 input$ 拿到的是 logical NA 而**不是 NULL**（同一次实测还确认了
#    updateNumericInput(value = NA) 真的会把框清空）。见 mod_model.R 里
#    "清空输入栏 = 不设上限"那一段。
DSAPP_MAXTOK_UNLIMITED <- 0L

#' 这个值是不是「不设上限」
#'
#' ⚠️ **NULL 不算**。NULL 是"还没设过"（控件刚建起来、设置还没载入），那种
#'    时候该用默认档 65536，而不是替用户做一个"以后都不设上限"的决定。
#'    真正的空值（输入栏被清空）到服务端是 NA，不是 NULL。
dsapp_maxtok_is_unlimited <- function(x) {
  if (is.null(x) || length(x) == 0L) return(FALSE)
  x <- suppressWarnings(as.numeric(x[1]))
  !is.finite(x) || x <= 0
}

#' 滑块上「不设上限」那一格的位置
#'
#' 比有限量程的最高档再高**一格**。
#'
#' ⚠️ 必须正好落在一个格子点上，否则滑块根本停不到那儿 —— 用户拖到最右会
#'    被吸附回 10M，而「不设上限」永远点不出来（症状是"拖到头还是 10,000,000"，
#'    看起来像这次改动没生效）。DSAPP_PARAM_DEFAULTS 里的 min / max / step
#'    都是 1024 的倍数，max + step 从 min 起算正好是整数格。
dsapp_maxtok_slider_max <- function(r) {
  r$max + r$step
}

#' 滑块读到的数 → 上限值（最右那一格塌成 DSAPP_MAXTOK_UNLIMITED）
#'
#' @return 数值；滑块给了个不是数的东西时返回 NULL（调用方原样跳过）。
dsapp_maxtok_from_slider <- function(v, r) {
  # ⚠️ `x[1] %||% NA_real_` 那半截不是装饰。写成 `as.numeric(v[1])` 的话，
  #    v = NULL 时 `NULL[1]` 是 NULL、`as.numeric(NULL)` 是 numeric(0)、
  #    `is.finite(numeric(0))` 是 logical(0)、`if (logical(0))` 直接报
  #    **argument is of length zero** —— 报错位置指着这个 if，和"滑块没给值"
  #    这件事看不出任何关系。（实测踩到过。）
  v <- suppressWarnings(as.numeric(v[1] %||% NA_real_))
  if (length(v) != 1L || !is.finite(v)) return(NULL)
  if (v >= dsapp_maxtok_slider_max(r)) return(DSAPP_MAXTOK_UNLIMITED)
  v
}

#' 上限值 → 滑块该停在哪一格
#'
#' @return 数值。**永远返回一个滑块停得住的位置**：拿不到数时退到 r$min，
#'   而不是 NA / numeric(0)（那两种会让 sliderInput 直接报错，报的还是
#'   控件内部的话，看不出是谁传坏的）。
dsapp_maxtok_to_slider <- function(x, r) {
  if (dsapp_maxtok_is_unlimited(x)) return(dsapp_maxtok_slider_max(r))
  x <- suppressWarnings(as.numeric(x[1] %||% NA_real_))
  if (length(x) != 1L || !is.finite(x)) return(r$min)
  x
}

#' 「单次回复上限」给人看的写法
#'
#' @param short TRUE 用短写法（"8K"），FALSE 用带千分位的精确数。
#'   ⚠️ 别拿它去显示用户**正在编辑**的那个值 —— 那个要精确到个位（见
#'   dsapp_fmt_tokens_short 的说明）。这里只用在"说给人听"的句子和标签里。
dsapp_fmt_maxtok <- function(x, short = FALSE) {
  # ★ V15.5 item 6：这一格的含义从「不设上限」变成「跟随模型」。
  #   ⚠️ 不是换个说法而已：0 发到下游**不再**是"不带 max_tokens 字段"，
  #      而是"这一次的可用总量 = 这个模型自己的上下文窗口"。见
  #      dsapp_ctx_limit()。回复上限现在由总上限推出来，不可能不设。
  if (dsapp_maxtok_is_unlimited(x)) return("跟随模型")
  # ⚠️ 同 dsapp_maxtok_from_slider：`x[1]` 遇上 NULL 会得到 numeric(0)，
  #    再喂给 `if (!is.finite(x))` 就是 argument is of length zero。
  x <- suppressWarnings(as.numeric(x[1] %||% NA_real_))
  if (length(x) != 1L || !is.finite(x)) return("—")
  if (isTRUE(short)) dsapp_fmt_tokens_short(x)
  else format(as.integer(x), big.mark = ",")
}

#' 某个 (厂商, 模型) 下，某个参数的取值范围
#'
#' @param param "temperature" 或 "max_tokens"
#' @return list(min, max, step)；param 不是已知参数时返回 NULL（调用方自己
#'   决定是当成"没有限制"还是"这是个笔误"—— 隐式返回一个默认范围会把这个
#'   笔误藏起来）。
#'
#' ⚠️ 这里返回的 max 是**能填的最大数字**，不是滑块的最右端 —— 滑块最右端
#'    还要再高一格，那一格是「不设上限」（见 dsapp_maxtok_slider_max）。
dsapp_param_range <- function(vendor, model = NULL, param = "temperature") {
  param <- trimws(as.character(param %||% "")[1] %||% "")
  base <- DSAPP_PARAM_DEFAULTS[[param]]
  if (is.null(base)) return(NULL)
  out <- base

  # 厂商档。⚠️ 空串要走 [[ 拿不到东西（返回 NULL，不是报错），正好是
  # "没选厂商"该有的行为，不用额外判。
  v <- trimws(as.character(vendor %||% "")[1] %||% "")
  if (nzchar(v)) {
    ov <- DSAPP_VENDOR_PARAMS[[v]][[param]]
    if (is.list(ov)) out[names(ov)] <- ov
  }

  # 模型档。模式比的是**剥掉前缀之后的小写名**：聚合平台上转售的叫
  # `kimi/kimi-k3`，前缀不是模型名的一部分（同 dsapp_model_temp_locked）。
  nm <- tolower(trimws(dsapp_model_strip_provider(model %||% "")))
  if (nzchar(nm) && length(DSAPP_MODEL_PARAM_RULES)) {
    for (rule in DSAPP_MODEL_PARAM_RULES) {
      # 规则写歪了（pattern 不是字符串）不该让整页白屏 —— 跳过它，
      # 剩下的规则照常生效。
      if (!is.character(rule$pattern) || length(rule$pattern) != 1L) next
      if (!grepl(rule$pattern, nm)) next
      ov <- rule$params[[param]]
      if (is.list(ov)) out[names(ov)] <- ov
    }
  }

  out$min  <- suppressWarnings(as.numeric(out$min)[1])
  out$max  <- suppressWarnings(as.numeric(out$max)[1])
  out$step <- suppressWarnings(as.numeric(out$step %||% NA_real_)[1])

  # ⚠️ 表写歪了（min > max、NA、非数字）就**整条退回默认档**，而不是把
  #    歪值递给 sliderInput —— 那个的表现是整页 "An error has occurred"，
  #    而用户根本看不出是哪个厂商配错了。宁可量程宽一点。
  bad <- !is.finite(out$min) || !is.finite(out$max) || out$min > out$max ||
    !is.finite(out$step) || out$step <= 0
  if (bad) return(base)

  # ★ 第四层：学到的档（Test_V15.3 item 2）。**最紧、优先级最高** —— 它是
  #   厂商本人拒过一次的那个数，比任何人写死的都权威，所以只往**紧**里收。
  #
  #   ⚠️ 位置在 bad 检查**之后**，这是有意的：学到的 max 有可能比上面三层的
  #      min 还小（库里有脏行、或者以后有人手工塞了一条）。放在 bad 检查之前
  #      的话，那种行会让 out$min > out$max 成立 → 整条退回默认档 →
  #      **学到的上限被静默丢掉**。症状是"点了『直接帮我设置』、提示成功、
  #      下一轮一模一样地再 400 一次"，而解析、写库、缓存三处各自看都对。
  #
  #   ⚠️ 只收不放（`<` 而不是直接赋值）：写成直接覆盖的话，一条学到的宽值会把
  #      厂商档/模型档**放松**掉 —— 那两层存在的意义正是"有人确认过这家就是
  #      这个数"，被一条运行期记录推翻是反的。
  lr <- dsapp_param_learned_get(v, model, param)
  if (is.list(lr)) {
    if (isTRUE(is.finite(lr$max)) && lr$max < out$max) out$max <- lr$max
    if (isTRUE(is.finite(lr$min)) && lr$min > out$min) out$min <- lr$min
    # 收完之后还得是个合法的量程。下限被顶到上限之上时**让下限**，
    # 不是让上限 —— 上限是厂商说的话，下限只是我们自己填输入框的起点。
    if (out$min > out$max) out$min <- out$max
    # 步子比量程还大时，sliderInput 会把滑块吸附到量程外面去。
    gap <- out$max - out$min
    if (gap > 0 && gap < out$step) out$step <- gap
  }
  out
}

#' 把一个参数值夹进当前 (厂商, 模型) 允许的范围
#'
#' @param value 用户当前的值（可能是 NULL —— 控件正在重建，或者 NA）
#' @param default value 不可用时用它。**也不可用**时取范围下限：宁小勿大 ——
#'   上限填错会把请求打成 400，下限填错只是回复短一点。
#' @return 数值；param 未知（dsapp_param_range 返回 NULL）时**原样返回 value**。
dsapp_param_clamp <- function(vendor, model, param, value, default = NULL) {
  r <- dsapp_param_range(vendor, model, param)
  if (is.null(r)) return(value)

  x <- suppressWarnings(as.numeric(value %||% NA_real_)[1])
  if (!is.finite(x)) {
    x <- suppressWarnings(as.numeric(default %||% NA_real_)[1])
  }
  if (!is.finite(x)) x <- r$min

  x <- min(max(x, r$min), r$max)
  # 对齐到步长（从 min 起算）。不对齐的话滑块会顶着一个它自己走不到的位置，
  # 下一次拖动会跳一下 —— 看起来像应用把用户的值改了。
  if (is.finite(r$step) && r$step > 0) {
    x <- r$min + round((x - r$min) / r$step) * r$step
    x <- min(max(x, r$min), r$max)
  }
  x
}

# ---- 学到的上限：落库 / 读库（Test_V15.3 item 2）----------------------------
#
# 上面 .dsapp_param_learned_env 那一套是**内存**。这一节是它和库之间的桥。
#
# ⚠️ 为什么非要落库：学习发生在**用户 A 那个会话进程**里。A 点完按钮、提示
#    "已设置"，下一个会话是**另一个 R 进程**（Shiny Server 一个会话一个进程，
#    空闲 5 秒就被回收）。只放内存的话，用户 B —— 甚至 A 自己刷新一下页面 ——
#    拿到的是**空的**缓存，同一个 400 再来一遍。落库才有"这个模型以后都按它来"。

#' model_param_limits 的表结构（由 R/db.R 的 dsapp_db_schema 调用）
#'
#' 和 mail_queue / lit_subs 一样是**旁挂表**：不改任何现有表，所以只加一个
#' schema 函数、把 DSAPP_SCHEMA_VERSION 加一就够。
#'
#' ⚠️ 唯一的键是 (vendor, model, param) 三元组，不是 id。**同一台机器上所有
#'    账号共用这张表** —— 这是刻意的：厂商的上限跟谁在用它没关系，一个账号
#'    试出来的数对另一个账号同样成立。参数域是客观事实，不是用户偏好。
dsapp_db_schema_paramlim <- function(con) {
  DBI::dbExecute(con, "
    CREATE TABLE IF NOT EXISTS model_param_limits (
      id         INTEGER PRIMARY KEY AUTOINCREMENT,
      vendor     TEXT NOT NULL DEFAULT '',
      model      TEXT NOT NULL DEFAULT '',
      param      TEXT NOT NULL DEFAULT '',
      min_value  REAL,
      max_value  REAL,
      source     TEXT NOT NULL DEFAULT '',
      note       TEXT NOT NULL DEFAULT '',
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    )")
  # 一个 (厂商, 模型, 参数) 只有一行 —— 重新学到就覆盖（见 dsapp_param_learn）。
  # upsert 的 ON CONFLICT 认的就是这个索引。
  DBI::dbExecute(con,
    "CREATE UNIQUE INDEX IF NOT EXISTS idx_mpl_key
       ON model_param_limits(vendor, model, param)")
  invisible(TRUE)
}

#' 把库里的学习记录灌进进程内缓存
#'
#' 在每个 R 进程启动时调一次（app.R）。**读不出来就当作"什么都没学到"** ——
#' 那是安全的那一侧：量程宽一点，顶多让用户再撞一次 400，不会拦住合法请求。
#'
#' @return 有没有真的读到东西（TRUE/FALSE），调用方一般不看。
dsapp_param_learned_load <- function(con = NULL) {
  if (is.null(con)) con <- tryCatch(dsapp_db(), error = function(e) NULL)
  dsapp_param_learned_clear()
  if (is.null(con)) return(invisible(FALSE))
  rows <- tryCatch(
    DBI::dbGetQuery(con,
      "SELECT vendor, model, param, min_value, max_value
         FROM model_param_limits"),
    error = function(e) NULL)
  if (is.null(rows) || !nrow(rows)) return(invisible(FALSE))
  for (i in seq_len(nrow(rows))) {
    dsapp_param_learned_put(rows$vendor[i], rows$model[i], rows$param[i],
                            max_value = rows$max_value[i],
                            min_value = rows$min_value[i])
  }
  invisible(TRUE)
}

#' 记下一条厂商说的上限：写库 + 当场更新本进程的缓存
#'
#' @param max_value 厂商说的上限。NULL/NA 表示"只记了下限"（目前没人这么用）。
#' @param note 诊断用的一句话。**只截一段**，见下面的说明。
#' @return 真的记下来了 TRUE；参数不合法 FALSE（调用方据此决定要不要报成功）。
dsapp_param_learn <- function(vendor, model, param,
                              max_value = NULL, min_value = NULL,
                              source = "provider_400", note = "", con = NULL) {
  param <- trimws(as.character(param %||% "")[1] %||% "")
  base <- DSAPP_PARAM_DEFAULTS[[param]]
  if (is.null(base)) return(FALSE)

  v <- tolower(trimws(as.character(vendor %||% "")[1] %||% ""))
  m <- tolower(trimws(dsapp_model_strip_provider(
    as.character(model %||% "")[1] %||% "")))
  # ⚠️ 没有厂商或没有模型名就不记。一条"没有厂商"的记录会套到所有厂商头上 ——
  #    拿 A 家的话去管 B 家，而 B 家的真实上限可能高得多。
  if (!nzchar(v) || !nzchar(m)) return(FALSE)

  mx <- suppressWarnings(as.numeric(max_value %||% NA_real_)[1])
  mn <- suppressWarnings(as.numeric(min_value %||% NA_real_)[1])
  if (!is.finite(mx) && !is.finite(mn)) return(FALSE)
  # ⚠️ 比这个参数的**最低可填值**还小的"上限"不可能是有用的：
  #    它连量程下限都盖不住，存进去只会让 dsapp_param_range() 里的
  #    min/max 打架（见那一节的说明）。宁可不记。
  if (is.finite(mx) && mx < base$min) return(FALSE)

  note <- substr(gsub("[\r\n\t]+", " ", as.character(note %||% "")[1] %||% ""),
                 1L, 200L)
  now <- dsapp_now()
  if (is.null(con)) con <- dsapp_db()

  DBI::dbExecute(con, "
    INSERT INTO model_param_limits
      (vendor, model, param, min_value, max_value, source, note,
       created_at, updated_at)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
    ON CONFLICT(vendor, model, param) DO UPDATE SET
      min_value  = excluded.min_value,
      max_value  = excluded.max_value,
      source     = excluded.source,
      note       = excluded.note,
      updated_at = excluded.updated_at",
    list(v, m, param, mn, mx, as.character(source %||% "")[1] %||% "",
         note, now, now))

  # ★ 自己这个进程当场生效，不等下次启动。学习就发生在这里，而用户点完
  #   "直接帮我设置"紧接着就会再发一条 —— 那一条必须已经吃到新的上限。
  dsapp_param_learned_put(v, m, param, max_value = mx, min_value = mn)
  invisible(TRUE)
}

# ---- 从 400 原文里读出厂说的上限（Test_V15.3 item 2）------------------------

# 「这个字段最多多少」的各种写法。**顺序 = 优先级**：越明确的排越前面，
# 因为下面是"第一条命中的算数"。带歧义的（`maximum ... is N`）排在后面。
#
# ⚠️ 每条**有且只有一个**捕获组（`(?:...)` 不算），因为取数靠
#    regexec 的第 2 个元素。多一个组就会取到别的东西。
# ⚠️ 数字写成 `[0-9][0-9,]*`：厂商会写 65,536（带千分位），解析时去逗号。
.dsapp_maxtok_bound_pats <- c(
  "less than or equal to\\s*[:=]?\\s*([0-9][0-9,]*)",
  "no more than\\s*[:=]?\\s*([0-9][0-9,]*)",
  "at most\\s*[:=]?\\s*([0-9][0-9,]*)",
  "(?:must|should|can|cannot|can't|could|may|shall|will)\\s+(?:not\\s+)?(?:be\\s+)?(?:exceed|be\\s+greater\\s+than|be\\s+larger\\s+than|be\\s+more\\s+than|be\\s+less\\s+than\\s+or\\s+equal\\s+to)\\s*[:=]?\\s*([0-9][0-9,]*)",
  "(?:valid\\s+)?range[^0-9]{0,40}?[\\[\\(]\\s*[0-9][0-9,]*\\s*,\\s*([0-9][0-9,]*)\\s*[\\]\\)]",
  # ★ V15.6 item 1：上面那条要的是英文 "range"，中文厂商写的是「范围」——
  #   用户报的那条原文「HTTP 400：max_tokens参数非法：限制数值范围[1,131072]」
  #   一条模式都命不中（实测解析出来是 NULL，于是"直接帮我设置"那颗按钮
  #   根本不出现，用户只能自己去翻文档）。
  #   ⚠️ **必须**带「范围/区间」这类字样才认方括号里的区间。光看见 `[1, 2]`
  #      就当上限的话，报错正文里随便一段 JSON 数组（`"stop": [1, 2]`）都会
  #      被读成"上限 = 2"，然后按钮真的去把 max_tokens 调成 2 ——
  #      给一个错的按钮比不给按钮坏得多。
  "(?:数值|取值|允许|合法)?(?:范围|区间)\\s*[：:=]?\\s*[\\[\\(（【]\\s*[0-9][0-9,]*\\s*[，,、~～]\\s*([0-9][0-9,]*)\\s*[\\]\\)）】]",
  "between\\s*[0-9][0-9,]*\\s*and\\s*([0-9][0-9,]*)",
  "(?:<=|≤|=<)\\s*([0-9][0-9,]*)",
  # 数字在括号里回指（"1000000 > 65536 (maximum)"）
  "([0-9][0-9,]*)\\s*\\(\\s*(?:max|maximum|max\\.?\\s*allowed)\\s*\\)",
  "(?:maximum|upper\\s+(?:limit|bound)|最大)\\s*(?:value|allowed\\s+value)?\\s*(?:is|of|:|=)\\s*([0-9][0-9,]*)",
  "(?:不能超过|不得超过|最多(?:为|是)?|上限(?:为|是)?|最大(?:值)?(?:为|是)?)\\s*[:：]?\\s*([0-9][0-9,]*)"
)

# ★★ 「上下文太长」这一类**必须**排除，而且必须在认上限**之前**排除。
#
#   它们的原文里同样有 "maximum ... 65536"，照样能过上面那些模式 ——
#   但那个 65536 是**总上下文**（提示词 + 回复），不是 max_tokens 的上限。
#   拿它去设 max_tokens 的结果是：提示词已经占了两万，设成 65536 照样 400，
#   而界面上会说"已按厂商的上限调好了"。**给一个错的按钮比不给按钮坏得多。**
#
#   ⚠️ 所以这条判据是**整段文本**上做的，不看窗口：宁可漏掉一条夹在上下文
#      报错里的真上限，也不能把上下文长度当成上限用。
.dsapp_ctx_len_pat <- paste(c(
  "context[ _-]*(?:length|window|limit|size)",
  "maximum\\s+context",
  "context_length_exceeded",
  "too\\s+many\\s+(?:tokens|input)",
  "prompt\\s+is\\s+too\\s+long",
  "input\\s+is\\s+too\\s+long",
  "reduce\\s+the\\s+length",
  "上下文(?:长度|窗口|上限|超)",
  "超出.{0,6}上下文",
  "输入(?:过|太)长"
), collapse = "|")

# 「这个模型的**窗口**多大」的各种写法（V15.5 item 7）。
#
# ⚠️ 为什么不能直接复用 .dsapp_maxtok_bound_pats：那里面认上限的写法是
#    `maximum ... is N`（中间只允许夹 value / allowed value），而厂商说窗口
#    的时候写的是 "maximum context length is 65536" —— `maximum` 和 `is`
#    中间夹着 "context length" 三个词，那些模式一条都匹配不上。实测：
#    拿原来的模式去解析这句话，window 解析出来是 NULL，于是"学到了真窗口"
#    静默不发生，用户下次还撞同一堵墙。
# ⚠️ 同样**每条只有一个捕获组**（取数靠 regexec 的第 2 个元素）。
.dsapp_ctx_window_pats <- c(
  "context\\s*(?:length|window|size|limit)\\s*(?:is|of|:|=)?\\s*([0-9][0-9,]*)",
  "(?:maximum|max)\\s+(?:allowed\\s+)?(?:context|input|prompt)[^0-9]{0,30}?([0-9][0-9,]*)",
  "([0-9][0-9,]*)\\s*(?:tokens?)?\\s*(?:of\\s+)?(?:context|input)\\s*(?:length|window|size|limit)",
  "up\\s+to\\s+([0-9][0-9,]*)\\s*(?:tokens)?",
  # Anthropic 那一家的写法："prompt is too long: 300000 tokens > 200000
  # maximum"。⚠️ 数字在 `>` **后面**那个才是窗口，前面那个是我们发出去的量
  # —— 取反了就学成一个更大的窗口，下次照样超。
  ">\\s*([0-9][0-9,]*)\\s*(?:tokens?)?\\s*(?:maximum|max)",
  "上下文(?:长度|窗口|上限|大小)(?:为|是|：|:)?\\s*([0-9][0-9,]*)"
)

#' 从报错原文里裁出提到 max_tokens 的那几段
#'
#' @return 字符向量，每段 = 一处 `max_tokens` 前后各 160 字符。
.dsapp_maxtok_windows <- function(txt, width = 160L) {
  m <- gregexpr("max[ _-]?(?:completion[ _-]?)?tokens", txt,
                ignore.case = TRUE)[[1]]
  if (length(m) == 1L && m[1] == -1L) return(character(0))
  len <- attr(m, "match.length")
  n <- nchar(txt)
  out <- character(length(m))
  for (i in seq_along(m)) {
    a <- max(1L, m[i] - width)
    b <- min(n, m[i] + len[i] + width)
    out[i] <- substr(txt, a, b)
  }
  unique(out)
}

#' 把一段报错原文解析成「上下文窗口到底多大」
#'
#' ★ V15.5 item 7 的另一半。用户原话：「内容输出时遇到上下文长度的问题，请
#' 立即给出反馈，而不是在下一次发送消息时才告知用户」。
#'
#' ⚠️ 它和 dsapp_maxtok_advice() 是**互斥**的两件事，判据是同一条
#'    .dsapp_ctx_len_pat —— 那边先出局（见那段说明）。所以同一个错误不可能
#'    既被当成"该调 max_tokens"又被当成"窗口没那么大"。
#'
#' @param plan 可选，dsapp_ctx_plan() 的结果，用来把"我们算了多少"写进反馈里。
#' @return NULL（不是上下文类错误），或者
#'   list(window = <数值或 NULL>, msg = <给人看的 markdown>)
dsapp_ctx_error_advice <- function(err, plan = NULL) {
  txt <- paste(as.character(unlist(err) %||% ""), collapse = " ")
  txt <- gsub("[\r\n\t]+", " ", txt)
  if (!nzchar(trimws(txt))) return(NULL)
  if (!grepl(.dsapp_ctx_len_pat, txt, ignore.case = TRUE, perl = TRUE)) {
    return(NULL)
  }

  # 报错原文里常常带着真实窗口（"... maximum context length is 65536 tokens"）。
  # ⚠️ 这里找的是**整段**里的那个数，不像 dsapp_maxtok_advice() 那样只找
  #    提到 max_tokens 的那一句 —— 上下文报错里往往压根不提 max_tokens。
  # ⚠️ 先过**窗口专用**的那一套，再退回通用的上限模式。顺序反过来的话，
  #    "maximum context length is 65536 tokens, but you requested 70000"
  #    里那个 70000（我们发出去的量）可能先被 `at most` 之类命中，学成一个
  #    比真实窗口大的数 —— 而那正是这一次报错的原因，学错了下次照样撞。
  window <- NULL
  for (p in c(.dsapp_ctx_window_pats, .dsapp_maxtok_bound_pats)) {
    mm <- regmatches(txt, regexec(p, txt, ignore.case = TRUE, perl = TRUE))[[1]]
    if (length(mm) < 2L) next
    n <- suppressWarnings(as.numeric(gsub("[^0-9]", "", mm[2])))
    if (length(n) != 1L || !is.finite(n) || n < 1024) next
    window <- n
    break
  }

  used  <- suppressWarnings(as.numeric(plan$used  %||% NA_real_)[1])
  limit <- suppressWarnings(as.numeric(plan$limit %||% NA_real_)[1])
  # 厂商原话只截一段。整段可能几千字（有些厂商会把整个请求回显给你），
  # 而用户要的是"为什么没发出去"，不是那份回显。
  short <- substr(trimws(txt), 1L, 300L)
  if (nchar(trimws(txt)) > 300L) short <- paste0(short, "…")

  msg <- paste0(
    "**这一次请求没能发出去：上下文超了。**\n\n",
    "厂商那边的原话是：\n\n> ", short, "\n\n",
    if (is.finite(used) && is.finite(limit)) {
      sprintf(paste0("平台这一侧算的是：这一次带进去约 %s tokens，",
                     "可用总量 %s tokens（%.0f%%）。\n"),
              format(used, big.mark = ","), format(limit, big.mark = ","),
              100 * used / limit)
    } else "",
    if (!is.null(window)) {
      sprintf(paste0("从报错里读出来，这个模型的上下文窗口是 %s tokens —— ",
                     "比我们记着的小，已经按它改过来了，下一条消息就会按新的算。\n"),
              format(window, big.mark = ","))
    } else {
      paste0("报错里没有写窗口多大，所以这一次只能请你手动调一下。\n")
    },
    "\n**怎么办：**\n",
    "- 到「模型服务」页把「单次使用上限」调小到窗口以内",
    if (!is.null(window)) sprintf("（%s 或更小）", format(window, big.mark = ","))
    else "", "；\n",
    "- 或者**新开一个对话** —— 历史是自动裁剪的，但裁剪有下限：",
    "最早的提问永远保留，所以一个很长的对话最后会裁不动；\n",
    "- 这条消息本身没丢，改完直接重发就行。\n\n",
    "⚠️ 这不是「你的问题太难」，是平台对这个模型的窗口估大了。")
  list(window = window, msg = msg)
}

# ---- 厂商报错的分类与说辞（Test_V15.7 item 1）-------------------------------
#
# 用户原话：「wchcpu2019@163.com这个账号依然是卡住的，任何操作都会引起页面
# 不响应，帮我看下应该怎么解决这个问题。」
#
# 查下来那个账号配的智谱 Key 被厂商**每一次**都拒：
#     HTTP 429：余额不足或无可用资源包,请充值。
# 而这条错误当时的表现是：
#   · 只写进 rv$error（**服务端内存里的** reactiveVal）→ 刷新页面就没了；
#   · 不落库 → 对话里留下 4 条「继续」和 1 条「你好」，后面一条回复都没有。
# 用户看到的就是"发了没反应 / 页面卡住"。**一半是厂商拒了，另一半是拒了不说。**
#
# 落库这条路 V15.5 item 7 已经给**上下文类**错误修好了
# （dsapp_ctx_error_advice），别的错误一律没有说明、也不落库 —— 这个函数
# 把"说"补齐：任何非空的报错都归类 + 给出用户自己那侧能做的事，一律落库。
#
# ⚠️⚠️ 判据宁可粗、不可漏。认不出来就走 "other" 那一格，照样带着厂商原话
#     落库 —— 这个函数存在的全部意义就是"再也不出现什么都没发生"，所以它
#     **只有 err 为空时才返回 NULL**。加任何"认不出就不报"的收紧都是把
#     这个 bug 请回来。
#
# ⚠️ 分类顺序是有意的：余额 → 鉴权 → 模型 → 限流 → 超时 → 服务端。
#    429 既可能是"没钱"也可能是"太快"：中文厂商的余额文案里没有 rate 字样，
#    英文厂商的限流文案里没有 balance 字样，所以两个都认，**余额先判**
#    （见下面 kind 那段的翻案逻辑）。
.dsapp_err_pats <- list(
  balance = c(
    "余额不足", "无可用资源包", "请充值", "欠费", "余额", "账户余额",
    "insufficient\\s+(?:balance|funds|credit|quota|resource)",
    "exceeded\\s+your\\s+current\\s+quota",
    "billing\\s+(?:hard\\s+)?limit", "payment\\s+required",
    "credit\\s+balance", "out\\s+of\\s+credit", "no\\s+available\\s+resource"
  ),
  auth = c(
    "鉴权失败", "认证失败", "密钥(?:无效|错误|过期)", "令牌(?:无效|过期)",
    "invalid\\s+api[\\s_-]*key", "incorrect\\s+api[\\s_-]*key",
    "api[\\s_-]*key[^.]{0,24}(?:invalid|not\\s+valid|expired)",
    "unauthorized", "authentication[_\\s]*(?:error|failed)",
    "permission\\s+denied", "insufficient\\s+permissions",
    "no\\s+permission\\s+to\\s+access"
  ),
  model = c(
    "模型不存在", "模型未授权", "无权限访问该模型", "该模型不存在",
    "model[^.]{0,40}not\\s+found", "no\\s+such\\s+model", "unknown\\s+model",
    "invalid\\s+model", "unsupported\\s+model",
    "model[^.]{0,24}does\\s+not\\s+exist"
  ),
  rate = c(
    "频率", "限流", "请求过于频繁", "并发",
    "rate[\\s_-]*limit", "too\\s+many\\s+requests",
    "requests\\s+per\\s+(?:minute|second)", "overloaded"
  ),
  timeout = c(
    "超时", "无法连接", "连接失败", "网络异常",
    "timed?\\s*out", "timeout",
    "failed\\s+to\\s+(?:connect|resolve)", "could\\s+not\\s+resolve\\s+host",
    "connection\\s+(?:refused|reset|error)", "certificate"
  )
)

#' 厂商报错 → 「到底是什么事 + 我这边能做什么」
#'
#' 给**所有**非空的厂商报错配一段说辞，让 mod_chat 的出错分支只有一条路
#' （上下文类和其余所有类走同一段代码）。上下文那一类原样复用
#' `dsapp_ctx_error_advice()`，包括它的窗口学习和那段文案。
#'
#' @param err  报错原文（`rv$error`、HTTP 响应体，都行）。
#' @param plan 可选，`dsapp_ctx_plan()` 的结果。
#' @return NULL（err 是空的），或者 `list(kind, window, msg, notify)`：
#'   · `kind`   —— `"ctx"` / `"balance"` / `"auth"` / `"model"` /
#'                 `"rate"` / `"timeout"` / `"server"` / `"other"`
#'   · `window` —— 只有 `kind == "ctx"` 时可能非 NULL
#'   · `msg`    —— **落库**的那条 markdown（合成成一条 assistant 消息）
#'   · `notify` —— 弹给用户的那句短的
dsapp_llm_error_advice <- function(err, plan = NULL) {
  txt <- paste(as.character(unlist(err) %||% ""), collapse = " ")
  txt <- trimws(gsub("[\r\n\t]+", " ", txt))
  if (!nzchar(txt)) return(NULL)

  # 厂商原话只截一段：整段可能几千字（有的厂商会把整个请求回显回来），
  # 而用户要的是"为什么没发出去"，不是那份回显。
  short <- substr(txt, 1L, 300L)
  if (nchar(txt) > 300L) short <- paste0(short, "…")

  # ---- 上下文那一类先判：它有自己的处置（把真实窗口学下来）------------
  ctx <- tryCatch(dsapp_ctx_error_advice(err, plan), error = function(e) NULL)
  if (!is.null(ctx)) {
    return(list(kind = "ctx", window = ctx$window, msg = ctx$msg,
      notify = if (is.null(ctx$window))
        "上下文超出模型窗口，这一次请求没有发出去。详见对话里那条说明。"
      else
        sprintf(paste0("上下文超出模型窗口，这一次请求没有发出去。",
                       "已把窗口改成 %s，下一条就按新的算。"),
                format(ctx$window, big.mark = ","))))
  }

  hit <- function(pats) any(vapply(pats, function(p)
    grepl(p, txt, ignore.case = TRUE, perl = TRUE), logical(1)))

  # ---- 先按 HTTP 状态码定一个初判，再按文案翻案 ------------------------
  #
  # ⚠️ 认状态码要用 `HTTP[[:space:]]*([0-9]{3})`，不能裸认 `429` ——
  #    request_id / 时间戳 / token 数里都有可能出现这三个数字，那会把一条
  #    无关的报错归到限流名下。而 llm.R 拼的就是 `HTTP %d：%s`
  #    （R/llm.R:267），所以这个前缀一定在。
  mm <- regmatches(txt, regexec("HTTP[[:space:]]*([0-9]{3})", txt))[[1]]
  code <- if (length(mm) >= 2L) suppressWarnings(as.integer(mm[2])) else NA_integer_

  kind <- if (is.na(code)) NULL
    else if (code %in% c(401L, 403L)) "auth"
    else if (code == 402L) "balance"
    else if (code == 404L) "model"
    else if (code == 429L) "rate"
    else if (code >= 500L) "server"
    else NULL

  # 余额**能翻 429 的案**：中文厂商的"余额不足"就是挂在 429 上回来的
  # （这条 bug 的原样）。反过来不成立 —— 限流文案不该被 402 之类翻掉。
  if (hit(.dsapp_err_pats$balance)) kind <- "balance"
  else if (is.null(kind)) {
    kind <- if (hit(.dsapp_err_pats$auth)) "auth"
      else if (hit(.dsapp_err_pats$model)) "model"
      else if (hit(.dsapp_err_pats$rate)) "rate"
      else if (hit(.dsapp_err_pats$timeout)) "timeout"
      else "other"
  }

  head <- "**这一次请求没能发出去。**\n\n"
  quote_it <- paste0("厂商那边的原话是：\n\n> ", short, "\n\n")

  switch(kind,
    balance = list(
      kind = "balance", window = NULL,
      msg = paste0(
        "**这一次请求没能发出去：模型服务那边说账户余额不足。**\n\n",
        quote_it,
        "**怎么办（任选一条，都是你这侧能做的）：**\n",
        "- 给这家厂商的账户充值；\n",
        "- 或者到「模型服务」页换一家**还有余额**的厂商 —— ",
        "存过的 Key 按厂商分开记着，切过去就会自动用那一家的；\n",
        "- 这条消息本身没丢，改完直接重发就行。\n\n",
        "⚠️ 这不是网络问题，也不是这个对话坏了：厂商拒的是**每一次**请求，",
        "所以这个账号里换一个对话、换一个操作，同样不会有回复。"),
      notify = "模型服务余额不足，这一次请求没有发出去。详见对话里那条说明。"),
    auth = list(
      kind = "auth", window = NULL,
      msg = paste0(
        "**这一次请求没能发出去：厂商不认这把 API Key。**\n\n",
        quote_it,
        "**怎么办：**\n",
        "- 到「模型服务」页确认厂商**选对了** —— Key 是按厂商分开存的，",
        "选错厂商就会拿 A 家的 Key 去请求 B 家，而这类报错里一个字都不提厂商；\n",
        "- 重新粘一遍这家厂商的 Key（粘完点页面上的「更新」）；\n",
        "- 到厂商后台确认这把 Key 没有被吊销 / 过期。\n\n",
        "⚠️ 同上：在这个账号里换对话、换操作也没用，钥匙串里那把不换就不通。"),
      notify = "API Key 被厂商拒绝，这一次请求没有发出去。详见对话里那条说明。"),
    model = list(
      kind = "model", window = NULL,
      msg = paste0(
        "**这一次请求没能发出去：厂商那边没有这个模型**",
        "（或者这把 Key 没有权限用它）。\n\n",
        quote_it,
        "**怎么办：**\n",
        "- 到「模型服务」页点**「获取模型」**，从厂商真正提供的清单里挑一个",
        "（那个清单是直接问厂商要的，比手打可靠）；\n",
        "- 手填的模型名要和厂商文档里的一字不差。\n\n",
        "⚠️ 这一条只影响这个模型：换一个能用的模型，对话立刻就能继续。"),
      notify = "厂商那边没有这个模型，这一次请求没有发出去。详见对话里那条说明。"),
    rate = list(
      kind = "rate", window = NULL,
      msg = paste0(
        "**这一次请求没能发出去：厂商把请求挡回来了（HTTP 429）。**\n\n",
        quote_it,
        "这个码在厂商那边有两种常见意思，看上面那句原话就能分辨：\n",
        "- **余额 / 资源包没了** —— 中文厂商的 429 多半是这个",
        "（原话里会有「余额」「充值」这样的字）；\n",
        "- **请求太频繁 / 并发超了** —— 原话里会有 rate limit、频率之类，等几秒重发就好。\n\n",
        "**怎么办：**是余额就去充值或换一家厂商；是限流就等几秒再发一次。\n\n",
        "⚠️ 这条消息本身没丢，改完直接重发。"),
      notify = "厂商把请求挡回来了（429），这一次请求没有发出去。详见对话里那条说明。"),
    timeout = list(
      kind = "timeout", window = NULL,
      msg = paste0(
        "**这一次请求没能发出去：连不上厂商的服务器。**\n\n",
        quote_it,
        "**怎么办：**\n",
        "- 确认这台机器能出网（DNS / 代理 / 防火墙）；\n",
        "- 到「模型服务」页确认填的接口地址没写错；\n",
        "- 等一会儿重发 —— 厂商侧抖动是最常见的原因。\n\n",
        "⚠️ 这一条**不会**自己好，重发之前先确认网络。这条消息本身没丢。"),
      notify = "连不上模型服务，这一次请求没有发出去。详见对话里那条说明。"),
    server = list(
      kind = "server", window = NULL,
      msg = paste0(
        "**这一次请求没能发出去：厂商自己那边出错了（HTTP 5xx）。**\n\n",
        quote_it,
        "这不是你配置的问题，等一会儿重发通常就好。\n\n",
        "⚠️ 这条消息本身没丢。"),
      notify = "模型服务自己出错了（5xx），这一次请求没有发出去。详见对话里那条说明。"),
    # 认不出来的：照样把厂商原话落库。这一格是"再也不出现什么都没发生"
    # 那条保证的兜底，**不要**改成"静默返回 NULL"。
    list(
      kind = "other", window = NULL,
      msg = paste0(
        head, quote_it,
        "**怎么办：**\n",
        "- 到「模型服务」页把**厂商 / 模型 / API Key** 三项和厂商文档对一遍；\n",
        "- 这条消息本身没丢，改完直接重发就行。"),
      notify = "这一次请求没有发出去。详见对话里那条说明。")
  )
}

#' 把一段报错原文解析成「该把上限调成多少」
#'
#' @param err 报错原文（`rv$error`、HTTP 响应体，都行）。
#' @param range **可选**：当前 `dsapp_param_range(v, model, "max_tokens")`
#'   的结果。给了的话，解析出来的数**不比现在的上限更紧就直接返回 NULL** ——
#'   这样"非 NULL"和"点了按钮真的会变"是同一件事，界面不用自己再判一遍。
#' @return NULL，或者 `list(param = "max_tokens", max = <数值>, text = <原文片段>)`。
#'
#' ★ **宁可不给按钮，也不给一个错的**：解析不出来一律 NULL。界面上少一颗
#'   按钮，用户顶多自己翻文档；按钮给出一个错的数，用户会以为已经修好了。
dsapp_maxtok_advice <- function(err, range = NULL) {
  txt <- paste(as.character(unlist(err) %||% ""), collapse = " ")
  txt <- gsub("[\r\n\t]+", " ", txt)
  if (!nzchar(trimws(txt))) return(NULL)

  # ① 上下文类错误先出局（理由见上面 .dsapp_ctx_len_pat 那段）
  if (grepl(.dsapp_ctx_len_pat, txt, ignore.case = TRUE, perl = TRUE)) {
    return(NULL)
  }

  wins <- .dsapp_maxtok_windows(txt)
  if (!length(wins)) return(NULL)

  for (w in wins) {
    # ★ 先在**提到这个字段的那一句**里找，找不到才退到整个窗口。
    #   整段一起找的话，"temperature must be at most 2. max_tokens must be
    #   at most 65536" 会先命中左边那个 2 —— 而那是个温度上限。
    frags <- unique(c(
      Filter(function(s) grepl("tokens", s, ignore.case = TRUE),
             strsplit(w, "[;；。\\n]|(?<=[0-9])\\.\\s", perl = TRUE)[[1]]),
      w))
    for (s in frags) {
      if (!nzchar(trimws(s))) next
      hit <- NULL
      for (p in .dsapp_maxtok_bound_pats) {
        mm <- regmatches(s, regexec(p, s, ignore.case = TRUE, perl = TRUE))[[1]]
        if (length(mm) < 2L) next
        n <- suppressWarnings(as.numeric(gsub("[^0-9]", "", mm[2])))
        if (length(n) != 1L || !is.finite(n) || n <= 0) next
        hit <- list(param = "max_tokens", max = n, text = trimws(mm[1]))
        break
      }
      if (!is.null(hit)) {
        # ② 跟"现在的上限"对一下：不比它紧就是没用的话，别给按钮
        if (is.list(range)) {
          rmax <- suppressWarnings(as.numeric(range$max %||% NA_real_)[1])
          rmin <- suppressWarnings(as.numeric(range$min %||% NA_real_)[1])
          if (!is.finite(rmax) || hit$max >= rmax) return(NULL)
          if (is.finite(rmin) && hit$max <= rmin) return(NULL)
        }
        return(hit)
      }
    }
  }
  NULL
}
