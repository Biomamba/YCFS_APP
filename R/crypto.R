# =============================================================================
# 落盘凭据的加密（V13.1 item 9）
# =============================================================================
#
# 用户的原话是登录页要写这句提示：
#
#   「你的 API Key、远程服务器密码不会明文存到服务器上，
#     若使用异常请在服务商处删除API Key。」
#
# 这句话在 V6 ~ V13.0 之间是**假的**：API Key 从 V6 起就按账号存在
# users.llm_api_key 里，一个字节都没加密。整个代码库还到处写着"不落盘"，
# 而真实情况是"落盘、明文、谁能读这个 sqlite 文件谁就拿到所有人的 Key"。
#
# 用户选的那条路是「把它改成真的（加密入库）」，所以这个文件存在的唯一
# 目的就是让上面那句话从假话变成真话。
#
# ---- 挡得住什么、挡不住什么（写清楚，别让下一个人以为这是保险柜）----
#
#   挡得住：把 dsapp.sqlite3 拷走的人（备份、误传、别的租户拿到文件）。
#           密文离了钥匙串就是一堆 base64。
#   挡不住：能登服务器读 /srv/.../data/.keyring 的人。钥匙串和密文放在
#           同一台机器上，root 两样都读得到 —— 这是**设计上的边界**，
#           不是疏漏。真要挡这一类人，得把钥匙串挪到应用进程之外
#           （KMS / 环境变量由运维注入 / 每次启动手输口令），那是另一件事。
#
#   ⚠️ 所以界面上那句话不能升级成"很安全"。它现在的措辞是准确的：
#      **不会明文存到服务器上** —— 是的；**服务器管理员读得到** —— 也是的，
#      见 mod_welcome.R 里紧跟的那半句。
#
# ---- 钥匙串丢了会怎样 ----
#
#   所有已存的 Key 都解不开。这时**不能崩、也不能拿密文当 Key 发出去**
#   （那会变成一次诡异的 401，用户查不到这里来）。dsapp_sec_dec() 的做法是
#   返回 NULL + 在应用日志里留一条 —— 效果等于"这家没存过 Key"，界面会
#   让用户重填。宁可让用户重贴一次，也不要静默地发一个垃圾凭据。
# =============================================================================

DSAPP_SEC_PREFIX <- "v1:"          # 密文前缀；没这个前缀的一律当老明文读
DSAPP_KEYRING_FILE <- ".keyring"   # 放在 data_root 下，权限 0600

#' 钥匙串路径
#'
#' ⚠️ 放在 **data_root** 下，不是仓库里。仓库会被拷来拷去（部署脚本、
#'    tests 里的 make_instance.sh 都是整目录 cp），钥匙串跟着代码走等于没有。
#'    data_root 是那份"这台机器上的这份数据"，和 sqlite 同进同退。
dsapp_keyring_path <- function(cfg = dsapp_config()) {
  file.path(cfg$data_root, DSAPP_KEYRING_FILE)
}

# 进程内缓存。ashr 的会话是长命的，每次加解密都读一遍文件没必要；
# 而且读失败时我们会 keyring 置 NULL，缓存也省得反复报同一个错。
.dsapp_keyring_cache <- new.env(parent = emptyenv())

