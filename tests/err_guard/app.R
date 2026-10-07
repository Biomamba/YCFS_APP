# =============================================================================
# 最小复现：observe 里一个没人接的错，会不会把用户的会话整个弄死
# =============================================================================
#
# 这个文件夹存在的唯一理由：V15.6 item 4 的结论必须**能被人自己重跑一遍**。
# 用户报的是「经常运行一半弹『与服务器的连接断了』」，查下来是 Shiny 的默认
# 行为（observe 里的软错误 = 把会话 close 掉），修法是 R/errhand.R 的
# dsapp_err_soften_session()。
#
# 跑法（见 README.md）：
#   bash tests/err_guard/run.sh 8971 render     ← 渲染炸弹：会话应该活着
#   bash tests/err_guard/run.sh 8972 observe    ← observe 炸弹：**没守卫就死**
#   bash tests/err_guard/run.sh 8973 observe 1  ← 同一颗炸弹 + 装上守卫
#
# ⚠️ 这里用的是**仓库里那个真函数**（source R/errhand.R），不是抄一份逻辑 ——
#    抄一份的话，这个测试只能证明"抄的那份对"。
library(shiny)
REPO <- Sys.getenv("DSAPP_ERR_GUARD_REPO", "/data3/biomamba/analysis/DS_App")
source(file.path(REPO, "R/utils.R"))
source(file.path(REPO, "R/errhand.R"))

LOG   <- Sys.getenv("HBLOG", "/tmp/dsapp_err_guard.log")
BOMB  <- Sys.getenv("BOMB", "render")            # render | observe | none
GUARD <- identical(Sys.getenv("GUARD", "0"), "1")

# dsapp_err_log() 要一份 cfg；这里只测错误路径，落一行到自己的日志就够
dsapp_err_log <- function(e, where = "", ...) {
  cat(sprintf("%s [%s] 接住：%s\n", format(Sys.time(), "%H:%M:%S"), where,
              conditionMessage(e)), file = LOG, append = TRUE)
  NA_character_
}

ui <- fluidPage(actionButton("btn", "点我"),
                textOutput("hb"), textOutput("rbomb"), textOutput("obomb"))

server <- function(input, output, session) {
  t0 <- Sys.time()
  n <- 0L

  # ★ 被验的就是这一行
  if (GUARD) dsapp_err_soften_session(session)
  cat(sprintf("%s === 会话开始（BOMB=%s GUARD=%d）===\n",
              format(Sys.time(), "%H:%M:%S"), BOMB, as.integer(GUARD)),
      file = LOG, append = TRUE)

  # 心跳：app.R 里那条的原样写法。它停 = 前端 16 秒后弹断连遮罩
  observe({
    invalidateLater(1000, session)
    n <<- n + 1L
    cat(sprintf("%s hb %d\n", format(Sys.time(), "%H:%M:%S"), n),
        file = LOG, append = TRUE)
  })

  # 会话结束的**唯一**判据：Shiny 判死会话时会走 onEnded
  session$onEnded(function() {
    cat(sprintf("%s ★会话结束★\n", format(Sys.time(), "%H:%M:%S")),
        file = LOG, append = TRUE)
  })

  # 页面还听不听点击
  observeEvent(input$btn, {
    cat(sprintf("%s 收到点击 #%d\n", format(Sys.time(), "%H:%M:%S"), input$btn),
        file = LOG, append = TRUE)
  })

  output$hb <- renderText(paste("hb", n))

  # 炸弹一：渲染函数里抛（Shiny 自己会兜住，画成报错卡片）
  output$rbomb <- renderText({
    invalidateLater(2000, session)
    if (BOMB %in% c("render", "both") &&
        as.numeric(difftime(Sys.time(), t0, units = "secs")) > 6) {
      stop("boom in a render")
    }
    "render ok"
  })

  # 炸弹二：observe 里抛（Shiny 默认把会话 close 掉）
  observe({
    invalidateLater(2000, session)
    if (BOMB %in% c("observe", "both") &&
        as.numeric(difftime(Sys.time(), t0, units = "secs")) > 6) {
      stop("boom in an observe")
    }
  })
  output$obomb <- renderText("observe ok")
}
shinyApp(ui, server)