#' 取钥匙串里的那把密钥（32 字节 raw）
#'
#' 第一次调用时**生成**它。生成即落盘，权限 0600。
#' 读不到 / 内容坏了 → 返回 NULL（调用方按"解不开"处理），不抛。
dsapp_keyring <- function(cfg = dsapp_config()) {
  p <- dsapp_keyring_path(cfg)
  if (!is.null(.dsapp_keyring_cache[[p]])) return(.dsapp_keyring_cache[[p]])

  key <- NULL
  if (file.exists(p)) {
    key <- tryCatch({
      # 两种都认：32 字节裸二进制，或者 64 个 hex 字符。
      # 用 hex 写盘是为了让运维 `cat` 得动、能一眼看出"这东西存在"。
      raw <- readBin(p, "raw", n = 4096L)
      if (length(raw) == 32L) raw
      else {
        h <- gsub("[^0-9a-fA-F]", "", rawToChar(raw))
        if (nchar(h) == 64L) {
          as.raw(strtoi(substring(h, seq(1, 63, 2), seq(2, 64, 2)), 16L))
        } else NULL
      }
    }, error = function(e) {
      message("[dsapp] 读钥匙串失败（", p, "）：", conditionMessage(e))
      NULL
    })
  }

  if (is.null(key)) {
    if (file.exists(p)) {
      # 文件在、但读不出可用密钥。**不覆盖它** —— 覆盖等于把还能救的
      # 密文彻底判死刑（也许只是权限不对，运维 chmod 一下就好了）。
      message("[dsapp] 钥匙串 ", p, " 存在但无法解析（长度/编码不对）。",
              "已存的 API Key 解不开，需要用户重新填写。")
      .dsapp_keyring_cache[[p]] <- NULL
      return(NULL)
    }
    key <- tryCatch({
      k <- openssl::rand_bytes(32L)
      # 先写临时文件再 rename：写到一半被 kill 的话，rename 之前那个
      # 半截文件不会顶掉正式的名字。同一个目录下 rename 是原子的。
      tmp <- paste0(p, ".tmp")
      writeLines(paste(as.character(k), collapse = ""), tmp)
      Sys.chmod(tmp, mode = "0600")
      file.rename(tmp, p)
      Sys.chmod(p, mode = "0600")
      k
    }, error = function(e) {
      message("[dsapp] 建钥匙串失败（", p, "）：", conditionMessage(e))
      NULL
    })
  }

  .dsapp_keyring_cache[[p]] <- key
  key
}

# ---- 为什么不是直接 aes_gcm_encrypt() ---------------------------------------
#
# ⚠️⚠️ R 的 openssl 包里那个 `aes_gcm_encrypt()` **不做认证**，名字里的 GCM
#    是骗人的：`aes_gcm_encrypt(charToRaw("hello"), key, iv)` 返回的就是
#    **5 个字节**，没有 tag —— 它退化成了一条流密码。而
#    `aes_gcm_decrypt()` 拿着**错误的钥匙**不会报错、也不会返回 NULL，
#    它会**老老实实解出一段垃圾**（2026-09-16 实测：错钥匙解 "hello"
#    返回 52 72 1b 01 62，五个字节，一声不吭）。
#
#    这一条如果没发现，后果正好是我在这个文件开头说要避免的那个：
#    钥匙串换过之后，`dsapp_sec_dec()` 把垃圾当 API Key 返回，应用拿着它
#    去请求，用户看到的是服务商的 401 —— 而真正的原因（钥匙串变了）
#    在这台机器上，界面上一个字都不会提。
#
#    所以这里自己拼一个 encrypt-then-MAC：AES-CBC 加密 + HMAC-SHA256 认证明文。
#    MAC 覆盖密文，**先验 MAC 再解密**，验不过就是 NULL。
#
#    格式：v1: + base64( iv[16] || ciphertext || tag[32] )

# 从主密钥派生子密钥。两把用途不同的钥匙必须分开 —— 拿同一把去做 MAC 和
# 加密，两类原语之间的相互作用是有已知攻击面的。
.dsapp_subkey <- function(key, label) {
  openssl::sha256(c(key, charToRaw(label)))
}

#' 加密一个凭据
#'
#' 空值原样返回（NULL / "" / NA 都不该被加密成一段密文 —— 那会让
#' "这家没存过 Key" 变成"这家存了一段解不开的东西"）。
#' 加密本身失败时**返回原值**并留日志：宁可不加密，也不能把用户的 Key
#' 弄丢 —— 丢了他只会看到认证失败，找不回来。
dsapp_sec_enc <- function(x, cfg = dsapp_config()) {
  if (is.null(x) || length(x) == 0) return(x)
  x <- as.character(x)[1]
  if (is.na(x) || !nzchar(x)) return(x)
  if (startsWith(x, DSAPP_SEC_PREFIX)) return(x)   # 已经是密文，别套两层

  key <- dsapp_keyring(cfg)
  if (is.null(key)) return(x)

  tryCatch({
    iv <- openssl::rand_bytes(16L)   # CBC 的块长是 16
    ct <- openssl::aes_cbc_encrypt(charToRaw(x),
                                   key = .dsapp_subkey(key, "enc"), iv = iv)
    # ⚠️ openssl 包里**没有** hmac() 这个导出函数（`openssl::hmac` 不存在），
    #    HMAC 是 sha256() 的 key= 参数那条路：带 key 就是 HMAC-SHA256，
    #    不带就是普通摘要。
    tag <- openssl::sha256(ct, key = .dsapp_subkey(key, "mac"))
    paste0(DSAPP_SEC_PREFIX, openssl::base64_encode(c(iv, ct, tag)))
  }, error = function(e) {
    message("[dsapp] 加密失败，这一条按明文存了：", conditionMessage(e))
    x
  })
}

#' 解密一个凭据
#'
#' 三种输入，三种处理：
#'   * 老明文（没有 v1: 前缀）—— **原样返回**。V13.1 之前存进去的就是明文，
#'     迁移没跑到它也得能读，否则升级当天所有线上账号的 Key 一起失效。
#'   * 密文 —— 先验 MAC，过了才解密。
#'   * 验不过 / 解不开 —— 返回 NULL 并留日志。**绝不返回密文、也绝不返回
#'     半截垃圾**：那样用户看到的是服务商的 401，而真正的原因在这台机器上。
dsapp_sec_dec <- function(x, cfg = dsapp_config()) {
  if (is.null(x) || length(x) == 0) return(NULL)
  x <- as.character(x)[1]
  if (is.na(x) || !nzchar(x)) return(NULL)
  if (!startsWith(x, DSAPP_SEC_PREFIX)) return(x)   # 老明文

  key <- dsapp_keyring(cfg)
  if (is.null(key)) {
    message("[dsapp] 有密文要解，但钥匙串读不出来。这条 Key 只能重新填。")
    return(NULL)
  }

  body <- substring(x, nchar(DSAPP_SEC_PREFIX) + 1L)
  tryCatch({
    raw <- openssl::base64_decode(body)
    # iv(16) + 至少一个密文块(16，CBC 带填充) + tag(32)
    if (length(raw) < 64L) stop("密文长度不对")
    n <- length(raw)
    iv  <- raw[1:16]
    tag <- raw[(n - 31L):n]
    ct  <- raw[17:(n - 32L)]

    # ⚠️ 先验 MAC。这一步是**唯一**能挡住"钥匙串换过了"的地方 ——
    #    aes_cbc_decrypt 拿错钥匙同样会吐出一段垃圾来。
    want <- openssl::sha256(ct, key = .dsapp_subkey(key, "mac"))
    if (!identical(as.raw(want), as.raw(tag))) {
      stop("MAC 对不上（钥匙串被换过或丢了？）")
    }

    enc2utf8(rawToChar(openssl::aes_cbc_decrypt(
      ct, key = .dsapp_subkey(key, "enc"), iv = iv)))
  }, error = function(e) {
    message("[dsapp] 解不开一条已存的 API Key：", conditionMessage(e),
            "。这台机器上的钥匙串可能被换过或丢了，用户需要重新填写。")
    NULL
  })
}

#' 这条记录是密文吗
#'
#' 给迁移和自检用：判断"还需不需要加密一次"。
dsapp_sec_is_enc <- function(x) {
  if (is.null(x) || length(x) == 0) return(FALSE)
  x <- as.character(x)[1]
  !is.na(x) && startsWith(x, DSAPP_SEC_PREFIX)
}
