/* ===========================================================================
 * Biomamba言出法随生信APP 前端脚本
 * ===========================================================================
 * 这里刻意不做任何"把代码内容发给服务端"的事。
 *
 * 执行按钮只发一个坐标（"消息id:块序号"），代码内容由服务端回数据库重取。
 * 浏览器端能改 DOM、能改按钮上的任何属性，但改不动数据库里的那条消息，
 * 所以伪造不出"一段没被扫描过的代码"去执行。这个性质依赖前端只传坐标，
 * 别为了省一次数据库读取而把代码内容塞进请求里。
 * =========================================================================== */

/* 各输入控件的真实 id。模块会加命名空间前缀（"chat-code_action" 之类），
 * 在 JS 里硬编码前缀的话，改模块 id 就会静默失效 —— 所以由服务端在会话
 * 建立时下发一次。 */
var dsappIds = { codeAction: null, sendKey: null, input: null, pickSession: null,
                 sendBtn: null, sessionRename: null };

Shiny.addCustomMessageHandler("dsapp:init", function (m) {
  dsappIds = m;
});

/* ---- 输入法组字状态（V13.7 item 4）---------------------------------------
 *
 * 用户原话：「经常输入的是汉语，但是放到对话框里变成拼音了」。
 *
 * 根因在下面那个 Enter 发送处理器：中文输入法组字期间，textarea.value 里
 * 已经放着**没上屏的拼音**（"nihao"），而敲回车选字时浏览器派发的那个
 * keydown 一样带着 `key === "Enter"`。那四道闸门没有一道看组字状态，于是
 * ① preventDefault() 把"选字上屏"这个默认行为吃掉了（汉字根本没能上屏）；
 * ② 紧接着读到 value = "nihao"，trim 完非空，当正常消息发了出去。
 * 用户看到的就是"我打的是汉字，发出去是拼音"。
 *
 * ⚠️ 这个标志是给**鼠标那条路**兜底的：有些输入法是在 **mousedown** 那一刻
 *    才提交候选词，点"发送"按钮会抢在 compositionend 之前。键盘那条路
 *    自己有 `e.isComposing`，不依赖这个标志（但两个都要有 —— 见各自的注释）。
 *
 * ⚠️ 用**捕获阶段**注册：将来若有人在 textarea 上加了带 stopPropagation 的
 *    冒泡处理器，标志不会失同步。 */
var dsappComposing = false;
/* ★ V15.6 item 12：这个标志原来只认主输入框，而"它问你话"那个回答框
 *   （mod_chat.R 的 .dsapp-ask-box）是**另一个** textarea。中文用户在
 *   那个框里打字，回车选字同样会被当成"发送" —— 判据必须跟着一起放开。
 *   认两个：主输入框的 id，或者带 data-dsapp-enter 的通用框。 */
function dsappIsSendBox(el) {
  if (!el || el.tagName !== "TEXTAREA" && el.tagName !== "INPUT") return false;
  if (dsappIds.input && el.id === dsappIds.input) return true;
  return !!(el.dataset && el.dataset.dsappEnter);
}
document.addEventListener("compositionstart", function (e) {
  if (dsappIsSendBox(e.target)) dsappComposing = true;
}, true);
document.addEventListener("compositionend", function (e) {
  if (dsappIsSendBox(e.target)) dsappComposing = false;
}, true);

/* ---- 账号令牌（cookie）--------------------------------------------------- */

/* 令牌放在**长期 cookie** 里，而不是 localStorage：cookie 会跟着请求一起
 * 发给服务端，这样万一以后要做服务端渲染判断也是现成的；而且用户清
 * "站点数据"和清 cookie 是同一件事，不会出现"localStorage 清了 cookie
 * 没清"这种半吊子状态。
 *
 * SameSite=Lax：本站是 http 明文访问，Secure 属性加上去 cookie 会被浏览器
 * 直接丢弃（明文站点不允许 Secure）—— 那等于账号功能整个失效。所以这里
 * 只设 SameSite，不设 Secure，并在 README 里如实写明"身份靠明文 cookie",
 * 别让人误以为它是安全传输的。 */

function dsappCookie(name) {
  var parts = document.cookie ? document.cookie.split(";") : [];
  for (var i = 0; i < parts.length; i++) {
    var kv = parts[i].trim();
    if (kv.indexOf(name + "=") === 0) {
      return decodeURIComponent(kv.substring(name.length + 1));
    }
  }
  return "";
}

function dsappSetCookie(name, value, days) {
  var d = new Date();
  d.setTime(d.getTime() + (days || 365) * 24 * 60 * 60 * 1000);
  document.cookie = name + "=" + encodeURIComponent(value) +
                    "; expires=" + d.toUTCString() + "; path=/; SameSite=Lax";
}

function dsappDelCookie(name) {
  document.cookie = name + "=; expires=Thu, 01 Jan 1970 00:00:00 GMT; path=/";
}

/* ⚠️ 写完 cookie 要**读回来确认**，再回执给服务端。
 *
 *   这条回执是 2026-09-13 那个 bug 的修法。服务端登录成功之后要 reload 页面
 *   来清掉上一个账号在各模块里攒的状态，而 reload 之后新会话的身份
 *   **只剩 cookie 这一条路**。原来的写法是"发一条 setToken，紧接着 reload"
 *   —— 两条 websocket 消息虽然有序，但服务端**无从知道** cookie 有没有真的
 *   写进去：浏览器禁用或拦截 cookie（无痕窗口、第三方 cookie 拦截、企业
 *   策略）时 document.cookie 的赋值是**静默失败**的，服务端照常 reload，
 *   用户就被无声地弹回登录页 —— 而 audit_log 里记的是「登录成功」。
 *   线上就是这么报上来的，查了很久。
 *
 *   所以：写 → 读回来 → 比对 → 回执。服务端拿到 ok 才 reload；拿到 fail
 *   就明说"浏览器没保存登录状态"，不再让人对着一个假成功反复点。 */
Shiny.addCustomMessageHandler("dsapp:setToken", function (m) {
  if (!m || !m.token) return;
  dsappSetCookie("dsapp_token", m.token, m.days || 365);
  if (!m.ack) return;
  var got = dsappCookie("dsapp_token");
  Shiny.setInputValue(m.ack, { ok: got === m.token, n: m.n },
                      { priority: "event" });
});

/* ⚠️ 这个 handler **必须**写成 function (m) {...}，不能图省事写 function ()。
 *    Shiny 注册时会校验 handler.length === 1，零参函数直接抛
 *    "handler must be a function that takes one argument." —— 而且是在
 *    **顶层同步抛**，于是这个文件里它后面的代码一行都不会执行。
 *    这个 bug 的代价是：下面那个 shiny:connected 监听器压根没注册上，
 *    页面连上时不会把 cookie 交给服务端，于是"刷新一下就自动登录"整个失效，
 *    而报错只出现在浏览器控制台里 —— 服务端日志干干净净。
 *    用不到参数也要留着它。 */
Shiny.addCustomMessageHandler("dsapp:clearToken", function (m) {
  dsappDelCookie("dsapp_token");
});

/* ---- 被顶下线（V11 item 4b）-----------------------------------------------
 *
 * 服务端的心跳发现"当前那一端已经不是我了"，就发这一条。这里做两件事：
 *
 *   1. **先把 cookie 删掉再跳**。不删的话，重新打开这一页时 cookie 还在，
 *      而它里面的 nonce 已经被新那一端顶掉了 —— 服务端会拒绝自动登录
 *      （见 dsapp_user_by_token），用户看到的仍然是登录页，但浏览器每次
 *      都白跑一趟自动登录。删掉更干净，也让"登录页 + 那条说明"这个组合
 *      在任何一次后续刷新里都成立。
 *
 *   2. 用 location.replace 而不是 location.href：这一步是**被赶出去**，
 *      不该在浏览器的后退历史里留一个"刚才那一页"—— 用户按后退键回到
 *      一个已经被顶掉、点什么都无效的界面，只会更困惑。
 *
 * ?kicked=1 是给服务端看的（渲染那句"这个账号刚刚在别的地方登录了"），
 * 用完由 dsapp:cleanUrl 抹掉。 */
Shiny.addCustomMessageHandler("dsapp:kick", function (m) {
  dsappDelCookie("dsapp_token");
  window.location.replace(window.location.pathname + "?kicked=1");
});

/* 把那句说明显示出来之后，把 ?kicked=1 从地址栏抹掉。
 * 不抹的话，用户重新登录之后再点「退出登录」（那是一次 reload，地址栏
 * 还是这一条），会原样再弹一遍"你的账号在别的地方登录了"。 */
Shiny.addCustomMessageHandler("dsapp:cleanUrl", function (m) {
  if (window.history && window.history.replaceState) {
    window.history.replaceState({}, "", window.location.pathname);
  }
});

/* ---- 皮肤（V8 item 4）-----------------------------------------------------
 *
 * 服务端认的那份皮肤推下来，落两处：
 *   · <html data-skin>  —— 真正决定长相的就是它（CSS 在 www/skins.css）；
 *   · localStorage      —— 给下次刷新用。app.R 的 head 里那段内联脚本要在
 *                          **首屏绘制之前**把属性定下来，那时候服务端还没
 *                          说话，只能读 localStorage。
 *
 * ⚠️ 两处必须一起写。只写 localStorage 的话这一次不生效（要等下次刷新）；
 *    只写属性的话下次刷新会先闪一下旧皮肤。
 *
 * ⚠️ 挂 documentElement 而不是 body。Bootstrap 的变量定义在 :root（= html）
 *    上，弹窗/下拉菜单这些又挂在 body 直属 —— 只有 html 上的属性能同时
 *    罩住两者。R/skins.R 顶部有完整说明。
 *
 * ⚠️ 合法性在这里也挡一道（白名单式，只放行 [a-z0-9_-]）。服务端已经收敛
 *    过一次（dsapp_skin_norm），这里是第二道 —— 这个值会被塞进 HTML 属性，
 *    而它的来源里有一条是 localStorage（用户能改）。
 *    非法值**不改动现状**，而不是回落到 dark：服务端发的值不合法属于代码
 *    错误，静默改成另一个皮肤只会让问题更难查；保持现状至少保留现场。 */
Shiny.addCustomMessageHandler("dsapp:skin", function (m) {
  var s = (m && m.skin) ? String(m.skin) : "";
  if (!/^[a-z0-9_-]{1,24}$/.test(s)) return;
  document.documentElement.setAttribute("data-skin", s);
  try { localStorage.setItem("dsapp_skin", s); } catch (e) {}
});

/* 页面一连上就把 cookie 交给服务端。用 shiny:connected 而不是
 * shiny:bound：绑定完成时自定义消息处理器已经注册好了，但连接事件更早、
 * 也更明确地表示"可以发输入了"。
 *
 * ⚠️ 必须用 jQuery 的 $(document).on()，**不能**用原生的
 *    document.addEventListener()。
 *
 *    shiny:connected 是 Shiny 用 `$(document).trigger("shiny:connected")`
 *    发出来的**自定义**事件。jQuery 的 trigger() 只会调用 jQuery 自己绑的
 *    处理器，不会派发到 addEventListener 注册的监听器上（原生监听器只对
 *    浏览器真实派发的 DOM 事件生效）。写错的表现是：这段代码一个字都不执行、
 *    不报任何错，cookie 永远送不到服务端 —— "刷新一下就自动登录"整个失效，
 *    而服务端日志干干净净，浏览器控制台也干干净净，只能靠逐行打断点找。
 *
 *    要验证它还活着：在浏览器控制台里跑
 *        $(document).trigger("shiny:connected")
 *    然后看服务端有没有重新取到身份。 */
/* ★ V13.11 item 7：最近一次收到服务端心跳的时刻。
 *
 * ⚠️ 必须在**最前面**声明。下面有两个地方读它（看门狗）、两个地方写它
 *    （收到心跳 / 刚连上），而那几处的注册顺序和执行顺序不是一回事。
 *    写在中间的话，读它的那一侧可能在它被赋值之前就跑过一轮。 */
var dsappLastPing = Date.now();

/* 心跳间隔（服务端）和判死时间（前端）。放在一起，改一个就知道另一个
 * 该不该跟着动：判死必须**明显大于**间隔，否则网络抖一下、或者服务端
 * 正在跑一个几百毫秒的渲染，就会误报。现在 4 秒一跳、30 秒判死 ——
 * 也就是连着丢 7 拍才算数。
 *
 * ★ 2026-10-07 从 16 秒抬到 30 秒。用户原话：「服务器现在还是经常未响应，
 *   这个提示能不能显示的不要这么频繁，即使真的断了，也请间隔一段时间再提示」。
 *   16 秒在线上太容易到了：服务端正在跑一个重活（渲染报告 / 装包 / 跑模型）
 *   的时候，它**自己的事件循环就被钉住**，心跳自然停；链路抖一下丢几拍也会
 *   到线。这些情况绝大多数会自己好，而用户已经为它们被一整块遮罩吓过好几次。
 *
 * ⚠️ 判死线现在只管**"要不要开始提示"**，不再等于"铺一整页卡片" ——
 *    那是下面 DSAPP_OFFLINE_CARD_MS 的事。 */
var DSAPP_PING_MS = 4000;
var DSAPP_PING_DEAD_MS = 30000;

/* ★ 断线提示**分两档出场**（2026-10-07，同一条反馈）。
 *
 *     判死线到（30 秒）      → 只出左下角**小条**：不遮任何东西，页面照常
 *                              能看能打字，绝大多数情况它自己就消失了。
 *     再撑 DSAPP_OFFLINE_CARD_MS → 才铺那张盖住整页的大卡片。
 *
 *   为什么不一到判死线就铺卡片：那两种情况（服务端在忙 / 真的断了）在浏览器
 *   这边**分不出来**（见下面 window.dsappNet 那段），而"在忙"占绝大多数。
 *   一个只在极少数情况下才该出现的遮罩，天天出现，用户就不信它了 ——
 *   而不信的下一步就是"它弹它的、我干我的"，那时候真断了也没人看。
 *
 * ⚠️ 用户点过「先等一下」之后，这一轮**不再**自动铺卡片（dsappCardDismissed）。
 * ⚠️ 自愈那条路（真的断了、要整页重载）是**例外**：它有话要说的时候会把卡片
 *    铺出来（见 dsappHealNote）—— "它一回来这页会自己刷新"那几句必须让人
 *    看见，而且到那时离断线已经过了 DSAPP_HEAL_GRACE_MS（20 秒）。 */
var DSAPP_OFFLINE_CARD_MS = 30000;

/* 这一轮"不是 up"是从什么时候开始的（毫秒时刻；0 = 现在是 up）。
 * ⚠️ 它**跨 silent↔down 不重置**：换的只是说法，断这件事从更早就开始了。
 *    （所以不能用 dsappNet.since —— 那个每次换档都会刷新。）
 * 以及：用户这一轮点过「先等一下」没有 —— 点过就不再自动铺卡片。 */
var dsappOutageSince = 0;
var dsappCardDismissed = false;

$(document).on("shiny:connected", function () {
  Shiny.setInputValue("dsapp_cookie_token", dsappCookie("dsapp_token"),
                      { priority: "event" });
  /* 连（回）上了就把提示撤掉、把心跳计时归零 —— 网络抖一下不该逼人刷新 */
  dsappLastPing = Date.now();
  dsappOfflineHide();
  /* ★ V16.11 item 0：每次连上都重新问一遍"Shiny 那套还是我以为的样子吗"。
   *   结果只写进 dsappNet.features，这里**不做任何动作** —— item 2 才会
   *   拿 sendInput 那个字段去决定包不包。现在写它是为了让线上出问题时
   *   第一眼就能看见"到底哪一条判据不成立"。 */
  dsappOpFeatures();
  /* ★ V16.11 item 2：收口 `sendInput`（**只观测**）。装的时候会重新做一遍
   *   特征检测 —— Shiny 升版换了形状的话，失效形态是"补发没了"，
   *   而不是"页面死了"，所以每次连上都要重新问一遍。 */
  dsappOpInstall();
});

/* ---- 服务端不吭声了，必须说一声 -------------------------------------------
 *
 * ★ 这一节管两种"看起来一模一样、原因不同"的情况，判据也不一样：
 *     socket 收到 close  → shiny:disconnected 事件（下面第一个处理器）
 *     事件一直不来       → 心跳超时（本节末尾的看门狗，V13.11 item 7）
 *   后者才是用户报的那个"卡住"，原因见下面那段注释。
 */

/* ⚠️ Shiny 默认的断线提示**等于没有**。
 *
 *    它给的遮罩是个空壳：<div id="shiny-disconnected-overlay"></div> ——
 *    没有文字、没有按钮、也没有"正在重连"的通知（本应用没开
 *    session$allowReconnect）。而遮罩下面是**一整个看起来完好的页面**：
 *    输入框还能打字、按钮还是蓝的。于是用户看到的是：
 *    「页面还在，但点哪个按钮都没反应，也不报任何错。」
 *
 *    2026-09-13 线上就卡在这上面。用户报"点击登录还是停留在登录页面"，
 *    而服务端 audit_log 里**一条记录都没有** —— 点击根本没发出去（实测：
 *    断线后点按钮，websocket 新增消息数为 0）。查了半天代码，代码是好的。
 *
 *    Shiny Server 那条路（shiny-server-client，reconnect:true）自己会重连、
 *    连不上会重载页面，所以线上多数时候能自愈；但"重启那几十秒"和本地
 *    runApp 下，用户面对的就是这个假活页面。所以自己填一句话进去。
 *    见 www/app.css 里的 #dsapp-offline。 */
/* ---- 提示遮罩：两种原因，一个壳 ------------------------------------------
 *
 * kind = "disconnected" —— 连接**明确地**断了（socket 收到 close）
 * kind = "silent"       —— 连接看着还在，但服务端**不再应答**
 *
 * ★★ 为什么要有第二种（V13.11 item 7 加的）。用户报的是"页面卡住了，
 *    刷新后正常了，也不报任何错"。实测复现（tests/ui_v1311/probe_wedge.py）：
 *    把 R worker `kill -STOP` 冻住之后 ——
 *        isConnected() 一直是 true、Shiny 自带遮罩不出现、
 *        这里原来那个 shiny:disconnected 处理器**也**不触发、
 *        控制台一条报错都没有。
 *    整整 20 秒，页面看起来完全正常，点什么都石沉大海。
 *
 *    原因是所有断线检测（Shiny 的、这里原来的、Shiny Server 那套）**都挂在
 *    socket 的 close 事件上**。而对端没了、或者进程被冻住时，TCP 根本不会
 *    发 FIN/RST —— close 事件永远不来。浏览器这边**没有任何办法**从连接
 *    状态上分辨"服务端在忙"和"服务端没了"，这两件事在前端长得一模一样。
 *
 *    所以判据不能是连接状态，只能是"**它多久没跟我说话了**"。服务端每 4 秒
 *    发一次心跳（见 app.R 里那条 observe），前端 30 秒没收到就认为出事
 *    （⚠️ "认为出事" = 出左下角小条，不是铺整页卡片，见 DSAPP_OFFLINE_CARD_MS）。
 *    这条判据同时覆盖了两种原因，而且不依赖任何事件是否触发。
 *
 * ⚠️ 但心跳**测不出**"浏览器主线程被卡死"——那种情况下 setInterval 本身
 *    就不跑了。真遇到那个，页面是整个冻住的（连滚动都卡），和这里说的
 *    "页面能动、只是点了没反应"是两回事，别混。 */
/* ---- 连接状态：唯一的事实来源（V16.11 item 0）----------------------------
 *
 * ★★ 为什么要有这个（而不是继续"看那块提示在不在"）。
 *
 *    2026-10-02 线上实锤过一次：自愈是靠 `document.getElementById("dsapp-offline")`
 *    判"还断着吗"的，而看门狗会把那块提示**换成另一种**，于是自愈**自己把自己
 *    关掉了**，页面从此永远回不来（见下面 dsappHealStart 那段注释）。根因是
 *    "那块 DOM 在不在"被当成了事实来源，而它其实只是个**投影** —— 谁画的、
 *    画成什么样，都不该决定要不要救页面。
 *
 *    所以：状态只有一个写入口 `dsappNetSet()`，节点降级成它的渲染结果。
 *    `#dsapp-offline` / `#dsapp-offline-mini` / 补发闸门 / 补发前奏，全部从
 *    这里派生。
 *
 * 三档的含义（**不要**把它当成"连接好不好"的测量 —— 前两档在浏览器这边
 * 分不出来，见上面那段注释）：
 *    "up"      连接正常（或者至少没有任何证据说它不正常）
 *    "silent"  心跳 30 秒没来。**是猜测**：服务端可能只是忙
 *    "down"    socket 收到了 close（或者服务端明确答说断）—— **硬证据**
 *               ⚠️ 在线上它还有个更准的含义：shiny-server-client 已经试着重连
 *               15 秒（reconnectTimeout 默认 15000）**并且放弃了**。那 15 秒里
 *               `isConnected()` 一直是 true、这个事件也不触发，传输层自己在
 *               缓冲消息（BufferedResendConnection）。那一段**不归我们管**，
 *               见 V16.11 item 2 的收口点注释。 */
window.dsappNet = {
  state: "up",     /* "up" | "silent" | "down" */
  since: 0,        /* 进入当前状态的时刻 */
  pending: 0,      /* 待补发的写操作条数（item 4 起用） */
  features: null   /* 传输层特征检测结果，见 dsappOpFeatures() */
};

function dsappNetSet(state, why) {
  var n = window.dsappNet;
  if (n.state === state) return;
  /* ★ 断电时钟（2026-10-07）。放在**这里**而不是各个 show/warn 里：状态只有
   *   这一个写入口，时钟跟着它走就不可能对不上（V15.12 那次"自愈看节点"的
   *   教训就是同一件事 —— 别让第二个地方各自记一份"现在是什么情况"）。
   *
   *   ⚠️ 判据分两句，缺一不可：
   *     · 离开 up 的那一刻开始计时；
   *     · silent → down 这种**中途换档不算新的一轮**（不重置）—— 换的只是
   *       说法，断这件事从更早就开始了。要是用下面那个 n.since，每换一次档
   *       就重新数 30 秒，卡片会越推越远。
   *     · 回到 up 才算这一轮结束：时钟归零、"先等一下"也一并作废。 */
  if (state === "up") {
    dsappOutageSince = 0;
    dsappCardDismissed = false;
  } else if (n.state === "up") {
    dsappOutageSince = Date.now();
  }
  n.state = state;
  n.since = Date.now();
  /* 状态翻转很少见（一次断线就两条），留着比去掉有用得多 ——
   * 线上排查"到底哪一下判错了"全靠它。 */
  console.log("[dsapp] 连接状态 → " + state + "（" + why + "）");
}

/* ---- 传输层特征检测（V16.11 item 0）--------------------------------------
 *
 * ⚠️ 现在**只记录，不动作**。它存在的理由是 item 2 要包 `sendInput`，
 *    而那个函数是 Shiny 内部对象上的方法：Shiny 升版换了形状的话，
 *    包装会**静默**地包错东西（症状是"补发没了"，不是"页面死了"）。
 *    所以每次 `shiny:connected` 都要重新问一遍"它还是我以为的那个样子吗"。
 *
 * 三个判据各自的用处：
 *   sendInput   —— item 2 的收口点本体在不在
 *   version     —— 出了事第一句话要问"你那边 Shiny 几点几"。
 *                  ⚠️ 它在 **`Shiny` 对象自己**身上（shiny.js:25168 那句
 *                  `this.version = "1.10.0"` 在 `ShinyClass` 的构造函数里），
 *                  **不在** `Shiny.shinyapp` 上 —— 第一版写成
 *                  `app.version` 取回来是 null，白记一个字段。
 *   serverClient—— 传输层是不是 shiny-server-client。**本地 runApp 没有它**，
 *                  而 `BufferedResendConnection` 那套 15 秒缓冲/去重只在线上有
 *                  ⇒ 本地验不了的东西，靠这个字段在线上认出来。
 *                  判据用它给连接对象打的 `allowReconnect` 标记
 *                  （shiny-server-client.js:1372/1385/1387）。
 *   secure      —— 明文 http 下 `crypto.randomUUID` 是 undefined（本文件
 *                  dsappCopyText 那段已经在为同一件事打补丁），
 *                  item 4 拼 op key 要走兜底路径，这条是它的现场证据。 */
function dsappOpFeatures() {
  var f = { at: Date.now(), sendInput: false, version: null,
            serverClient: false, secure: false, randomUUID: false, err: null };
  try {
    var app = (window.Shiny && window.Shiny.shinyapp) || null;
    f.sendInput    = !!(app && typeof app.sendInput === "function");
    f.version      = (window.Shiny && window.Shiny.version) || null;
    f.serverClient = !!(app && app.$socket &&
                        typeof app.$socket.allowReconnect !== "undefined");
    f.secure       = !!window.isSecureContext;
    f.randomUUID   = (typeof crypto !== "undefined" &&
                      typeof crypto.randomUUID === "function");
  } catch (e) { f.err = String(e); }
  window.dsappNet.features = f;
  return f;
}

/* ---- 写操作的唯一漏斗（V16.11 item 2）--------------------------------------
 *
 * ★★ 收口点为什么是 `Shiny.shinyapp.sendInput`，而**不是** `Shiny.setInputValue`：
 *    查过 shiny.js（1.10.0）—— `Shiny.setInputValue`（:25431）只被本应用**手写的
 *    20 处**调用命中；原生绑定（发送按钮、Enter、DT 勾选、每一个 selectize……）
 *    走的是 `InputBatchSender.setInput` → `_sendNow`，**压根不碰那个公开函数**。
 *    两条路真正的唯一汇合点是 `Shiny.shinyapp.sendInput(values)`。三处硬证据：
 *      · `_sendNow()` 里写的是 `this.shinyapp.sendInput(currentData)`
 *        （shiny.js:19190）—— **属性访问**，不是初始化时抓走的函数引用
 *        ⇒ 在实例上替换**能生效**（抓引用的话这整套都是空的）；
 *      · 全文件里 `method: "update"` 只出现**一次**（shiny.js:23751），就在
 *        `sendInput` 里 ⇒ 没有第二条路绕过它发输入；
 *      · 它拿到的还是**结构化对象** `{inputId: value}`（`$sendMsg` 拿到的已经
 *        是 JSON 串或 Blob，在那层解析等于自己把协议重实现一遍）。
 *    ⚠️ 上传**不走这里**（`makeRequest("uploadInit")` → 原生 XHR），item 9 单独管。
 *
 * ⚠️⚠️ **只观测，不拦、不改、不排队。** item 2 的全部产出就是这个环形日志。
 *    真正"拦下来"是 item 4 的事，而那一步要先把"哪些 input 算一个写操作"用
 *    **真数据**看清楚 —— 现在就去拦是在猜。
 *
 * ⚠️ 爆炸半径必须是零：这个函数包在**每一个**按钮的事件处理器底下。记账抛异常，
 *    轻则丢一条记录，重则把整页按钮一起带哑。所以三条防线：
 *      ① 记账体整个包在 try/catch 里；
 *      ② `orig.apply` 在 catch **外面**，无论记不记得成，原路永远照走；
 *      ③ 连续出错 20 次就自己卸载，并 console.error 喊一声 —— 宁可没有补发，
 *         也不能有一个"某些按钮没反应"的页面。
 */
var DSAPP_OP_LOG_MAX = 500;      /* 环形上限：只留最近 500 条，不涨内存 */
window.dsappOpLog = [];
var dsappOpErrN = 0;

/* 值的**形状**，不是值本身。
 * ⚠️ 刻意不记内容：这条日志活在页面里，而经过它的东西包括设置页的 api_key、
 *    入口页的口令。记长度/类型足够区分"按钮计数器加一"和"文本框内容"，
 *    又不会把凭据留在一个谁都能 dump 的数组里。 */
function dsappOpShape(v) {
  if (v === null) return "null";
  var t = typeof v;
  if (t === "string") return "s" + v.length;
  if (t === "number" || t === "boolean") return String(v);
  if (Object.prototype.toString.call(v) === "[object Array]") return "a" + v.length;
  return t;
}

function dsappOpObserve(values) {
  var keys = [];
  for (var k in values) {
    if (Object.prototype.hasOwnProperty.call(values, k)) {
      keys.push(k + "=" + dsappOpShape(values[k]));
    }
  }
  window.dsappOpLog.push({ at: Date.now(), keys: keys });
  if (window.dsappOpLog.length > DSAPP_OP_LOG_MAX) window.dsappOpLog.shift();
}

function dsappOpUnwrap(app, orig) {
  try {
    if (app.sendInput && app.sendInput.__dsappWrapped === true) app.sendInput = orig;
  } catch (e) { /* 卸不掉也不能再抛 —— 这里已经在异常路径上了 */ }
  try { window.dsappNet.wrapped = false; } catch (e) {}
}

function dsappOpWrapSendInput() {
  try {
    var app = (window.Shiny && window.Shiny.shinyapp) || null;
    if (!app || typeof app.sendInput !== "function") return false;
    /* 幂等：每次 shiny:connected 都会调一遍，装过就别套第二层
     * （套两层的话每条记录会记两次，而且 orig 指向包装过的那个）。 */
    if (app.sendInput.__dsappWrapped === true) return true;
    var orig = app.sendInput;
    var wrapped = function (values) {
      /* ⚠️ 这两句的**顺序和位置**都别动。 */
      try { dsappOpObserve(values); }
      catch (e) {
        dsappOpErrN++;
        if (dsappOpErrN >= 20) {
          console.error("[dsapp] 记账连续出错 " + dsappOpErrN + " 次，卸掉 " +
                        "sendInput 包装。页面功能不受影响，只是断线补发那条路没了。", e);
          dsappOpUnwrap(app, orig);
        }
      }
      return orig.apply(this, arguments);
    };
    wrapped.__dsappWrapped = true;
    wrapped.__dsappOrig = orig;
    app.sendInput = wrapped;
    window.dsappNet.wrapped = true;
    console.log("[dsapp] 已收口 Shiny.shinyapp.sendInput（只观测，不拦）");
    return true;
  } catch (e) {
    console.error("[dsapp] 收口 sendInput 失败（功能不受影响）", e);
    return false;
  }
}

/* ⚠️ `Shiny.shinyapp` 是 `initShiny()`（DOM ready）里才建的，app.js 顶层求值时
 *    还不存在 —— 所以**不能在文件顶层装**。主路是 shiny:connected（下面那个
 *    处理器里调）；这个轮询是兜底，防的是"connected 已经放过去了、而那一刻
 *    shinyapp 还没建好"这种顺序意外。装上就停，最多试 5 秒。 */
function dsappOpInstall() {
  if (dsappOpWrapSendInput()) return;
  var tries = 0;
  var t = setInterval(function () {
    tries++;
    if (dsappOpWrapSendInput() || tries >= 100) clearInterval(t);
  }, 50);
}

function dsappOfflineHide() {
  /* ⚠️ 顺序要紧：**先**改状态，**再**动节点。反过来的话，万一中间抛了，
   *    节点没了而状态还停在"断着"，自愈会一直空转到刹车踩死。 */
  dsappNetSet("up", "dsappOfflineHide");
  /* （这一轮的断电时钟和"先等一下"由上面那句 dsappNetSet("up") 一起归零，
   *   见那里的注释 —— 状态只有一个写入口，收尾也只在那一处。） */
  var d = document.getElementById("dsapp-offline");
  if (d && d.parentNode) d.parentNode.removeChild(d);
  dsappOfflineMiniClear();
}

/* ---- 断线状态条（V16.11 item 1）--------------------------------------------
 *
 * ★ 这一节补的是一个**会骗人**的洞。「先等一下」那颗按钮以前直接调
 *   dsappOfflineHide() —— 把盖住整页的卡片**整个删掉**。删完之后页面看着
 *   完好无损，用户接着打字、点发送、点运行，而那些点击全部打进一个死
 *   socket（`$sendMsg` 把它们 push 进一个只在 `socket.onopen` 里 flush 的
 *   内存数组，而本应用从没调过 `session$allowReconnect` ⇒ 那个数组到整页
 *   重载为止都不会有人来排空）。
 *   于是"提醒"变成了"骗人"—— 比一开始就挡住他更糟：**他以为没事**。
 *
 * 拆成两件事，语义完全不同：
 *   dsappOfflineDismiss() —— 用户说"我先等着"。大卡片收成左下角一条**常驻**
 *                            小条；状态**一个字不改**（还是断着），页面照常
 *                            能看能打字，自愈照跑，item 4 的补发队列照记。
 *   dsappOfflineHide()    —— 真的好了（心跳回来了 / 重连上了 / 自愈重载后）。
 *                            删卡片、删小条、状态归 up。
 *
 * ⚠️ 小条**在 = 断线状态还在**。它同时是 item 4 那个补发队列的闸门指示灯：
 *    "还有东西没送到"和"还没好"必须是同一件事的两种说法，不能各说各的 ——
 *    所以小条由状态派生，不由用户那一下点击派生。
 *
 * ⚠️ 小条**不遮鼠标**（CSS 里 `pointer-events:none`，只有那颗「详情」例外）。
 *    它不是遮罩，是提示；能不能点页面由状态决定（网断了页面本来也点不动，
 *    但那是服务端的事，前端不该再叠一层假的）。 */
function dsappOfflineMini(kind) {
  var m = document.getElementById("dsapp-offline-mini");
  /* 原因没变就不重画 —— 同 dsappOfflineShow 里那句，防鼠标停在
   * 正在被删掉的按钮上。 */
  if (m && m.getAttribute("data-kind") === kind) return;
  if (m && m.parentNode) m.parentNode.removeChild(m);
  m = document.createElement("div");
  m.id = "dsapp-offline-mini";
  m.setAttribute("data-kind", kind);
  /* ⚠️ 这里是 HTML 字符串，不是 Markdown（同 dsappOfflineShow）。
   *    转圈那个 span 的动画在 app.css 里，`prefers-reduced-motion` 下会停。 */
  m.innerHTML =
    '<span class="dsapp-offline-spin" aria-hidden="true"></span>' +
    '<span class="dsapp-offline-mini-text">' +
      (kind === "silent" ? "服务端没有响应，在等它回来…"
                         : "与服务器断开了，在等它回来…") +
    '</span>' +
    /* 只让这一颗能点：用户把卡片收起来了，得留条路能再看见全文
     * （比如"正在等服务器回来"后面那段话，或者重试次数用尽那条）。 */
    '<button type="button" class="dsapp-offline-mini-btn"' +
      ' onclick="dsappOfflineShow(\'' + kind + '\')">详情</button>';
  document.body.appendChild(m);
}

function dsappOfflineMiniClear() {
  var m = document.getElementById("dsapp-offline-mini");
  if (m && m.parentNode) m.parentNode.removeChild(m);
}

function dsappOfflineDismiss() {
  /* ★ 记下"用户这一轮不想看卡片了"。没有这一句的话，DSAPP_OFFLINE_CARD_MS
   *   一到，看门狗会把卡片**再铺回来** —— 那颗按钮又白点了（和 V16.11 item 1
   *   修掉的那个洞形状一样：用户明确表达过的意思被自动机制盖掉）。
   *   小条**照旧挂着**：它表示"还没好"，那件事没有被这一下点击改变。 */
  dsappCardDismissed = true;
  /* kind 从**状态**推，不从被点的那块卡片推 —— 卡片上的 data-kind 是渲染
   * 结果，状态才是事实（同 dsappHealStart 里那条注释）。 */
  dsappOfflineMini(window.dsappNet.state === "silent" ? "silent" : "down");
  var d = document.getElementById("dsapp-offline");
  if (d && d.parentNode) d.parentNode.removeChild(d);
}

/* ★★ 判死线到了：**先只说一句**（左下角小条），不铺卡片。见 DSAPP_OFFLINE_CARD_MS。
 *
 * ⚠️ 与 dsappOfflineShow 的分工（两条路都要卡片，但**时机不同**）：
 *      dsappOfflineWarn —— "刚发现不对劲"：只出小条。
 *      dsappOfflineShow —— "把卡片铺出来"：用户点「详情」、自愈有话要说、
 *                          或者断够久了（看门狗里那条）—— 三条路。
 * ⚠️ 卡片**已经**铺着的时候走 Show 那条：原因变了要换卡片，没变就什么都不做
 *    （那个函数自己会早退）。
 *
 * ⚠️ 卡片那一档的 data-kind 是 "silent" / "disconnected"，小条那一档是
 *    "silent" / "down"（小条那份从**状态**推，见 dsappOfflineMini）——
 *    这个不对称是原来的约定（卡片是"发生了什么"，小条是"现在什么状态"），
 *    这里按原样接着用，别在两条路上写同一个词。 */
function dsappOfflineWarn(kind) {
  if (document.getElementById("dsapp-offline")) {
    dsappOfflineShow(kind);
    return;
  }
  dsappNetSet(kind === "silent" ? "silent" : "down", "dsappOfflineWarn");
  dsappOfflineMini(kind === "silent" ? "silent" : "down");
}

/* 断着**够久**了 → 才把盖住整页的卡片铺出来（看门狗每 2 秒问一次）。
 *
 * ⚠️ 单独抽成一个函数只有一个理由：让"判死 ≠ 铺卡片"这件事在源码里**看得见**。
 *    自检的判据是"看门狗那一段里不许出现 dsappOfflineShow" —— 写回一行 if
 *    就说不清了。
 *
 * ⚠️ 三个条件缺一不可：
 *   · dsappCardDismissed —— 用户点过「先等一下」，这一轮不再自动铺
 *     （没有它，那颗按钮在 CARD_MS 之后又被自动机制盖掉 = 白点）；
 *   · dsappOutageSince > 0 —— 得真的处在"不是 up"的一轮里（0 表示现在是 up，
 *     正常不该走到这儿，真走到了就是状态坏了，宁可什么都不做）；
 *   · 撑够 DSAPP_OFFLINE_CARD_MS —— 从**离开 up 的那一刻**起算，silent↔down
 *     换档不重置（见 dsappNetSet）。
 *
 * 幂等：dsappOfflineShow 对同一个 kind 会早退，所以每 2 秒调一次是安全的。 */
function dsappOfflineEscalate(st) {
  if (dsappCardDismissed || !(dsappOutageSince > 0)) return;
  if (Date.now() - dsappOutageSince < DSAPP_OFFLINE_CARD_MS) return;
  dsappOfflineShow(st === "silent" ? "silent" : "disconnected");
}

function dsappOfflineShow(kind) {
  /* ⚠️ 同样先改状态。注意这里**不早退** —— 下面那句"原因没变就直接 return"
   *    是防鼠标点空的（别每 2 秒重画一次），但状态该写真得写：
   *    节点可能已经被"先等一下"收成小条了，那时它是 null，而状态还是断着。 */
  dsappNetSet(kind === "silent" ? "silent" : "down", "dsappOfflineShow");
  /* ★ 卡片上屏了，用户那次「先等一下」到此为止 —— 下一轮（比如状态又变了、
   *   或者界面被藏起来之后再来一次）该弹还是要弹，不能一直哑着。 */
  dsappCardDismissed = false;
  var d = document.getElementById("dsapp-offline");
  /* 已经挂着一块了：只在**原因变了**的时候换掉，否则每 2 秒重画一次，
   * 用户的鼠标会停在正在被删掉的按钮上。 */
  if (d && d.getAttribute("data-kind") === kind) return;

  /* ⚠️ 这里是 HTML 字符串，**不是** Markdown：想加粗只能用 <b>，
   *    写 `**这样**` 会原样显示成带星号的字。（mod_lit.R 里同一个坑。） */
  var silent = (kind === "silent");
  var body = silent
    ? '服务端有一会儿没回应了。可能是网络断了，也可能是它在忙一个很重的活' +
      '（比如装包、跑模型）—— 这两种情况从浏览器这边<b>分不出来</b>。<br>' +
      '现在这个页面上的按钮<b>点了不会有任何反应</b>。'
    : '应用可能刚重启或更新过。现在这个页面上的按钮' +
      '<b>点了不会有任何反应</b>。';

  /* ★ V16.11 item 1：大卡片回来的时候，小条必须让位。
   *   两条路会产生"两个指示同时在"：① 用户先"先等一下"收成小条，之后
   *   （silent → disconnected）原因变了要换大卡片；② 用户点小条上的「详情」。
   *   ⚠️ 小条是独立节点（不叫 #dsapp-offline），上面那句"原因没变就 return"
   *   管不着它 —— 漏了这句就是"左下角说断着、中间弹一张卡片说断着"。 */
  dsappOfflineMiniClear();
  if (d) d.parentNode.removeChild(d);
  d = document.createElement("div");
  d.id = "dsapp-offline";
  d.setAttribute("data-kind", kind);
  d.innerHTML =
    '<div class="dsapp-offline-card">' +
      '<div class="dsapp-offline-title">' +
        (silent ? "服务端没有响应" : "与服务器的连接断了") +
      '</div>' +
      '<div class="dsapp-offline-body">' + body + '</div>' +
      (silent
        ? '<div class="dsapp-offline-body">如果它只是在忙，等它跑完这里会' +
          '<b>自己消失</b>，不用刷新。</div>'
        : '') +
      '<div class="dsapp-offline-actions">' +
        // 「继续等」只对 silent 有意义：那种情况下服务端可能只是慢，
        // 等下去是对的选择。disconnected 那种是真断了，只能刷新。
        /* ⚠️⚠️ 这颗**绝不能**接回 dsappOfflineHide()（V16.11 item 1 修的洞）：
         *    那样按下去 = 把卡片删掉、状态归 up、页面看着一切正常，而
         *    socket 还死着。用户以为"我选择继续等，所以它没事了"，于是接着
         *    打字点发送，全打进那个没人排空的池子。接 dsappOfflineDismiss()：
         *    收成左下角小条，状态不变 —— 等下去这个选择被尊重了，"还在断着"
         *    这个事实也还在。 */
        (silent
          ? '<button type="button" class="btn btn-outline-secondary"' +
            ' onclick="dsappOfflineDismiss()">先等一下</button>'
          : '') +
        /* ★ V15.12 item 2：手动刷新要**清零自动重试的账**。不清的话，刹车
         *   踩下去之后用户点一次刷新，新页面一加载就发现自己"已经失败 3 次"，
         *   下一次断线连试都不试 —— 一个自动机制把人的手动操作也一起堵死了。
         *   人是自己决定再试一次的，账就该从这一下重新算。 */
        '<button type="button" class="btn btn-primary"' +
          ' onclick="dsappHealReset();window.location.reload()">刷新页面</button>' +
      '</div>' +
    '</div>';
  document.body.appendChild(d);
}

$(document).on("shiny:disconnected", function () {
  /* ★ 2026-10-07：这里原来直接铺整页卡片。现在跟判死那条一样**先出小条**
   *   （见 DSAPP_OFFLINE_CARD_MS）—— socket 刚收到 close 的那一秒，
   *   shiny-server-client 还在替我们重连（reconnectTimeout 15 秒），
   *   一大半的 close 根本轮不到用户看见。真回不来的话，自愈那张卡片
   *   在 20 秒后照样会铺出来（dsappHealNote），一句信息都不少。 */
  dsappOfflineWarn("disconnected");

  /* 兜底：这块提示**盖住整页**，所以必须有第二条路把它撤掉。
   * 上面 shiny:connected 那条是主路，但重连的路径不止一条（Shiny Server 的
   * shiny-server-client 走的是自己那套）。万一它没触发，用户就被永久挡在
   * 门外了 —— 一个"提醒"变成"锁死"是最糟的结果。所以自己盯着连接状态。 */
  var t = setInterval(function () {
    /* ⚠️ 读**状态**（V16.11 item 1）。原来是读卡片上的 data-kind ——
     *    小条一出现（虽然 disconnected 那一档没有「先等一下」，但 silent
     *    收成小条之后再转成 disconnected 时卡片可能正被换掉）这里就会误判
     *    "已经不是断线了"而收工，把恢复探测整个撤掉。状态不会说谎。 */
    if (window.dsappNet.state !== "down") { clearInterval(t); return; }
    if (window.Shiny && Shiny.shinyapp && Shiny.shinyapp.isConnected()) {
      clearInterval(t);
      dsappOfflineHide();
    }
  }, 2000);

  /* 上面那条只管"能连回来的"情况。连不回来的（worker 被回收了）交给
   * 自愈：宽限期 → 探活 → 整页重载。见下面那段注释。 */
  dsappHealStart();
});

/* ---- 断线自愈（V15.9 item 1）---------------------------------------------
 *
 * 2026-10-02 线上（Biomamba_ceshi 那个号）：用户正看着一条刚跑完的回复，
 *   网络抖了一下 → socket 断 → **5 秒后 Shiny Server 把这个 worker 回收了**
 *   （`app_idle_timeout` 默认就是 5 秒）→ 那块"与服务器的连接断了"的提示
 *   从此永远挂在那儿。用户点了刷新才回去。
 *
 * ⚠️ 为什么上面那段"兜底轮询"救不了：它撤提示的条件是 `isConnected()`。
 *    worker 一旦被回收，这个页面**再也连不回去了** —— 那个条件永远不会成立，
 *    提示就是终局。而 Shiny Server 注入的 shiny-server-client 只管**传输层**
 *    重连（它会重新连上一个**新**的 worker、开一个**新**的 session），它不会
 *    把老页面接回去。这个应用从来没调过 `session$allowReconnect`，Shiny 自己
 *    那套"断线重连、保留 session"也就没开。
 *
 * 所以这里**必须**有"整页重载"这一条路 —— 只靠前端状态永远回不来。
 *   判据用 fetch 探一下应用本体：**只要请求以任何状态码答回来**（200、404、
 *   500 都算），就说明服务器活着、重载有意义；连不上（网络异常）就闭嘴等
 *   下一拍。⚠️ 不能只看 `navigator.onLine`：服务器进程死掉时它照样是 true，
 *   那会刷出一张浏览器的"无法访问此网站"——比现在这块说明难看得多，而且
 *   用户会以为应用坏了。
 *
 * ⚠️⚠️ 只对 `disconnected` 那种动手，**绝不碰 `silent`**。
 *   silent 是"服务端有一会儿没说话"，很可能是它正在跑一个很重的活
 *   （装包 / 跑模型）。那种情况下**重载 = 把用户正在跑的东西扔掉**，
 *   而它本来会自己好。这两件事在浏览器这边长得像，后果却相反。
 *
 * ⚠️ 宽限期不能省。socket 断掉和"worker 被回收"之间隔着 5 秒，而
 *   shiny-server-client 自己会在这段时间里试着重连（reconnectTimeout 15 秒）。
 *   宽限期比它长，短抖动就轮不到重载出场 —— 让原本就会好的情况自己好。 */
var DSAPP_HEAL_GRACE_MS = 20000;    /* 抖动的话 shiny-server-client 自己就接上了 */
var DSAPP_HEAL_EVERY_MS = 4000;     /* 宽限期过了之后，每 4 秒问一次服务器 */
var DSAPP_HEAL_MAX = 3;             /* 连着自动刷这么多回还是断，就别刷了 */
var DSAPP_HEAL_OK_MS = 180000;      /* 连接**连着好了这么久**才把账清零 */
var DSAPP_HEAL_BACKOFF_MS = 20000;  /* 每失败一轮，下一次多等这么久 */
var dsappHealTimer = null;

/* 重载次数记在 sessionStorage 里（**不是** localStorage：换标签页另算）。
 *
 * ⚠️⚠️ 「连着几次」的口径 —— V15.12 item 2 改的就是这里，别改回去。
 *
 * 原来是"最近 3 分钟以内刷了几次"（滑动窗口）。2026-10-03 线上量出来那个
 * 口径**永远数不到 3**：uid=1 的页面每 ~120 秒整页重载一次，任意 180 秒的
 * 窗口里最多只装得下 2 次 —— 刹车形同虚设，页面就这么无限重载下去
 * （`data/logs/auth.log` 里 15:49→16:51 一刻没停）。
 *
 * 现在换成**只会被"好起来"清零**的计数：每自动刷一次记一笔，只有连接真的
 * **连续**好了 DSAPP_HEAL_OK_MS 才把账清空。于是"刷完就断、断完就刷"这种
 * 循环攒得起来，第 4 次就停手；而"网络偶尔抖一下、刷完能好好用"的情况，
 * 中间好够 3 分钟就重新开始数，不会被冤枉。
 *
 * ⚠️ 光有计数还不够：**手动**刷新要清零（见 dsappOfflineShow 里那个按钮）。
 *    人是自己决定再试一次的，不该被上一轮的账挡在门外。 */
function dsappHealStamps() {
  try {
    var a = JSON.parse(sessionStorage.getItem("dsapp_heal") || "[]");
    return Object.prototype.toString.call(a) === "[object Array]" ? a : [];
  } catch (e) { return []; }
}
function dsappHealCount() {
  return dsappHealStamps().length;
}
function dsappHealStrike() {
  var a = dsappHealStamps();
  a.push(Date.now());
  try { sessionStorage.setItem("dsapp_heal", JSON.stringify(a)); } catch (e) {}
}
function dsappHealReset() {
  try { sessionStorage.removeItem("dsapp_heal"); } catch (e) {}
}
function dsappHealCancel() {
  if (dsappHealTimer) { clearInterval(dsappHealTimer); dsappHealTimer = null; }
}

/* 连接**连续**好了 DSAPP_HEAL_OK_MS → 这一轮过去了，把账清零。
 *
 * ⚠️ 判据是 `isConnected()` 一直为真，不是"页面打开够久"：断着的那段不算数，
 *    否则"打开 3 分钟、断了 5 次"会被当成"好了"，刹车又白设了。
 * ⚠️ 用 setInterval 自己看，不挂到 heartbeat 上：心跳消息是**服务端**发的，
 *    连接断着的时候它本来就不会来，拿它当"好没好"的时钟正好反了。 */
var dsappHealOkSince = null;
setInterval(function () {
  var up = !!(window.Shiny && window.Shiny.shinyapp &&
              window.Shiny.shinyapp.isConnected());
  if (!up) { dsappHealOkSince = null; return; }
  var now = Date.now();
  if (dsappHealOkSince === null) { dsappHealOkSince = now; return; }
  if (now - dsappHealOkSince >= DSAPP_HEAL_OK_MS) {
    dsappHealReset();
    dsappHealOkSince = now;   /* 别每 5 秒写一次 sessionStorage */
  }
}, 5000);
/* ⚠️ 只改**正文那一段**，不碰标题、不碰按钮，也不重画整块 ——
 *    dsappOfflineShow 里那句"原因没变就直接 return"是防鼠标点空的，
 *    从外面重画等于把它绕过去。 */
function dsappHealNote(msg) {
  /* ★ 2026-10-07：卡片现在是**延迟**出现的（判死和断线都只先出小条），而自愈
   *   第一次说话是在 DSAPP_HEAL_GRACE_MS 之后 —— 那一刻卡片很可能还没铺，
   *   这几句话就写进空气里了。所以这里先把它铺出来。
   *
   *   这也正是"真的断了"那一档的出场时机：自愈只在 disconnected 上跑，
   *   而它要等过宽限期才开口 ⇒ 卡片大约在断线 20 秒后出现，**不是**断线那
   *   一瞬间（用户要的"间隔一段时间再提示"；那 20 秒里挂着的是小条）。
   *
   * ⚠️ 这一句会**盖过**用户点过的「先等一下」（dsappOfflineShow 里会把它
   *    归零）。这是故意的，而且只有一条路能走到：用户先在 silent 那一档按了
   *    「先等一下」，之后 socket 才真的死掉。那种情况下这张卡片说的是**新的、
   *    不一样的话**（真断了 + 这一页马上会自己刷新），不告诉他才是真坑。
   *    注意 disconnected 那一档的卡片**没有**「先等一下」—— 正在自愈时用户
   *    按不掉它，所以不存在"按了又被盖回来"的循环。 */
  if (!document.getElementById("dsapp-offline"))
    dsappOfflineShow(window.dsappNet.state === "silent" ? "silent"
                                                       : "disconnected");
  var b = document.querySelector("#dsapp-offline .dsapp-offline-body");
  if (b) b.innerHTML = msg;
}

function dsappHealStart() {
  dsappHealCancel();
  var t0 = Date.now();
  /* ★ V15.12 item 2：这次是第几轮（跨整页重载累计，见上面 dsappHealStamps）。
   *   两个用处：决定刹车踩不踩，以及退避等多久。 */
  var fails = dsappHealCount();
  /* ⚠️ 退避不能省。链路正堵着的时候立刻再要一遍整页，等于把刚排空的发送
   *    队列又灌满 —— 上一轮就是这么死的。多等一轮，让积压先排掉。 */
  var grace = DSAPP_HEAL_GRACE_MS + fails * DSAPP_HEAL_BACKOFF_MS;
  dsappHealTimer = setInterval(function () {
    /* 连接好了（重连成功 / 用户自己刷了）→ 收工。
     *
     * ⚠️⚠️ 这里**读状态位，不读 DOM**。V15.12 之前写的是"看 #dsapp-offline
     *    在不在"，和更早那版写 `kind !== "disconnected"` 是同一类错：
     *    把**投影**（那块提示画没画、画成哪一档）当成了事实来源。
     *    2026-10-02 的实锤就是看门狗把提示换成 silent 之后自愈自己收工了。
     *    现在 `dsappNet.state` 是唯一写入口，节点只是它的渲染结果 ——
     *    谁画的、写着哪几个字、有没有被"先等一下"收成小条，都不影响这一句。
     *
     * ⚠️ 判据必须是 `=== "up"` 而不是 `!== "down"`：silent 也**没有**恢复，
     *    只是换个说法（"可能是忙"），那种情况下照收工就是同一类错。 */
    if (window.dsappNet.state === "up") { dsappHealCancel(); return; }
    if (window.Shiny && Shiny.shinyapp && Shiny.shinyapp.isConnected()) {
      dsappHealCancel(); return;
    }
    if (Date.now() - t0 < grace) return;

    if (fails >= DSAPP_HEAL_MAX) {
      /* 停手，但要把话说清楚。这一段**不能**写成"服务器多半还没起来"——
       * 实测那个号是"服务器好好的、只是这一段的链路太慢，整页怎么也加载
       * 不完"，两句话指的方向完全相反，用户会跑去问运维。也说清楚为什么
       * 不再自动重试（每刷一次就要重下一整页，只会让它更堵）。 */
      dsappHealNote('这一页已经自动重试 ' + DSAPP_HEAL_MAX + ' 次，每次都在加载' +
        '完之前又断了 —— 多半是这一段的网络太慢或者不稳，再自动重试也是一样。' +
        '<br>等网络好一点的时候，点下面那个<b>刷新页面</b>再试。' +
        '（正在跑的任务不受影响，跑完的结果还在。）');
      dsappHealCancel();
      return;
    }
    dsappHealNote('正在等服务器回来。它一回来这页会<b>自己刷新</b>，不用管它。' +
      '（正在跑的任务不受影响，跑完的结果还在。）');

    /* ⚠️ 加超时：服务器在冷启动时这个请求会**挂着**（R 进程起来要几秒到几十秒），
     *    不设上限的话这一拍就永远不返回，下一拍也不会来。 */
    var ac = (typeof AbortController !== "undefined") ? new AbortController() : null;
    if (ac) setTimeout(function () { ac.abort(); }, 6000);
    fetch(location.pathname + "?_dsapp_probe=" + Date.now(),
          { cache: "no-store", signal: ac ? ac.signal : undefined })
      .then(function () {
        dsappHealStrike();
        console.log("[dsapp] 服务器回来了，自动刷新页面（连着第 " +
                    (fails + 1) + " 次，上限 " + DSAPP_HEAL_MAX + "）");
        window.location.reload();
      })
      .catch(function () { /* 还没回来，下一拍再问 */ });
  }, DSAPP_HEAL_EVERY_MS);
}

/* ---- 心跳：服务端还活着吗（V13.11 item 7）------------------------------- */

/* 收到了心跳 → 记时刻，并把"服务端没响应"那块提示撤掉（它自己好了）。
 *
 * ⚠️ 只撤 silent 那一块，**不碰** disconnected 那一块：连接真断了的时候，
 *    心跳也可能正好还有一个在管道里，撤掉就骗人了。 */
/* ⚠️⚠️ 那个 m 参数**不能省**，哪怕一个字都用不到。
 *    Shiny.addCustomMessageHandler() 注册时就在查 `handler.length !== 1`，
 *    是 0 的话当场抛 "handler must be a function that takes one argument"。
 *    而它是**加载时同步抛**的 —— 于是这个文件里排在它**后面**的每一个
 *    addCustomMessageHandler / 事件绑定全都不会被注册。症状离得很远：
 *    左侧栏点了不切页、下载点了没反应、跨页跳转的高亮不动，而控制台那行
 *    报错是一句跟这些功能毫不相干的话。（就是写这条的时候踩的，测试当场
 *    抓到：心跳压根没注册上，冻住服务端 30 秒都没报警。） */
Shiny.addCustomMessageHandler("dsapp:ping", function (m) {
  dsappLastPing = Date.now();
  /* ⚠️ 判据是**状态**，不是那块卡片在不在（V16.11 item 1 改）。
   *    原来写 `document.getElementById("dsapp-offline")`：用户一点「先等一下」
   *    卡片就没了 ⇒ 这里拿到 null ⇒ **服务端已经活过来了、小条却永远撤不掉**，
   *    左下角一直挂着"在等它回来…"直到用户自己刷新。一处"节点即事实"的旧账，
   *    被小条这个新节点照出来了。
   *    仍然只撤 silent、不碰 down：连接真断了的时候心跳也可能正好还有一个在
   *    管道里，撤掉就骗人了（这条语义一个字没动）。 */
  if (window.dsappNet.state === "silent") dsappOfflineHide();
});

setInterval(function () {
  /* ⚠️ 后台标签页不算。浏览器会把后台标签页的定时器降频到分钟级，Chrome
   *    还会直接冻结/丢弃整个标签页 —— 那种情况下"没收到心跳"说明不了
   *    任何事，一回到前台就会误报一整块遮罩。用户切回来第一眼看到的是
   *    "服务端没有响应"，而他什么都没干。
   *
   *    代价是：标签页在后台时真的断了，用户切回来的那一瞬间**不会**立刻
   *    看到提示 —— 但他下一秒就会开始点，而下面这条 setInterval 还在跑，
   *    最多 2 秒就报出来。 */
  if (document.hidden) { dsappLastPing = Date.now(); return; }
  if (Date.now() - dsappLastPing > DSAPP_PING_DEAD_MS) {
    /* ⚠️⚠️ 已经挂着 disconnected 的时候**不许**降级成 silent。
     *    这两块的权威性不对等：disconnected 是 socket **真的收到了 close**
     *    （硬证据），silent 只是"它 30 秒没跟我说话"（猜测，忙和死分不开）。
     *    而心跳超时这一条在**任何**断线里都必然成立 —— 于是它总会踩着
     *    disconnected 往上盖，把硬证据换成猜测。
     *    2026-10-02 实测就是这么翻的车：disconnected 挂上 16 秒后被这里
     *    换成 silent，自愈那段（它只认 disconnected）下一拍就自己收工了，
     *    页面从此永远回不来。 */
    /* ⚠️ 同样改读**状态**（V16.11 item 1）。原来读卡片：用户"先等一下"之后
     *    卡片不在 ⇒ 每 2 秒把大卡片重新弹回来一次，那颗按钮等于白点。
     *    语义不变：down 不许被降级（理由见上），silent 不重复画。 */
    var st = window.dsappNet.state;
    if (st !== "down" && st !== "silent") {
      /* ★ 判死线到了，但**不铺卡片** —— 只出小条（2026-10-07 用户反馈）。
       *   原来 16 秒那个阈值在线上太容易到了：服务端跑重活时它自己的事件
       *   循环就被钉住。绝大多数情况下它自己会好，而一铺就是盖住整页，
       *   用户已经为此被吓过好几次了。（阈值已抬到 30 秒，但"忙"和"死"
       *   从浏览器这边本来就分不开 —— 所以判死那一刻更不该下重手。） */
      dsappOfflineWarn("silent");
      return;
    }
    /* 还断着 —— 交给它判断"够不够久、该不该把卡片铺出来了"。
     * ⚠️ 这一段里**不许**出现 dsappOfflineShow：判死那一支只出小条，
     *    铺整页卡片是另一条路（自检盯着这个形状）。 */
    dsappOfflineEscalate(st);
  }
}, 2000);

/* ---- 左侧栏导航（V6 item 5）---------------------------------------------- */

/* 点击只发一个值，**不在这里切 DOM**。
 *
 * 页签的激活状态归 Bootstrap 的 tab 机制管（navset_hidden 也是那一套），
 * 前端自己加个 .active 只是画上去的，真页面不会跟着换 —— 症状是
 * "点左边高亮了，右边还是原来那页"。所以走服务端：
 * bslib::nav_select() 会把该做的都做掉，再由服务端回一条 dsapp:nav
 * 把高亮和标题补上（见 app.R 里那条 observe）。
 *
 * 带序号是因为 Shiny 对**值相同**的输入不重复触发 observer：连点两次
 * 同一个导航项，第二次得是个不同的值才发得出去。 */
var dsappNavSeq = 0;

function dsappNav(value) {
  if (!value) return;
  dsappNavSeq += 1;
  Shiny.setInputValue("dsapp_nav_goto",
                      { v: value, n: dsappNavSeq },
                      { priority: "event" });
}

/* 服务端确认切换完成后回执：更新左栏高亮 + 顶栏标题。
 *
 * ⚠️ 标题取自导航项自己的文字，不另外维护一份映射表。写表的话，
 *    改一个导航项的名字要改两处，漏了就是"左边写着任务、顶上写着 Tasks"，
 *    而且不会有任何报错。 */
Shiny.addCustomMessageHandler("dsapp:nav", function (m) {
  if (!m || !m.value) return;
  var links = document.querySelectorAll(".dsapp-rail-link");
  var title = "";
  for (var i = 0; i < links.length; i++) {
    var hit = links[i].getAttribute("data-nav") === m.value;
    links[i].classList.toggle("active", hit);
    if (hit) {
      var lb = links[i].querySelector(".dsapp-rail-label");
      title = lb ? lb.textContent : "";
    }
  }
  var el = document.getElementById("dsapp_page_title");
  if (el && title) el.textContent = title;
  document.title = title ? (title + " · Biomamba言出法随生信APP")
                         : "Biomamba言出法随生信APP";
});

/* ---- 等一个元素出现后点它（下载用）--------------------------------------- */

/* 对话里的文件下载走这个：Shiny 的 downloadHandler 必须绑在一个**已经存在**
 * 的输出上，而"用户点了哪一行"是运行时才知道的。所以点行时先告诉服务端，
 * 服务端把 downloadLink 渲染出来，再由这里补一次点击。
 *
 * 用轮询而不是 MutationObserver：这个链接最多等一两百毫秒，轮询足够，
 * 而且不会在整页重渲染时留下观察器。
 *
 * ★★ 下载链接必须等到 href 非空再点。空 href 的 <a> 一点，浏览器会导航到
 *    当前地址 —— 用户拿回来一个首页的 HTML 而不是文件，而且页面被刷掉、
 *    界面上什么都不说，只在下载目录里留一个打不开的压缩包。
 *
 *    这不是理论风险：服务端那个 output 只要还受"隐藏即挂起"管辖
 *    （ShinySession$shouldSuspend，详见 mod_files.R 里 output$download
 *    的说明），href 就**从来**没有值。服务端那边已经用
 *    outputOptions(suspendWhenHidden = FALSE) 修掉了，这里再挡一道：
 *    两个地方各自独立，将来谁改坏了另一个都还有兜底。 */
Shiny.addCustomMessageHandler("dsapp:clickWhenReady", function (m) {
  if (!m || !m.id) return;
  var tries = 0;
  var timer = setInterval(function () {
    var el = document.getElementById(m.id);
    var ready = !!el;
    if (ready && el.classList &&
        el.classList.contains("shiny-download-link")) {
      ready = (el.getAttribute("href") || "") !== "";
    }
    if (ready) {
      clearInterval(timer);
      el.click();
    } else if (++tries > 60) {   /* 约 6 秒还没就绪，放弃 */
      clearInterval(timer);
    }
  }, 100);
});

/* ---- 通用复制（恢复码用）------------------------------------------------- */

function dsappCopyText(btn, text) {
  var done = function (ok) {
    var old = btn.innerHTML;
    btn.innerHTML = ok ? "已复制" : "复制失败";
    setTimeout(function () { btn.innerHTML = old; }, 1500);
  };
  /* 理由同 dsappCopyCode：明文 http 下 navigator.clipboard 是 undefined */
  if (navigator.clipboard && window.isSecureContext) {
    navigator.clipboard.writeText(text).then(
      function () { done(true); },
      function () { done(dsappCopyFallback(text)); }
    );
  } else {
    done(dsappCopyFallback(text));
  }
}

/* ---- 点击会话列表项 ------------------------------------------------------ */

function dsappPickSession(el) {
  var sid = el.getAttribute("data-sid");
  if (!sid || !dsappIds.pickSession) return;
  Shiny.setInputValue(dsappIds.pickSession, sid, { priority: "event" });
}

/* ---- 会话重命名（V13.1 item 4）------------------------------------------- */

/* 侧栏每一行右边那个铅笔。点它只做一件事：把**那一行的** sid 发给服务端，
 * 由服务端弹重命名框（名字的合法性、权限都在那边判，见 mod_chat.R）。
 *
 * ⚠️ 必须 stopPropagation。整个会话行上挂着 dsappPickSession 的 onclick，
 *    不拦的话点铅笔会先切到那个对话（发出 pickSession）、再发 rename ——
 *    用户看到的是"点一下铅笔，左边的对话莫名其妙跳了"。两件事都会发生，
 *    只是顺序看着像只发生了后一件。
 *
 * ⚠️ 必须 return false。铅笔是 <a href="#">，不拦默认行为的话浏览器会把
 *    URL 加上一个 "#" 并滚到页面顶部。
 *
 * `event` 在内联 onclick 里是能拿到的（老 IE 留下的全局，现代浏览器都还
 * 保留着）；真拿不到时退回 window.event，再没有就只做前两件事。 */
function dsappRenameSession(el, ev) {
  ev = ev || window.event;
  if (ev) { ev.preventDefault(); ev.stopPropagation(); }
  var row = el.closest ? el.closest(".dsapp-sess") : null;
  var sid = row && row.getAttribute("data-sid");
  if (!sid || !dsappIds.sessionRename) return false;
  Shiny.setInputValue(dsappIds.sessionRename, sid, { priority: "event" });
  return false;
}

/* ---- 代码块：复制 -------------------------------------------------------- */

function dsappCopyCode(btn) {
  var card = btn.closest(".dsapp-code-card");
  if (!card) return;
  var pre = card.querySelector("pre.dsapp-code code");
  if (!pre) return;
  var text = pre.innerText;

  var done = function (ok) {
    var old = btn.textContent;
    btn.textContent = ok ? "已复制" : "复制失败";
    setTimeout(function () { btn.textContent = old; }, 1500);
  };

  /* navigator.clipboard 只在安全上下文（HTTPS 或 localhost）可用。
   * 本站是 http://<域名>:34038 明文访问，navigator.clipboard 是 undefined，
   * 直接调用会抛异常且什么都不发生。所以必须留 execCommand 这条退路 ——
   * 它虽然已标记废弃，但在这个部署形态下是唯一能用的办法。 */
  if (navigator.clipboard && window.isSecureContext) {
    navigator.clipboard.writeText(text).then(
      function () { done(true); },
      function () { done(dsappCopyFallback(text)); }
    );
  } else {
    done(dsappCopyFallback(text));
  }
}

function dsappCopyFallback(text) {
  var ta = document.createElement("textarea");
  ta.value = text;
  /* 放在视口外，避免复制时页面跳动 */
  ta.style.position = "fixed";
  ta.style.top = "-1000px";
  ta.setAttribute("readonly", "");
  document.body.appendChild(ta);
  ta.select();
  var ok = false;
  try { ok = document.execCommand("copy"); } catch (e) { ok = false; }
  document.body.removeChild(ta);
  return ok;
}

/* ---- 代码块：确认执行 ---------------------------------------------------- */

/* 用事件委托而不是给每个按钮绑 onclick —— 消息是流式重渲染出来的，
 * 每次重渲染都是全新的 DOM 节点，逐个绑定必然漏掉后出现的那些。 */
document.addEventListener("click", function (e) {
  var btn = e.target.closest(".dsapp-code-run");
  if (!btn) return;
  if (!dsappIds.codeAction) return;

  var cid = btn.getAttribute("data-code-id");
  if (!cid) return;

  /* 防连点：提交后先禁用，避免同一段代码被重复提交成多个任务。
   * ★ V16.1 item 6：原文案存进 dataset —— 提交**被拒**的时候要还原回去
   *   （见下面 dsapp:coderun_reset 的说明）。 */
  btn.disabled = true;
  if (btn.dataset.dsappLabel === undefined) {
    btn.dataset.dsappLabel = btn.textContent;
  }
  btn.textContent = "已提交";

  Shiny.setInputValue(dsappIds.codeAction, cid, { priority: "event" });
});

/* ---- 代码块：提交被拒时把按钮还原（V16.1 item 6）-------------------------
 *
 * ★ 为什么要有这条消息：上面那个点击处理器是**乐观**的 —— 它先禁用按钮、
 *   写上"已提交"，然后才把动作发给服务端。服务端那边有好几道闸门会拒
 *   （引擎正忙、配额满、工作区不可写、安全检查没过），拒了只弹一条 toast。
 *   于是 toast 几秒就没了，而卡片上那颗按钮**永远停在灰色的「已提交」** ——
 *   用户看到的是"这一段代码已经提交了"，可它根本没跑，而且他再点也点不动。
 *
 *   用户这一条反馈的原话是「我点确认执行，显示已有任务在执行，但是我看不到
 *   任何提示任务在执行的痕迹」—— 他是被拒的那一方，而界面上留下的痕迹恰好
 *   是**最误导**的那种。所以这个还原和浮标是同一件事的两半。
 *
 * ⚠️ 只认 data-code-id 对得上的那一颗，不做全页还原：用户可能同时点了两张
 *    卡片，而只有其中一张被拒。
 * ⚠️ **逐个比属性，不拼选择器**。拼 `.dsapp-code-run[data-code-id="…"]` 的话，
 *    id 里只要有一个引号或反斜杠，querySelector 当场抛 DOMException ——
 *    而这一抛发生在消息处理器里，表现是"还原没发生"，且控制台里那句报错
 *    指向的选择器长得完全合理。id 是渲染层生成的，不该假设它的字符集。
 * ⚠️ 卡片可能已经被 Shiny 重画成**新节点**（那一颗本来就是启用的，没什么可
 *    还原）—— 找不到旧节点不是异常，找不到就算了。 */
Shiny.addCustomMessageHandler("dsapp:coderun_reset", function (m) {
  if (!m || !m.cid) return;
  var btns = document.querySelectorAll(".dsapp-code-run");
  for (var i = 0; i < btns.length; i++) {
    if (btns[i].getAttribute("data-code-id") !== m.cid) continue;
    btns[i].disabled = false;
    btns[i].textContent = (btns[i].dataset.dsappLabel !== undefined)
      ? btns[i].dataset.dsappLabel : "确认执行";
  }
});

/* ---- 发送按钮的忙闲 ------------------------------------------------------ */

/* 服务端说了算的最终状态（见 mod_chat.R 里那条 observe 的说明）。
 * 前端只负责"点下去到服务端回话"这一段空窗期的即时反馈。 */
Shiny.addCustomMessageHandler("dsapp:busy", function (m) {
  if (!m || !m.btn) return;
  dsappSetBusy(!!m.busy, m.btn, !!m.lock);
});

/* lock：共享进来的对话（V5 item 7）。发送按钮和输入框一起锁死 ——
 * 只灰按钮的话，用户在输入框里敲完一屏、按回车没反应，比直接不让打字
 * 更让人摸不着头脑。输入框上方的提示由服务端渲染（output$readonly_note）。
 *
 * ⚠️ 这只是界面。真正的闸门在服务端（mod_chat.R 的 dsapp_chat_send）——
 *    前端锁得再死，控制台里改一下 DOM 就没了。 */
function dsappSetBusy(busy, btnId, lock) {
  var id = btnId || dsappIds.sendBtn;
  if (!id) return;
  var btn = document.getElementById(id);
  if (btn) {
    btn.disabled = busy || lock;
    // 忙碌的转圈样式只跟 busy 走：只读是**长期**状态，
    // 给它挂上忙闲的样式会看起来像卡住了。
    if (busy) btn.classList.add("dsapp-busy");
    else btn.classList.remove("dsapp-busy");
  }
  if (dsappIds.input) {
    var box = document.getElementById(dsappIds.input);
    /* ⚠️ 组字过程中**不要**动 readOnly（V13.7 item 4）。在 composition 期间
     * 切换 readOnly 会让部分浏览器直接中止这次组字，pre-edit 串被丢弃或者
     * 被固化成 value —— 中文用户看到的就是"打着打着字没了"。
     * 只读会话（共享进来的对话）下这个赋值每次 busy 变化都来一遍，
     * 撞上组字的概率不低。等组字结束再写：下一次 busy 变化会补上它。 */
    if (box && !dsappComposing) box.readOnly = lock;
  }
}

/* ---- 「它问你话」时的回答框（★ V15.6 item 12）---------------------------- */

/* 服务端判出"最后一条回复是在问你一句"之后，发这条消息把回答框亮出来。
 *
 * 用户原话：「返回问题的时候只有继续和停止按钮，应该有键入让用户回答，
 * 类似于 claude 的 chat about this」。
 *
 * ⚠️ 这个框是**静态节点**（mod_chat.R 的 UI 里就画好了，默认 display:none），
 *    服务端只发消息切显隐 —— 绝不能用 renderUI 画它：历史那一格会重画，
 *    而重画会把用户正在打的字整段冲掉（本仓栽过，而且不报错）。
 * ⚠️ 只切 style.display 和 textContent，不碰别的属性。 */
Shiny.addCustomMessageHandler("dsapp:askbox", function (m) {
  var box = dsappIds.askBox ? document.getElementById(dsappIds.askBox) : null;
  if (!box) return;
  var on = !!(m && m.on);
  if (m && m.hint) {
    var h = dsappIds.askHint ? document.getElementById(dsappIds.askHint) : null;
    if (h) h.textContent = m.hint;
  }
  /* 清空只在服务端**确认发出去了**之后才做（m.clear）—— 失败时把用户
   * 刚写的那句话擦掉，等于让他重打一遍。 */
  if (m && m.clear && dsappIds.askReply) {
    var t = document.getElementById(dsappIds.askReply);
    if (t) t.value = "";
  }
  box.style.display = on ? "" : "none";
  /* ★ V16.1 item 1：把"回答框正亮着"这件事告诉父容器 —— 它亮着的时候，
   * 这个框和下面的大输入框要**焊成一整块**（见 app.css 的 .dsapp-has-ask）。
   * ⚠️ 判据必须落在父容器上，不能让 CSS 用 `~ 相邻兄弟` 去推：这个框一直在
   *    DOM 里（只切 display），兄弟选择器会在它**收起来**的时候照样生效，
   *    把下面输入框的上圆角抹掉，看起来像被削了一块。 */
  var comp = box.closest ? box.closest(".dsapp-composer") : null;
  if (comp) comp.classList.toggle("dsapp-has-ask", on);
  /* 亮出来的时候把光标放进去：用户刚看到"它在问你"，下一步就是打字。 */
  if (on && dsappIds.askReply) {
    var t2 = document.getElementById(dsappIds.askReply);
    if (t2) { try { t2.focus(); } catch (err) {} }
  }
});

/* ---- 输入框：Enter 发送，Shift+Enter 换行 -------------------------------- */

/* 单调递增的计数器。
 *
 * 用 Date.now() 是不够的：同一毫秒内的两次回车会得到相同的值，
 * Shiny.setInputValue 对相同的值不重复触发事件 —— 手快的时候第二次
 * 回车就被吞了（连按更容易撞上）。计数器保证每次都不一样。
 * 另外 keydown 会随按住不放反复触发，用 e.repeat 挡掉。 */
var dsappSendSeq = 0;

document.addEventListener("keydown", function (e) {
  if (e.key !== "Enter" || e.shiftKey) return;
  if (e.repeat) return;                 /* 按住回车不放，别连发 */
  /* ★ 组字中的这个 Enter 是"选字上屏"，**不是**发送（V13.7 item 4）。
   *
   * ⚠️ 必须放在 e.preventDefault() **之前**。放到后面等于照样把上屏吃掉，
   *    症状只是从"发出去的是拼音"变成"汉字怎么都打不出来"——更难查。
   *
   * ⚠️ `isComposing` 是主判据，`keyCode === 229` 是**必须留着的兜底**：
   *    部分 Windows 输入法/旧浏览器在组字中把 key 报成 "Process" 或
   *    "Unidentified"，那时上面那句 `e.key !== "Enter"` 反而不成立、会漏过去，
   *    229 是这些场景下唯一可靠的信号。`dsappComposing` 再兜一层键盘外的路径。 */
  if (e.isComposing || e.keyCode === 229 || dsappComposing) return;
  if (!dsappIds.input || !dsappIds.sendKey) return;
  if (!e.target.id || e.target.id !== dsappIds.input) {
    /* ★★ V15.6 item 12：「它问你话」时那个回答框（mod_chat.R 的
     *   .dsapp-ask-box）不是 dsappIds.input，上面那条按 id 的判据够不着
     *   它 —— 回车会变成换行，用户以为发不出去。
     *   所以给这类框一个**通用出口**：谁身上写了 `data-dsapp-enter`，
     *   回车就把序号发到那个属性写的 input 名上（服务端自己 ns() 拼好，
     *   前端不硬编码命名空间 —— 同 dsappIds 的规矩）。
     * ⚠️ 属性名必须原样是 `data-dsapp-enter`（dataset.dsappEnter），
     *    改了要同步改 R/mod_chat.R 里那个 tags$textarea。 */
    var altKey = e.target.dataset ? e.target.dataset.dsappEnter : null;
    if (!altKey) return;
    e.preventDefault();
    if (!e.target.value || !e.target.value.trim()) return;
    dsappSendSeq += 1;
    Shiny.setInputValue(altKey, dsappSendSeq, { priority: "event" });
    return;
  }

  e.preventDefault();

  /* 空内容直接不发。以前不管有没有字都发一个事件，服务端 trim 完
   * 发现是空的再原样返回 —— 白跑一趟，还会把按钮闪一下置灰。 */
  if (!e.target.value || !e.target.value.trim()) return;

  /* 先置灰再发。服务端的查库、拼上下文、起子进程要几百毫秒，这期间
   * 界面上什么都不动，用户以为没点上就又按一次 —— 上一条 e.repeat 挡住
   * 的是手一直按着，这一条挡的是"按一下、没动静、再按一下"。
   * 服务端也会拦重复请求（mod_chat.R 的 dsapp_chat_send），但那是兜底，
   * 用户看不见；按钮立刻变灰才是他能感知到的反馈。 */
  dsappSetBusy(true);
  dsappSendSeq += 1;
  Shiny.setInputValue(dsappIds.sendKey, dsappSendSeq, { priority: "event" });
});

/* ★ 组字还没结束就点"发送"：这一次点击直接作废（V13.7 item 4）。
 *
 * 上面那条 Enter 的守卫管不到鼠标。绝大多数输入法会在 mousedown 时把候选词
 * 上屏（compositionend 先于 click），那时这个守卫不会触发、点下去发的就是
 * 汉字，正是我们要的；只有"候选窗还开着、字还没定"的时候才会挡下来 ——
 * 那一刻框里的"内容"是拼音，发出去没有任何意义。
 *
 * ⚠️ 必须用**捕获阶段 + stopPropagation**：真正发消息的是 Shiny 自己绑在
 *    按钮上的处理器（冒泡阶段），在下面那个"补个视觉反馈"的处理器里 return
 *    是拦不住它的 —— 那样只会变成"按钮没变灰，但拼音照样发出去了"。
 *    挡完这一下，用户再点一次（那时组字已结束）即可正常发送。 */
document.addEventListener("click", function (e) {
  if (!dsappComposing) return;
  var btn = e.target.closest && e.target.closest("button");
  if (!btn || !dsappIds.sendBtn || btn.id !== dsappIds.sendBtn) return;
  e.preventDefault();
  e.stopPropagation();
}, true);

/* 点"发送"按钮同理：Shiny 自己的 click 处理器照常触发（置灰不取消本次
 * 事件分发），这里只补一个即时的视觉反馈。 */
document.addEventListener("click", function (e) {
  var btn = e.target.closest && e.target.closest("button");
  if (!btn || !dsappIds.sendBtn || btn.id !== dsappIds.sendBtn) return;
  var box = dsappIds.input ? document.getElementById(dsappIds.input) : null;
  if (box && !box.value.trim()) return;   /* 空内容不必置灰 */
  dsappSetBusy(true);
});

/* ---- 入口页：回车 = 点主按钮 --------------------------------------------- */

/* 表单里敲回车提交，是任何登录框的默认期待（ChatGPT 的也是这样）。
 * Shiny 自己不提供 —— 不补这一下，用户在邮箱框里敲回车会什么都不发生，
 * 然后以为页面卡住了。
 *
 * 只挑 .dsapp-btn-primary：入口页上每屏只有一个主按钮，用 class 选比传
 * id 过来少一处要同步的东西（id 带命名空间，改模块名就会静默失效）。 */
document.addEventListener("keydown", function (e) {
  if (e.key !== "Enter" || e.shiftKey || e.repeat) return;
  var el = e.target;
  if (!el || el.tagName !== "INPUT" || !el.closest) return;
  var page = el.closest(".dsapp-auth");
  if (!page) return;
  var btn = page.querySelector(".dsapp-btn-primary");
  if (btn && !btn.disabled) {
    e.preventDefault();
    btn.click();
  }
});

/* 点下去先自己进入"忙"状态。
 *
 * 服务端要查库、比对密码哈希，再走一次 cookie 回执（最长 2 秒）。这中间
 * 界面一动不动的话，用户会以为没点上，然后接着点 —— 和对话页那个发送
 * 按钮是同一类问题，处理方式也保持一致。
 *
 * 不设 disabled 属性：Enter 处理器走的是 btn.click()，靠 is-busy 这个类
 * 拦重复提交就够了；服务端出错时整页会重渲染，按钮自然恢复。6 秒的兜底
 * 是防"服务端既没回话也没重渲染"（那属于断线，另有断线提示接管）。 */
$(document).on("click", ".dsapp-auth .dsapp-btn-primary", function () {
  var b = this;
  if (b.classList.contains("is-busy")) return;
  b.classList.add("is-busy");
  setTimeout(function () { b.classList.remove("is-busy"); }, 6000);
});

/* ---- 重渲染之后把滚动位置放回去（V13.9 item 2）--------------------------- */

/* 用户原话：「会话不要总是刷新到顶部」。
 *
 * ★ 病根在 Shiny 的输出模型上，不在下面那个滚动处理器里：只要
 *   output$history（或 output$session_list）重算，Shiny 就把**整个容器的
 *   内容**换掉。被换掉的那一瞬间容器高度归零，浏览器把 scrollTop 钳到 0；
 *   等新内容铺回来，用户已经站在顶部了。
 *
 * ★ 为什么原来那个 dsapp:scroll 处理器救不了它：那是**另一条** websocket
 *   消息。它跑到的时候 DOM 往往还没换 —— 于是它按旧内容算出 nearBottom
 *   为真、滚到底，紧接着 Shiny 才把内容换掉、又弹回顶部。顺序反了，怎么调
 *   阈值都没用。"跟着底部走"和"重渲染"必须在同一处收口，这就是这个看护器
 *   存在的全部理由。
 *
 * 只需要记两件事：
 *   pinned —— 换之前用户是不是贴着底。是的话换完仍然贴底（流式输出要跟着走）；
 *   top    —— 不是的话，换完回到原来那个像素位置（用户正在翻历史，别动他）。
 * 用 MutationObserver 而不是给每个 output 挂回调：Shiny 换 DOM 的手法不止
 * 一种，观察容器本身是唯一不依赖它内部实现的做法。
 *
 * ⚠️ 回调里**只写 scrollTop、不碰 DOM**：碰了就会再触发自己一次。
 * ⚠️ MutationObserver 的回调跑在"DOM 改完、绘制之前"的微任务里，所以这个
 *    还原属于同一帧，看不出闪动 —— 不会出现"先跳到顶再弹回来"。
 */
(function () {
  var PIN = 40;              /* 离底多少像素以内算"贴着底" */

  function keep(el) {
    if (!el || el.__dsappKeeper) return el && el.__dsappKeeper;
    var pinned = true, top = el.scrollTop;

    el.addEventListener("scroll", function () {
      top = el.scrollTop;
      pinned = el.scrollHeight - el.scrollTop - el.clientHeight < PIN;
    }, { passive: true });

    var api = {
      /* 用户自己滚到底（发了消息、换了对话）：这次一律贴底，不问他原来在哪 */
      force: function () {
        pinned = true;
        el.scrollTop = el.scrollHeight;
        top = el.scrollTop;
      },
      /* 新内容来了：只在用户本来就贴着底的时候跟 */
      follow: function () {
        if (pinned) api.force();
      }
    };

    new MutationObserver(function () {
      if (pinned) {
        el.scrollTop = el.scrollHeight;
      } else {
        var want = Math.min(top, Math.max(0, el.scrollHeight - el.clientHeight));
        if (el.scrollTop !== want) el.scrollTop = want;
      }
    }).observe(el, { childList: true, subtree: true });

    el.__dsappKeeper = api;
    return api;
  }

  /* 暴露出去：皮肤切换、布局重排都会把主区整块重建，那时候容器是**新的
   * DOM 节点**，旧节点连同它的 observer 一起没了 —— 得重新挂。 */
  window.dsappKeepScroll = keep;

  function boot() {
    var els = document.querySelectorAll(".dsapp-chat-scroll");
    for (var i = 0; i < els.length; i++) keep(els[i]);
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", boot);
  } else {
    boot();
  }
  /* shiny:idle 在每次 flush 收尾时触发，正好覆盖"主区被重建"这件事。
   * 重复调用没有代价：keep() 第一句就按 __dsappKeeper 早退，命中的元素
   * 通常只有零到一个。 */
  $(document).on("shiny:connected shiny:idle", boot);
  setTimeout(boot, 1500);
})();

/* ---- 自动滚动到底部 ------------------------------------------------------ */

Shiny.addCustomMessageHandler("dsapp:scroll", function (m) {
  var el = document.getElementById(m.id);
  if (!el) return;
  /* 交给看护器：它知道用户是不是贴着底，而且它是在**重渲染之后**才做决定的
   * （见上面那段）。没有看护器的容器（理论上不该有）退回原来的就地判断。 */
  var api = window.dsappKeepScroll ? window.dsappKeepScroll(el) : null;
  if (api) {
    if (m.force) api.force(); else api.follow();
    return;
  }
  /* 用户往上翻看历史时就别打扰他 —— 只有本来就在底部附近才自动跟随。
   * 阈值给 120px：代码块高度不固定，卡太死会在流式输出时反复失效。 */
  var nearBottom = el.scrollHeight - el.scrollTop - el.clientHeight < 120;
  if (nearBottom || m.force) {
    el.scrollTop = el.scrollHeight;
  }
});

/* ---- 思考过程：往 <pre> 里追加（★ Test_V15.3 item 3）--------------------- */

/* 用户原话：「现在对话框思考时还是会闪，不要闪，正常往外输出思考过程就行了」。
 *
 * 服务端（R/mod_chat.R 的 dsapp_think_append）每一拍只发**新长出来的那一段**，
 * 这里把它贴到 <pre> 的**末尾**。关键在"追加"这两个字：
 *
 * 改之前那一格是 renderUI 出来的，服务端每 200ms 把整块 HTML 换一遍 ——
 * 用户展开的 <details> 被折回去、<pre> 的滚动位置归零，看起来就是一直在闪。
 * 现在服务端一次 DOM 都不碰（只发这条消息），节点是同一个节点，
 * 展开状态和滚动位置由浏览器自己记着。
 *
 * ⚠️ 为什么文本走 createTextNode 而不是拼 innerHTML：思维链是**模型写的
 *    纯文本**，里面出现 <、>、& 是家常便饭。走 textContent 天然免疫，
 *    而且比转义便宜。（同 app.js 里其它几处的做法。）
 * ⚠️ 元素找不到时把这一段**存起来**，下一次一起贴。这不是防御性编程：
 *    骨架比正文晚进 DOM 是可能的（服务端两个包走同一条连接，但渲染是
 *    另一拍的事），丢了这一段的症状是"思考过程开头缺一块"—— 不报错，
 *    只是少字，最难查。 */
var dsappThinkPending = {};

Shiny.addCustomMessageHandler("dsapp:think", function (m) {
  var pre = document.getElementById(m.pre);
  var text = m.text || "";

  if (!pre) {
    if (text) dsappThinkPending[m.pre] = (dsappThinkPending[m.pre] || "") + text;
    return;
  }
  if (dsappThinkPending[m.pre]) {
    text = dsappThinkPending[m.pre] + text;
    delete dsappThinkPending[m.pre];
  }
  if (text) {
    /* 贴底判据和消息流那条一样（<pre> 有自己的滚动条，18rem 高）——
     * 用户往上翻着读的时候别把他拽回底部。 */
    var atBottom = pre.scrollHeight - pre.scrollTop - pre.clientHeight < 40;
    pre.appendChild(document.createTextNode(text));
    if (atBottom) pre.scrollTop = pre.scrollHeight;
    /* ★ V15.6 item 2：**有新内容了**。这是"模型确实又往外吐了点东西"在
     *   前端唯一的权威信号（服务端只在 st$reason 真的长了字时才发这条
     *   消息），活人感提示词的轮换器据此才换下一句 —— 那一头是纯墙钟
     *   节拍时，模型沉默的几十秒里提示词照样在跳。 */
    document.dispatchEvent(new Event("dsapp:activity"));
  }

  /* 标签和字数：**改文本**，不重建节点。 */
  var lab = document.getElementById(m.label);
  if (lab && m.label_text) lab.textContent = m.label_text;
  var nb = document.getElementById(m.nbox);
  if (nb && m.n > 0) {
    nb.textContent = "已思考 " + m.n.toLocaleString() + " 字符";
  }
});

/* ---- 定位 + 闪一下（V8 item 5）------------------------------------------ */

/* 任务页 ↔ 文件页互跳之后，光"切过去"是不够的：目标在一屏之外时用户看到
 * 的是页面顶部，还得自己一屏屏找 —— 那这一跳等于只成功了一半。
 *
 * 传的是选择器而不是 DOM id：文件页的产物行按 `data-rel` 定位，而产物名
 * 是带 `/` 的相对路径，不可能是合法的 DOM id。
 *
 * 用轮询而不是"发消息时元素就该在了"：目标元素是服务端重渲染出来的，
 * 消息到达时那一拍它往往还没进 DOM。等 3 秒还没有就算了（比如产物正好
 * 被删了），不无限转下去。 */
Shiny.addCustomMessageHandler("dsapp:flash", function (m) {
  var tries = 0;
  (function look() {
    var el = document.querySelector(m.sel);
    if (!el) {
      if (++tries > 30) return;
      return setTimeout(look, 100);
    }
    try { el.scrollIntoView({ block: "center", behavior: "smooth" }); }
    catch (e) { el.scrollIntoView(); }
    el.classList.remove("dsapp-flash");
    /* 读一次 offsetWidth 强制重排，否则连着跳同一个元素时动画不会重播 */
    void el.offsetWidth;
    el.classList.add("dsapp-flash");
    setTimeout(function () { el.classList.remove("dsapp-flash"); }, 2600);
  })();
});

/* ---- 跨页跳转后，在任务列表里把那条任务勾上 ------------------------------ */

/* 从文件页点「任务 #N」跳过来时，服务端把任务号告诉这里，由这里去勾那一行。
 *
 * 为什么不在服务端用 DT::selectRows()：任务表是 selection = "none"（勾选
 * 交给 Select 扩展，理由见 mod_tasks.R 里 output$tbl 的注释），而 DT 的
 * methods.selectRows 整个定义在 datatables.js 的
 * `if (inArray(selMode, ['single','multiple']))` 里面 —— mode 是 "none"
 * 时这个函数**压根没被定义**，消息到了浏览器直接没人接。R 那边不但不报错，
 * try() 也 catch 不到（它只是把消息发出去，而且发成功了），最后表现就是
 * "跳过来了，但什么都没选中"。
 *
 * 所以这里直接用 Select 扩展的 API 勾。好处是走的**就是用户手点复选框那
 * 条路**：扩展会派发 select/deselect 事件，DT 的绑定监听着它、顺手把
 * input$tbl_rows_selected 更新掉 —— 详情卡不用再认第二份状态，也就不会
 * 出现"表格和详情卡各说各的"。
 *
 * 轮询的理由同 dsapp:flash：从别的页面跳过来时，这张表是**同一拍**才被
 * 重新渲染出来的，消息到达时它往往还没进 DOM。 */
Shiny.addCustomMessageHandler("dsapp:dtselect", function (m) {
  var tries = 0;
  (function look() {
    var el = document.getElementById(m.id);
    var $t = el ? window.jQuery(el).find("table") : null;
    /* 表还没渲染出来、或者渲染出来了但还没初始化成 DataTable */
    if (!$t || !$t.length || !window.jQuery.fn.DataTable.isDataTable($t[0])) {
      if (++tries > 30) return;
      return setTimeout(look, 100);
    }
    var api = $t.DataTable();
    var row = m.row - 1;                      /* R 那边是 1 起，DT 是 0 起 */
    /* 目标在第 2 页往后时，不先翻页的话是"勾上了但屏幕上根本看不到" */
    var len = api.page.info().length;
    if (len > 0) {
      var p = Math.floor(row / len);
      if (api.page() !== p) api.page(p).draw(false);
    }
    /* 先清掉别的勾。详情卡认的是**行号最小的那条**，留着上面原有的勾，
       "跳到第 5 条"会变成详情卡还停在第 1 条上。 */
    try { api.rows().deselect(); } catch (e) { /* 一条都没勾时会抛，无所谓 */ }
    api.rows(row).select();
  })();
});

/* ---- 上传后让文件输入框复位 ---------------------------------------------- */

/* Shiny 的 fileInput 在上传完成后不会清空，再次选同一个文件不触发 change，
 * 表现为"点了上传没反应"。这里在收到上传完成的信号后手动清一次。 */
Shiny.addCustomMessageHandler("dsapp:resetUpload", function (m) {
  var el = document.getElementById(m.id);
  if (el) el.value = "";
});

/* ---- 文件夹上传（V9 item 12）-------------------------------------------- */

/* 用户的原话：「上传文件和上传skills时需要支持上传文件夹」。
 *
 * 浏览器只认 <input type="file" webkitdirectory> 这一种选文件夹的方式，
 * Shiny 的 fileInput() 没有这个参数，所以属性在这里补上（见下面 mark()）。
 *
 * ★★ 为什么相对路径要**另开一条输入**报回去，而不是把 file.name 改成
 *    `16S分析/otu.csv`：
 *      Shiny 服务端的 FileUploadOperation$fileBegin 里写的是
 *          fileBasename <- basename(.currentFileInfo$name)
 *      —— 目录成分在**服务端**被丢掉（R6 方法实测读过）。浏览器这边把
 *      name 改得再对，落库的还是一个光秃秃的文件名，而且不报错：
 *      界面上是"传上来了"，只是全平铺在根目录里，结构没了。
 *    所以走两条输入：文件本体仍旧交给 Shiny 那条路（进度条、失败重试、
 *    临时文件清理都是现成的），路径单独一条。**两边靠顺序对齐** ——
 *    Shiny 是按 FileList 的顺序逐个上报的，这边也是按同一个顺序取的。
 *
 * ⚠️ 监听器挂在 document 上、走**捕获**阶段：Shiny 自己那个
 *    `change.fileInputBinding` 是 jQuery 的冒泡处理器，捕获一定先跑。
 *    同元素上注册顺序决定先后的那种不确定性（DOM 规范里 target 阶段
 *    不区分捕获/冒泡）在这里被绕开了。 */
(function () {
  var MAX = 3000;      /* 一次选太多会让服务端逐个写盘写很久，先挡住 */

  function relPaths(el) {
    var out = [], fs = el.files || [];
    for (var i = 0; i < fs.length && i < MAX; i++) {
      /* webkitRelativePath 只有 webkitdirectory 的框才有；
         普通多选框没有它，退回文件名 —— 两种框共用这一条路。 */
      out.push(fs[i].webkitRelativePath || fs[i].name);
    }
    return out;
  }

  function enable(el) {
    if (el.getAttribute("data-dsapp-dir-on")) return;
    el.setAttribute("data-dsapp-dir-on", "1");
    el.setAttribute("webkitdirectory", "");
    /* 标准名（Firefox 也认 webkit 那个，两个都写上不冲突） */
    el.setAttribute("directory", "");
  }

  /* 元素是 Shiny 动态渲染进来的，没有"渲染完成"的事件可听，
     所以用 MutationObserver 盯着。 */
  function mark(scope) {
    var list = (scope || document).querySelectorAll(
      ".dsapp-dirupload input[type=file]");
    for (var i = 0; i < list.length; i++) enable(list[i]);
  }

  document.addEventListener("change", function (e) {
    var el = e.target;
    if (!el || el.type !== "file" || !el.closest) return;
    var box = el.closest(".dsapp-dirupload");
    if (!box) return;
    var id = box.getAttribute("data-paths-input");
    if (!id || !window.Shiny) return;
    Shiny.setInputValue(id, relPaths(el), { priority: "event" });
  }, true);

  function boot() {
    mark(document);
    if (window.MutationObserver) {
      new MutationObserver(function () { mark(document); })
        .observe(document.body, { childList: true, subtree: true });
    }
  }
  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", boot);
  } else {
    boot();
  }
})();

/* ---- 对话目录的定位跳转（V9 item 9）-------------------------------------- */

/* 侧栏那条「本对话目录」里点一条 → 把对应的那一轮滚到视野里并闪一下。
 *
 * 纯客户端，不绕服务端：这个目录就是照着消息流渲染出来的，点的时候目标
 * 元素**一定已经在 DOM 里**（不像 dsapp:flash 那种跨页跳转要等重渲染）。
 * 绕一圈的代价是几百毫秒延迟 + 一次白闪，换不来任何东西。
 *
 * ⚠️ block 用 "start" 而不是 dsapp:flash 那边的 "center"：目录跳转是
 *    "从这一轮开始读"，目标停在顶部才对；居中会让上面半屏是上一轮的尾巴，
 *    用户还得自己往下找。
 *
 * 返回值给 onclick 用（`return dsappJumpTo(...)`）：找不到元素时返回 false
 * 也不会让 <div> 有什么默认行为，但保持"返回 false"的写法一致，
 * 以后有人把它挪到 <a> 上也照样对。 */
/* ★ V16.3 item 6：把"滚过去 + 闪一下 + 目录高亮"抽出来，因为它现在有两个
 * 调用者 —— 上面这条即时路径，和下面"等窗口挪过来之后"的那条路。
 * 返回 true 表示目标**已经在 DOM 里**（滚过了），false 表示还没渲染出来。 */
function dsappJumpToEl(id) {
  var el = document.getElementById(id);
  if (!el) return false;
  try { el.scrollIntoView({ block: "start", behavior: "smooth" }); }
  catch (e) { el.scrollIntoView(); }
  el.classList.remove("dsapp-flash");
  /* 读一次 offsetWidth 强制重排，否则连着点同一条时动画不会重播 */
  void el.offsetWidth;
  el.classList.add("dsapp-flash");
  setTimeout(function () { el.classList.remove("dsapp-flash"); }, 2600);
  /* 目录里当前这一条高亮。滚动是异步的（smooth），所以按锚点直接标，
     不靠滚完再算位置。 */
  var items = document.querySelectorAll(".dsapp-toc-item");
  for (var i = 0; i < items.length; i++) {
    items[i].classList.toggle("active",
      items[i].getAttribute("data-anchor") === id);
  }
  return true;
}

/* ★★ V16.3 item 6：目录里点一条**被折叠掉的**消息。
 *
 * 用户原话：「消息过多被折叠时，按导航栏里的消息无法跳转」。
 *
 * ⚠️⚠️ 病根是"目录"和"消息流"的数据源不是一个：目录列的是库里**全部**
 *    消息，消息流只渲染末尾一段（省载荷，见 R/config.R 的
 *    DSAPP_HIST_BUDGET_C）。所以点一个旧轮次时，那个锚点在 DOM 里
 *    **根本不存在** —— 而这里原来就一行 `if (!el) return false`，
 *    静默返回：点了没反应，控制台干干净净，看起来像"目录是坏的"。
 *
 * 为什么是**请服务端把窗口挪过去**，不是"让服务端把中间几屏都取回来"：
 * 库里最长的对话 167 条 / 377 万字，从末尾取到第 5 条要点 74 屏 ——
 * 一次点击就能把这一包顶过 pong 判据（10 秒）、页面自己重连。
 * 挪窗口的载荷恒定是一屏，和这条消息有多老无关。
 *
 * ⚠️ 第 2/3 个参数由服务端在 onclick 里写好（消息 id、input 名字）。
 *    老签名 dsappJumpTo(id) 仍然能用（缺参数时只是退回"点了没反应"）。
 * ⚠️ 值里缀一个时间戳：连续点**同一条**时值必须变，否则 Shiny 按"值没变"
 *    不派发（服务端那边还会再拆一次，见 observeEvent(input$toc_jump)）。 */
window.dsappJumpTo = function (id, mid, inputId) {
  if (dsappJumpToEl(id)) return false;
  if (mid && inputId && window.Shiny && Shiny.setInputValue) {
    Shiny.setInputValue(inputId, String(mid) + "|" + String(Date.now()),
                        { priority: "event" });
  }
  return false;
};

/* 服务端把窗口挪过来之后发的那一条。轮询等元素进 DOM，不假定"消息到时
 * 它就该在了"—— 那一屏是**同一拍**才发出去的（同 dsapp:flash 的理由）。 */
Shiny.addCustomMessageHandler("dsapp:jump_to", function (m) {
  var tries = 0;
  (function look() {
    if (dsappJumpToEl(m.id)) return;
    if (++tries > 30) return;
    setTimeout(look, 100);
  })();
});

/* 滚到哪一轮，目录里就跟到哪一轮 —— 长对话里"我现在读到哪了"和
 * "跳到某处"是一件事的两半，只做后一半的话，用户跳过去之后就丢了方位。
 *
 * 用 scroll 事件 + rAF 节流，不用 IntersectionObserver：这里要的是
 * "**最后一条**在视野顶部之上的轮次"，是一个全局的排序判断，不是
 * "某个元素可见/不可见"，用观察者反而要自己维护一堆状态。 */
(function () {
  var box = null, ticking = false;
  function spy() {
    ticking = false;
    if (!box) return;
    var boxTop = box.getBoundingClientRect().top;
    var items = document.querySelectorAll(".dsapp-toc-item");
    if (!items.length) return;
    var best = null;
    for (var i = 0; i < items.length; i++) {
      var target = document.getElementById(items[i].getAttribute("data-anchor"));
      if (!target) continue;
      if (target.getBoundingClientRect().top - boxTop <= 8) best = items[i];
    }
    /* ★ 滚到底了就点亮**最后一条**。最后那一轮永远够不到容器顶部（它下面
     *   没有内容可滚了），只按"谁在顶部之上"算的话，用户点最后一条、高亮
     *   闪一下立刻被上一条抢走，看起来像"点了没反应"。这是滚动监听这类
     *   实现的通病，滚到底特判一下就行。
     *   这里从后往前找第一条**锚点真的存在**的，而不是无脑取最后一条：
     *   锚点对不上（消息被删/重渲染）时不要点亮一个跳不过去的条目。 */
    if (box.scrollTop + box.clientHeight >= box.scrollHeight - 8) {
      for (var k = items.length - 1; k >= 0; k--) {
        if (document.getElementById(items[k].getAttribute("data-anchor"))) {
          best = items[k];
          break;
        }
      }
    }
    for (var j = 0; j < items.length; j++) {
      items[j].classList.toggle("active", items[j] === best);
    }
  }
  function onScroll(e) {
    var t = e.target;
    if (!t || !t.classList || !t.classList.contains("dsapp-chat-scroll")) return;
    box = t;
    if (ticking) return;
    ticking = true;
    (window.requestAnimationFrame || function (f) { setTimeout(f, 16); })(spy);
  }
  /* 捕获阶段：scroll 事件不冒泡，挂 document 上只能靠捕获拿到 */
  document.addEventListener("scroll", onScroll, true);
})();

/* ---- 左栏「模型服务」那一项下面的小字 ------------------------------------- */

/* ★ V13.12 item 19：模型服务从"左栏常驻的折叠块"搬成了独立页，「当前在用哪个
 * 模型」那行字也跟着搬到了导航项下面（dsapp_rail_link 的 sub 参数）。
 *
 * 这行字是 app_root 渲染时一次性写死的（只有换账号才重渲染），所以保存成功后
 * 必须由服务端推一次新的 —— 不推的话，用户填完 Key、切回对话页，左栏还写着
 * 「未配置」，看起来像保存失败了。
 *
 * ⚠️ 这里删掉的两段（dsapp:rail-model 处理器 + 捕获阶段监听 <details> 的
 *    toggle 上报）是 V7 item 8 / V13.11 item 8 的东西。模型服务搬成独立页之后
 *    那块 <details> 已经不存在了，"改了还没确认就离开"改判**切页**（服务端
 *    state$nav，见 app.R 的 input$nav 那条）—— 不再需要前端上报，也就不再
 *    需要那套"服务端主动收起要屏蔽 toggle"的防循环机制。
 *
 * ⚠️ 这条消息是从 mod_model.R 的模块里发的。模块的 session 是 session_proxy；
 *    这里只改一段文字，不涉及 input id，所以命名空间那一套不适用。 */
Shiny.addCustomMessageHandler("dsapp:rail-sub", function (m) {
  if (!m || typeof m.sub !== "string" || !m.sub) return;
  /* ⚠️ 认的是 data-nav="model"，不是 :nth-child 之类的位置 —— 用户可以把
   *    导航项拖成任意顺序（V13.11 item 3），位置是会变的。 */
  var a = document.querySelector('.dsapp-rail-link[data-nav="model"]');
  if (!a) return;
  var sub = a.querySelector(".dsapp-rail-sub");
  if (!sub) return;             /* 那一项没渲染 sub（理论上不会）就别硬塞 */
  sub.textContent = m.sub;
  sub.title = m.sub;            /* 长了会被省略号截掉，title 里留全的 */
});

/* ---- 文件页：拖拽上传 ---------------------------------------------------- */

/* 把拖进来的文件塞进 fileInput 的 <input type=file>，再派发 change 事件。
 * Shiny 的 shiny-input-file 绑定监听的就是 change，所以不用另开一条上传
 * 通道 —— 走原生这条路，大小限制、进度条、服务端 input$xxx 全都是现成的。 */

document.addEventListener("dragover", function (e) {
  var zone = e.target.closest && e.target.closest(".dsapp-dropzone");
  if (!zone) return;
  /* 不 preventDefault 的话浏览器会直接打开被拖进来的文件，页面跳走 */
  e.preventDefault();
  if (e.dataTransfer) e.dataTransfer.dropEffect = "copy";
  zone.classList.add("dsapp-dropzone-active");
});

document.addEventListener("dragleave", function (e) {
  var zone = e.target.closest && e.target.closest(".dsapp-dropzone");
  if (!zone) return;
  /* 拖过子元素也会触发 dragleave，不判断 relatedTarget 的话高亮会一直闪 */
  if (!e.relatedTarget || !zone.contains(e.relatedTarget)) {
    zone.classList.remove("dsapp-dropzone-active");
  }
});

document.addEventListener("drop", function (e) {
  var zone = e.target.closest && e.target.closest(".dsapp-dropzone");
  if (!zone) return;
  e.preventDefault();
  zone.classList.remove("dsapp-dropzone-active");

  var input = zone.querySelector('input[type="file"]');
  if (!input || !e.dataTransfer || !e.dataTransfer.files.length) return;

  try {
    var dt = new DataTransfer();
    for (var i = 0; i < e.dataTransfer.files.length; i++) {
      dt.items.add(e.dataTransfer.files[i]);
    }
    input.files = dt.files;
  } catch (err) {
    /* 老浏览器没有 DataTransfer 构造器。静默退回"点按钮选择"，
     * 不报错 —— 拖拽本来就是锦上添花，不是唯一入口。 */
    return;
  }
  input.dispatchEvent(new Event("change", { bubbles: true }));
});

/* ---- 表格「全选」方框（DT 的 Select 扩展没有这个功能）--------------------- */

/* ★★ 别再去找 Select 的"表头全选"选项，1.7.0 里根本没有。
 *
 * 这个版本只做两件事：给表头 <th> 加上 `select-checkbox` 这个类名
 * （`dataTables.select.min.js` 里 `m(t.header()).addClass(e._select.className)`），
 * 以及给**行**画方框。表头那个格子是空的 —— Select 自己的 CSS 也只写了
 * `table.dataTable > tbody > tr > td.select-checkbox:before`，选择器里
 * 压根没有 thead。所以表头看不出任何东西，点了也没有反应。
 *
 * ⚠️ 于是"表头有一个 select-checkbox"这种断言是**假绿**：类名在，
 *    功能不在。2026-09-15 的浏览器实测就是这么被骗过去的 —— 断言过了，
 *    用户点上去什么都不会发生。
 *
 * 这里自己塞一个真的 <input type="checkbox"> 进去，并把它和 Select 的
 * 选中集合双向绑起来。
 *
 * 为什么不用自己维护一个"全选"状态、或者去改 Shiny 的 input：Select 的
 * `rows().select()` / `.deselect()` 会触发 `select` / `deselect` 事件，
 * 而 DT 的 Shiny 绑定（datatables.js:1007）正是靠这两个事件把
 * `rows_selected` 重新整份读出来推给服务端的。所以只要走它的 API，
 * 服务端拿到的就是对的，不需要我们另外去 changeInput。
 *
 * @param {object} api DataTables API 实例（initComplete 里的 this）
 */
window.dsappSelectAll = function (api) {
  if (!api || !api.column || api.column(0).header() == null) return;
  var th = api.column(0).header();
  if (!th || th.querySelector("input.dsapp-selall")) return;   /* 装过了 */

  var cb = document.createElement("input");
  cb.type = "checkbox";
  cb.className = "dsapp-selall";
  cb.title = "全选 / 全不选";
  cb.setAttribute("aria-label", "全选 / 全不选");
  /* 表头原本可能是空的（Select 只加了类名），清掉再放，免得叠罗汉。
   * 列本身已设 orderable = FALSE，这个 stopPropagation 是双保险：
   * 万一将来有人把排序打开，点方框也不会变成按这一列排序。 */
  th.textContent = "";
  th.appendChild(cb);
  cb.addEventListener("click", function (e) { e.stopPropagation(); });

  cb.addEventListener("change", function () {
    /* search: 'applied' —— 只全选**当前筛出来的**那些。表格没有筛选时
     * 就是全部；将来加了搜索框，用户的心理模型也是"选中我看得见的"。 */
    var rows = api.rows({ search: "applied" });
    if (cb.checked) rows.select(); else rows.deselect();
  });

  /* 反向：用户一个个勾的时候，表头这个方框要跟着变。
   * 三态 —— 全选中打勾、一个没选是空、选中一部分是 indeterminate
   * （那个横杠）。少了 indeterminate 的话"勾了一个"和"全勾了"看起来
   * 一模一样，用户会以为已经全选。 */
  api.on("select deselect", function () {
    var view = api.rows({ search: "applied" }).indexes().toArray();
    var sel = api.rows({ selected: true }).indexes().toArray();
    var n = 0;
    for (var i = 0; i < view.length; i++) {
      if (sel.indexOf(view[i]) >= 0) n++;
    }
    cb.checked = view.length > 0 && n === view.length;
    cb.indeterminate = n > 0 && n < view.length;
  });
};

/* ---- 「去预览」按钮：点哪一行，勾选就只留哪一行（V13.5 item 4）-----------
 *
 * ★ 为什么这件事**必须在浏览器里做**，不能走服务端：
 *
 *   最自然的写法是 `DT::selectRows(proxy, i)`。它在这张表上**永远不生效**，
 *   而且不报错 —— 2026-09-17 实测：`input$tbl_rows_selected` 一直在变（那是
 *   Select 扩展自己算的），但服务端推过去的那一下石沉大海。
 *
 *   根因在 DT 的 htmlwidgets/datatables.js：
 *
 *     var selMode = data.selection.mode;
 *     if (inArray(selMode, ['single', 'multiple'])) {
 *       ...
 *       methods.selectRows = function (selected, ignoreSelectable) { ... }
 *     }
 *
 *   —— `methods.selectRows` 只在 `selection.mode` 是 single/multiple 时才会
 *   被定义。而这两张表都写着 `selection = "none"`，**而且必须写**（DT 自带的
 *   行选中和 Select 扩展是两套实现，同时开着会互相抢，见 R/mod_files.R 里
 *   那段长注释）。于是代理发过去的消息落到
 *   `console.log("Unknown method " + call.method)` 那一支 —— 是 log 不是
 *   error，控制台不红，只看 error 的断言全绿。
 *
 *   Select 扩展自己的 `rows().select()` / `.deselect()` 不受这个开关影响
 *   （它们挂在 DataTables API 上，不是 DT 的 shinyMethods），所以这里直接
 *   用它们。走它的 API 还顺带保证了 `input$tbl_rows_selected` 是对的 ——
 *   DT 的 Shiny 绑定（datatables.js:1007）靠的就是 select/deselect 事件。
 *
 * ⚠️ 用**捕获阶段**之后的冒泡监听（document 上的普通监听）而不是
 *    pointerdown：Select 扩展的点击处理挂在表上，冒泡顺序是
 *    目标 → 表 → ... → document，所以这里**一定在它之后**跑，
 *    看到的是它切换完的最终状态，再把状态**按平**成"只有这一行"。
 *    顺序反过来的话，用户点一下会被自己的处理器再切换回去 ——
 *    表现就是"点一次选中、点两次取消"，而这正是我们想避免的。
 *
 * ⚠️ 目录行不在这里处理：点目录是"进目录"，那条路要服务端（current_dir），
 *    走的是 tbl_cell_clicked。这里只管勾选。
 */
document.addEventListener("click", function (e) {
  if (!e.target || !e.target.closest) return;
  var td = e.target.closest("td.dsapp-dt-btn");
  if (!td || !window.jQuery) return;
  var tbl = td.closest("table.dataTable");
  if (!tbl) return;
  var api;
  try { api = window.jQuery(tbl).DataTable(); } catch (err) { return; }
  if (!api || !api.rows || !api.row) return;
  var row = api.row(td.parentNode);
  if (!row || !row.length) return;
  /* ★★ V13.9 item 10：这里原来写的是
   *
   *     api.rows().deselect();
   *     row.select();
   *
   *   —— "先全清再选这一行"，为的是让右栏预览读到刚点的那一行（那时预览
   *   读的是 selected()，"行号最小的那条"）。代价是**每点一次「去预览」
   *   就把用户攒的勾选清光**：勾了三项准备打包，看一眼其中一项的内容，
   *   回来只剩一项，按钮从「打包下载（3 项）」变成「下载 xxx.csv」，
   *   而且不报错 —— 用户只会觉得这个多选时灵时不灵。
   *
   *   现在预览在服务端有自己的指针（R/mod_files.R 的 pv_pick），点这一列
   *   由 tbl_cell_clicked 把指针挪过去。所以这里**一个勾都不动**。
   *
   *   ⚠️ 别把 deselect() 加回来。它当初要解决的问题已经不存在了 ——
   *      预览不再从 selected() 取行号。
   *
   *   ⚠️⚠️ 光把 deselect() 删掉**不够**，2026-09-21 实测：勾三行、点其中
   *     一行的「去预览」，`input$tbl_rows_selected` 从 3 变成 **2** ——
   *      少的是被点的那一行。因为 V13.4 item 4 把 Select 扩展的
   *      `selector` 从 `td:first-child` 放宽到了**整行**（那是为了"点行内
   *      任意位置 = 勾选这一行"），而「去预览」这一格也在行内，于是
   *      Select 扩展照常把它**切换**了一下。
   *
   *      这不是小事：那句注释写着"勾选原样不动"，服务端 R/mod_files.R 那边
   *      也写着同样一句 —— 两边都这么写，可实际会掉一个勾。用户勾了五项
   *      准备打包，挨个点开看一眼，回来一个都不剩。
   *
   *   所以这里把 **Select 扩展刚切换掉的那一行按回点击之前的状态**：
   *   点之前是勾着的就补勾回来，点之前没勾的就取消掉。只动**这一行**，
   *   别的行碰都不碰（不是"先全清再选"，那套已经删了）。
   *
   *   ⚠️ "点击之前"的状态只能在 pointerdown 里记：这个监听挂在 document
   *      的冒泡阶段（理由见上面那段），跑到这里时 Select 扩展**已经**切换
   *      完了，那时候再去读 selected() 读到的就是切换后的结果。
   *      pointerdown 一定在 click 之前，也一定在 Select 的处理之前。 */
  var before = window.__dsappPreClickSel;
  /* ⚠️ 比的是 **<table> 元素**，不是 `api`。DataTables 的
   *    `$(tbl).DataTable()` **每调用一次就 new 一个 Api 包装对象**
   *    （dataTable.js 里 `this.api = function () { return new Api(this) }`），
   *    所以 `before.api === api` 永远为假 —— 这一段会静悄悄地整段跳过，
   *    看起来"改了但没效果"。2026-09-21 就是这么白跑了一轮。
   *    （`api.settings()` 那个对象倒是稳定的，但比 DOM 元素更好读。） */
  if (before && before.td === td && before.tbl === tbl) {
    var idx = row.index();
    var was = before.idx.indexOf(idx) >= 0;
    var is = row.selected();
    /* 只在"被 Select 扩展改过"时才动 —— 相等就什么都不做，
       免得平白触发一轮 select/deselect 事件把 input 重发一遍。 */
    if (was !== is) { if (was) row.select(); else row.deselect(); }
  }
  return;
});

/* 记下"这一下点之前勾了哪些行"。见上面 click 处理器最后一段 —— 那一行是
 * 专门为「去预览」这一列记的，别的列（名称/大小/时间）照旧走 Select 扩展
 * 自己的切换，多选手感不变。
 *
 * ⚠️ 用 pointerdown 而不是 mousedown：触屏和无障碍设备上只有 pointer 事件。
 * ⚠️ 每一下都**覆盖**写，不清理也不会串味（下一行会盖掉上一行），但要在
 *    click 之后顺手清掉 —— 用户按住按钮又拖走（没产生 click）时留着的那份
 *    是过期的，虽然带着 td 一起比对不会用错，留着总归是脏的。 */
document.addEventListener("pointerdown", function (e) {
  window.__dsappPreClickSel = null;
  if (!e.target || !e.target.closest || !window.jQuery) return;
  var td = e.target.closest("td.dsapp-dt-btn");
  if (!td) return;
  var tbl = td.closest("table.dataTable");
  if (!tbl) return;
  var api;
  try { api = window.jQuery(tbl).DataTable(); } catch (err) { return; }
  if (!api || !api.rows || !api.row) return;
  try {
    window.__dsappPreClickSel = {
      td: td, tbl: tbl,
      idx: api.rows({ selected: true }).indexes().toArray()
    };
  } catch (err) { window.__dsappPreClickSel = null; }
}, true);

/* 服务端要求"把勾选设成某几行"（V13.5 item 4）。
 *
 * 上面那个点击处理器管的是"用户点的这一下"，这条管的是**服务端发起**的
 * 状态变更 —— 目前只有一处：换目录时清空选中（见 R/mod_files.R）。
 *
 * ⚠️ 消息体里的行号是 **1 基**（R 的下标），DataTables 的 `rows()` 要 0 基，
 *    这里减 1。不减的话永远是"选中下一行"，而且行号合法时不报错。
 *
 * ⚠️ 同样不能走 DT::selectRows(proxy, ...)：理由见上面那段（methods.selectRows
 *    在 selection = "none" 时根本没被定义）。 */
if (window.Shiny && Shiny.addCustomMessageHandler) {
  Shiny.addCustomMessageHandler("dsapp:selectRows", function (m) {
    if (!m || !m.id || !window.jQuery) return;
    /* ⚠️⚠️ V13.8 item 8：`m.id` 是 **DT 输出的 id**，而 getElementById 拿到
     *    的是那个**外壳 DIV**，不是里面的 <table>。DT::dataTableOutput() 渲染
     *    出来的是 `<div class="datatables html-widget ..." id="xx"></div>`，
     *    <table> 是它**渲染时**才塞进去的子节点。
     *
     *    原来是 `jQuery(el).DataTable()` —— 对 DIV 调用 DataTables 会走
     *    它内部那条 `if ("table" != this.nodeName.toLowerCase())` 分支，
     *    弹一个 **DataTables warning: Non-table node initialisation (DIV)**。
     *    用户报的就是这一条（「去预览的时候显示 DataTables warning...」），
     *    而"去预览"点目录行会走 current_dir() → 服务端发这条消息，必然触发。
     *
     *    ⚠️ 那个 try/catch **拦不住**它：DataTables 走的是它自己的 _fnLog
     *    （内部告警），只是打印，不抛异常。
     *
     *    正确做法是先用 find("table") 把内层找出来、再确认它**已经被初始化
     *    过**（isDataTable）。下面 dsapp:dtselect 那条一直是这么写的，这里
     *    照抄那套。isDataTable 那道判断同时挡掉了"表格还没渲染出来"的时序
     *    问题 —— 那种情况下 $t 是空集，直接返回，什么都不会发生。 */
    var el = document.getElementById(m.id);
    var $t = el ? window.jQuery(el).find("table") : null;
    if (!$t || !$t.length ||
        !window.jQuery.fn.DataTable.isDataTable($t[0])) return;
    var api;
    try { api = $t.DataTable(); } catch (err) { return; }
    if (!api || !api.rows) return;
    api.rows().deselect();
    var rows = m.rows || [];
    if (!rows.length) return;
    var zero = [];
    for (var i = 0; i < rows.length; i++) zero.push(rows[i] - 1);
    api.rows(zero).select();
  });
}

/* ---- 「本对话产物」分组的开合状态 ---------------------------------------- */

/* 每个任务一个 <details>，服务端每次重渲染都会重写它们的 open 属性。
 * 不把用户的选择报回去的话，任何一次 ws_refresh（发布、下载、打包）都会
 * 让所有组塌回"只有第一组展开" —— 用户刚展开的那一组连同刚出现的
 * 「已发布」标记一起消失，看起来像点了没反应。
 *
 * ⚠️ `toggle` 事件**不冒泡**，所以必须在捕获阶段监听 document，写
 *    `document.addEventListener("toggle", fn)`（冒泡）是收不到的。
 *    这是这个事件跟 click 最容易搞混的地方。 */
document.addEventListener("toggle", function (e) {
  var d = e.target;
  if (!d || !d.classList) return;
  /* ⚠️ 这个选择器里**必须**把技能页的 .dsapp-skillgroup 也列上（V13.2
   *    item 11）：那一条是"技能列表也做成可展开的文件夹"，开合状态的丢失
   *    方式和产物分组一模一样 —— 存一条技能、改一次排序都会重画列表，
   *    用户刚展开的那一条连同里面的文件信息一起塌回去，看着像点了没反应。
   *    两处的 data-input/data-key 约定是同一套，所以只是多一个类名。 */
  if (!d.classList.contains("dsapp-wsgroup") &&
      !d.classList.contains("dsapp-skillgroup")) return;
  var host = d.closest("[data-input]");
  if (!host || !window.Shiny) return;
  var inputId = host.getAttribute("data-input");
  if (!inputId) return;
  /* 报"当前开着的全部"，而不是"刚变的那一个"：服务端因此不需要维护状态
   * 机，重连/丢事件之后一次全量上报就能自愈。 */
  var keys = [];
  var open = host.querySelectorAll(
    "details.dsapp-wsgroup[open], details.dsapp-skillgroup[open]");
  for (var i = 0; i < open.length; i++) {
    var k = open[i].getAttribute("data-key");
    if (k) keys.push(k);
  }
  var sig = keys.join(",");
  /* 去重：重渲染会重新插入 <details>，浏览器对"插入时就带 open"的元素也会
   * 发 toggle。没有这道闸的话，一次重渲染就会触发一轮上报。
   * 服务端那边 `isolate(input$ws_open)` 是治本（断开重渲染环），这里是第二
   * 道，省掉纯属多余的往返。 */
  if (host._dsappOpenSig === sig) return;
  host._dsappOpenSig = sig;
  Shiny.setInputValue(inputId, keys, { priority: "event" });
}, true);

/* ---- 面板分隔条：拖一下调宽高（V13.2 item 5，V13.4 item 6 加到三条）------ */

/* 六条：会话列表（竖）、对话页产物栏（竖）、输入区（横）、任务导航栏（竖，
 * V13.4 item 6）、历史任务页执行历史栏（竖，V13.5 item 2）、文件页文件管理区
 * （竖，V14 item 1）。
 *
 * ★ 六条走的机制**完全一样**，"是哪一条"由 `data-dsapp-panel` 上那个键决定
 *   （见 panelOf）。加一条只需要：SPEC 里加一项、clampPanel/current/
 *   dragDelta/keydown 各补一个分支、report() 的正则补上后缀字母、
 *   R 那边加进 DSAPP_UIPREF_SPECS 并渲染出 data-dsapp-panel ——
 *   这个 IIFE 的调度部分不用再动。
 *
 * ⚠️ 只有第三条**不在内容流里**（它是绝对定位的，因为 bslib 那栏是 grid 的
 *    一个子项，中间没格子可插）。它靠 el.parentElement 找容器，所以 R 那边
 *    必须把它 append 到 layout **自己**身上 —— 见 mod_chat.R 末尾那段。
 *
 * 服务端把尺寸写成 `:root{--dsapp-files-w:...}`，CSS 里用 var() 取（见
 * app.css 的 .dsapp-files-col / html.dsapp-fixed-composer / codex.css 的
 * --_sidebar-width）。这里干三件事：
 *
 *   1. 拖动过程中**只改 <html> 上的内联变量**，一次网络往返都不发。
 *      ★ 内联值的优先级高于 :root 那条规则 —— 所以拖动期间哪怕服务端因为
 *        别的原因重渲染了（消息流刷新、产物发布），拖到一半的宽度也不会被
 *        弹回去。这是"变量挂 <html> + 内联"这件事真正的作用，不只是省事。
 *   2. 松手时把结果报回服务端存库（priority: "event"，和别的上报一致）。
 *   3. 双击 / 键盘也能调 —— 分隔条 tabindex=0，方向键挪 10px、Shift 挪 50。
 *
 * ⚠️ 边界在这里**现算**，不是照抄 R 里那对 min/max：R 里那对是"这辈子不许
 *    超出"的硬边界（防的是有人手改库），而"这一次拖动能到哪儿"取决于**当前
 *    窗口有多大**。只信后者的话，在 1366 的笔记本上能把文件区拖到只剩一条
 *    缝的消息流。两条都要。
 *
 * ⚠️ 用 pointer 事件 + setPointerCapture，不用 mousemove：鼠标拖出窗口、
 *    拖到 iframe 上、或者手指在触摸屏上滑，都能收到后续事件。mousemove 的
 *    版本会在拖出窗口时**静默停在半路**（看起来像"拖到一半卡住了"）。 */

(function () {
  /* 这几个数必须和 R/uiprefs.R 的 DSAPP_UIPREF_SPECS 一致。
   * 对不上的表现：拖到边界时松手，服务端夹一下，宽度跳一格。 */
  var SPEC = {
    files_w:    { def: 320, min: 200, max: 900 },
    /* ⚠️ 输入区拖动时的下限是 96 而不是 R 里的 0：0 的含义是"自动高度"，
     *    是个**开关**不是一个高度，拖是拖不出来的。"回自动"走双击。 */
    composer_h: { def: 0,   min: 96,  max: 620 },
    /* ★ V13.4 item 6：左边那条任务导航栏（会话列表）。 */
    sess_w:     { def: 260, min: 180, max: 520 },
    /* ★ V13.5 item 8：**全局**主菜单（.dsapp-shell 的第一列）。
     *   ⚠️ 别和 sess_w 搞混：sess_w 只影响「言出法随」那一页里面那条会话
     *      列表，menu_w 影响**所有页面**最左边那条导航。 */
    menu_w:     { def: 264, min: 180, max: 420 },
    /* ★ V13.5 item 2：历史任务页左栏（执行历史）的宽度。
     *   右边「任务详情」吃剩下的 —— 和 files_w 一个约定，调的是有边界的那个。 */
    tasks_w:    { def: 520, min: 300, max: 1200 },
    /* ★ V14 item 1：文件页「文件管理区 ↔ 预览」。
     * ⚠️ def 必须和 R/uiprefs.R 里 DSAPP_UIPREF_SPECS$filespage_w$def 以及
     *    app.css 里 .dsapp-files-list 那条 var() 的 fallback 三处一字不差。
     * ⚠️⚠️ 它和 files_w（「言出法随」页右边的产物栏）**不是一回事**，
     *    别合并成一个键 —— 见下面 current() 里那一段。 */
    filespage_w: { def: 420, min: 240, max: 1200 }
  };
  /* 文件区的宽度上限还要再过一个比例 —— 和 app.css 里那条 `max-width: 62%`
   * 是同一个数。CSS 那条管的是"换了窗口再打开"，这条管的是"正在拖"。 */
  var FILES_MAX_RATIO = 0.62;
  /* 输入区最多占到离页面底边这么近；留出来的是输出框，少于这个高度就没法看了 */
  var COMPOSER_TAIL = 220;
  /* 导航栏右边至少给主区留这么多：消息流才是这一页的正事，把导航栏拖到
   * 只剩一条缝的消息流没有意义。和 COMPOSER_TAIL 是一对。 */
  var SESS_TAIL = 360;

  var root = document.documentElement;

  function setVar(name, px) {
    root.style.setProperty("--dsapp-" + name.replace("_", "-"), px + "px");
  }

  /* 这条把手调的是哪个量。
   *
   * ★ 原来靠类区分（.dsapp-split-v = 文件区、.dsapp-split-h = 输入区），
   *   V13.4 加了导航栏之后**有两个都是"竖着拖"的把手**，类分不出来了 ——
   *   继续靠类去猜的话，拖导航栏会去改文件区的宽度。服务端渲染时写死了
   *   `data-dsapp-panel`，这里直接读；老的两条没写这个属性，走类兜底。 */
  function panelOf(el) {
    var p = el.getAttribute && el.getAttribute("data-dsapp-panel");
    if (p && SPEC[p]) return p;
    return el.classList.contains("dsapp-split-v") ? "files_w" : "composer_h";
  }

  function page() {
    /* ★ 量 .dsapp-chat-page 而不是 window.innerHeight：这一页上面还有顶栏，
     *   用窗口高度算出来的上限会比实际能用的多出几十像素，正好是"拖到底
     *   还是把页面顶出滚动条"的那几十像素。 */
    return document.querySelector(".dsapp-chat-page") ||
           document.querySelector(".dsapp-chat-main");
  }

  function clampW(px) {
    var main = document.querySelector(".dsapp-chat-main");
    var cap = SPEC.files_w.max;
    if (main && main.clientWidth > 0) {
      cap = Math.min(cap, Math.floor(main.clientWidth * FILES_MAX_RATIO));
    }
    /* ⚠️ cap 有可能被挤到 min 以下（窗口窄到 320px 以下时）。这时候取 min 会
     *    得到一个 > cap 的值，反而更糟；取 cap 会得到一个很小的宽度。两个都
     *    不理想，但小屏下 app.css 的 @media (max-width:1100px) 已经把两列
     *    改成上下叠放了，宽度压根不生效 —— 所以这里只要不返回负数就行。 */
    return Math.max(SPEC.files_w.min, Math.min(cap, Math.round(px)));
  }

  function clampH(px) {
    var p = page();
    var cap = SPEC.composer_h.max;
    if (p && p.clientHeight > 0) {
      cap = Math.min(cap, Math.floor(p.clientHeight - COMPOSER_TAIL));
    }
    return Math.max(SPEC.composer_h.min, Math.min(Math.max(cap, SPEC.composer_h.min),
                                                  Math.round(px)));
  }

  /* ★ V13.5 item 2：历史任务页左栏（执行历史）的宽度上限。
   *
   * 和 clampW 同一个形状（也是"左栏 + 右栏吃剩下"），但**容器不一样**：
   * 那边量的是 .dsapp-chat-main，这边是 .dsapp-task-page。共用一个函数的话
   * 就得在里面判断"现在在哪一页"，而那个判断在拖动过程中每一帧都要跑。 */
  var TASKS_MAX_RATIO = 0.8;
  function clampTasks(px) {
    var page = document.querySelector(".dsapp-task-page");
    var cap = SPEC.tasks_w.max;
    if (page && page.clientWidth > 0) {
      cap = Math.min(cap, Math.floor(page.clientWidth * TASKS_MAX_RATIO));
    }
    /* cap 可能被挤到 min 以下（窗口极窄），和 clampW 一样两层都夹一遍。 */
    return Math.max(SPEC.tasks_w.min, Math.min(Math.max(cap, SPEC.tasks_w.min),
                                               Math.round(px)));
  }

  /* ★ V13.5 item 8：主菜单的宽度上限。
   *
   * ⚠️ 和 clampSess 的**结构一样但容器不一样**：这条把手挂在 .dsapp-shell
   *    上（主菜单是它的第一列），所以 el.parentElement 就是那个 shell。
   *    拿 .dsapp-chat-main 去算会得到 undefined → 退回 SPEC 的硬上限，
   *    在窄窗口下能把主区挤没。 */
  /* ★ V14 item 1：文件页左栏（文件管理区）的宽度上限。
   *
   * 和 clampTasks 同一个形状（左栏定宽 + 右栏吃剩下），容器是
   * .dsapp-files-page。
   *
   * ⚠️ 右边的预览栏也有个下限（一个 iframe，窄到 300px 以下就没法看了），
   *    所以除了比例，还要按 FILEPREV_TAIL 给右栏留够位置 —— 和 clampMenu
   *    的 MENU_TAIL 同一个道理：光有比例的话，在很宽的屏幕上 62% 能到
   *    一千多像素，右栏只剩一点点。 */
  var FILESPAGE_MAX_RATIO = 0.7;
  var FILEPREV_TAIL = 380;
  function clampFilesPage(px) {
    var page = document.querySelector(".dsapp-files-page");
    var cap = SPEC.filespage_w.max;
    if (page && page.clientWidth > 0) {
      cap = Math.min(cap, Math.floor(page.clientWidth * FILESPAGE_MAX_RATIO),
                     page.clientWidth - FILEPREV_TAIL);
    }
    /* cap 可能被挤到 min 以下（窗口极窄），和上面几条一样两层都夹一遍。 */
    return Math.max(SPEC.filespage_w.min, Math.min(Math.max(cap, SPEC.filespage_w.min),
                                                   Math.round(px)));
  }

  var MENU_TAIL = 640;
  function clampMenu(px, el) {
    var shell = el && el.parentElement;
    var cap = SPEC.menu_w.max;
    if (shell && shell.clientWidth > 0) {
      cap = Math.min(cap, Math.floor(shell.clientWidth - MENU_TAIL));
    }
    return Math.max(SPEC.menu_w.min, Math.min(Math.max(cap, SPEC.menu_w.min),
                                              Math.round(px)));
  }

  /* 导航栏的宽度上限：按**这个 layout 自己**有多宽现算。
   *
   * ⚠️ 取 el.parentElement 而不是 document.querySelector('.bslib-sidebar-layout')：
   *    这条把手是挂在 layout 上的（见 mod_chat.R 里那段），父亲就是它。
   *    用全局查询的话，将来第二个 layout 出现时会拿错容器。 */
  function clampSess(px, el) {
    var lay = el && el.parentElement;
    var cap = SPEC.sess_w.max;
    if (lay && lay.clientWidth > 0) {
      cap = Math.min(cap, Math.floor(lay.clientWidth - SESS_TAIL));
    }
    /* 和 clampW 一样，cap 有可能被挤到 min 以下（窗口很窄时）。取 min
     * 会得到一个 > cap 的值反而更糟，所以两层都夹一遍。 */
    return Math.max(SPEC.sess_w.min, Math.min(Math.max(cap, SPEC.sess_w.min),
                                              Math.round(px)));
  }

  function report(el, which, val) {
    if (!el || !el.id || !window.Shiny) return;
    /* ★ 六条分隔条报的是**同一个** input（服务端一个 observeEvent 全收），
     *   "是哪一条"体现在消息里的**键**上。所以正则是 [vhstmf] 六个字母。
     *   ⚠️ id 是 ns() 出来的，形如 `chat-split_s` —— 只认**结尾**。
     *   ⚠️⚠️ 加一条分隔条就必须在这里补上它的后缀字母。漏掉的症状**不是**
     *      报错，是那条分隔条"拖了没反应、松手弹回去"：
     *      `inputId === el.id` 那一行直接 return，一次上报都没发出去，
     *      控制台干干净净。 */
    var inputId = el.id.replace(/split_[vhstmf]$/, "panel_size");
    if (inputId === el.id) return;   /* id 不是预期形状，宁可不报也不报错地方 */
    var msg = {};
    msg[which] = val;
    Shiny.setInputValue(inputId, msg, { priority: "event" });
  }

  function applyComposer(h) {
    setVar("composer_h", h);
    /* 这个类必须和变量**同时**改：只改变量的话，CSS 里两条规则都不匹配，
     * 输入区还是自动高度（看起来像"拖了没反应"）；只改类的话变量还是 0。 */
    root.classList.toggle("dsapp-fixed-composer", h > 0);
  }

  /* 当前这一条把手控制的量**现在**是多少。
   *
   * ⚠️ 一律去 DOM 上**量**，不读变量：变量可能是 px 也可能是别的单位，
   *    而且"没定义"时它根本不存在（那时界面用的是 CSS 里的默认值）。
   *    量出来的才是用户眼前这一条线的位置。 */
  function current(el) {
    var which = panelOf(el);
    if (which === "menu_w") {
      /* 主菜单是 .dsapp-shell 的第一列，把手就挂在 shell 上。 */
      var sh = el.parentElement;
      var rail = sh && sh.querySelector(":scope > .dsapp-rail");
      return { which: which, val: rail ? rail.getBoundingClientRect().width
                                       : SPEC.menu_w.def };
    }
    if (which === "tasks_w") {
      var col = document.querySelector(".dsapp-task-hist");
      return { which: which, val: col ? col.getBoundingClientRect().width
                                      : SPEC.tasks_w.def };
    }
    if (which === "sess_w") {
      /* 同一份 layout 里的 .sidebar —— 不去全局找，理由同 clampSess。 */
      var lay = el.parentElement;
      var sb = lay && lay.querySelector(":scope > .sidebar");
      return { which: which, val: sb ? sb.getBoundingClientRect().width
                                     : SPEC.sess_w.def };
    }
    if (which === "files_w") {
      var col = document.querySelector(".dsapp-files-col");
      return { which: which, val: col ? col.getBoundingClientRect().width
                                      : SPEC.files_w.def };
    }
    if (which === "filespage_w") {
      /* ★ V14 item 1：文件页左栏。
       *
       * ⚠️⚠️ 查的是 `.dsapp-files-list`（文件**页**里的文件管理区），
       *    不是 `.dsapp-files-col`（「言出法随」页右边的产物栏）。
       *    两者长得像但住在不同的页面里，混用的表现非常隐蔽：
       *      * 在文件页拖动时去量对话页那一列 —— 那一页此刻是 display:none，
       *        getBoundingClientRect() 给出的宽度是 **0**（页面隐藏时所有
       *        几何量都是 0，而且不报错），于是起点按 0 算，一碰就跳到下限；
       *      * 存进库里的又是同一个键，用户调完文件页，对话页的产物栏跟着变。
       *    两个症状都不抛异常，控制台干干净净。 */
      var lp = document.querySelector(".dsapp-files-list");
      return { which: which, val: lp ? lp.getBoundingClientRect().width
                                     : SPEC.filespage_w.def };
    }
    var box = document.querySelector(".dsapp-composer");
    return { which: which, val: box ? box.getBoundingClientRect().height
                                    : SPEC.composer_h.def };
  }

  /* 把某个量写到页面上。**只有这一个地方**碰变量和类 ——
   * 拖动、键盘、双击重置三条路都从这里走。
   * ⚠️ 分开写的话迟早有一路漏掉 `applyComposer` 里那个类（或者反过来只加类
   *    不改值），表现是"某一种操作方式没反应"，而另外两种是好的。 */
  function applyPanel(which, val) {
    if (which === "composer_h") { applyComposer(val); return; }
    setVar(which, val);
  }

  function clampPanel(which, px, el) {
    if (which === "sess_w")     return clampSess(px, el);
    if (which === "files_w")    return clampW(px);
    if (which === "menu_w")     return clampMenu(px, el);
    if (which === "tasks_w")    return clampTasks(px);
    if (which === "filespage_w") return clampFilesPage(px);
    return clampH(px);
  }

  /* 双击 = 回默认。
   * ⚠️ 输入区那个"默认"是 0（自动高度），要连着把 dsapp-fixed-composer
   *    类摘掉 —— 所以走 applyComposer 而不是 setVar。 */
  function reset(el) {
    var c = current(el);
    applyPanel(c.which, SPEC[c.which].def);
    report(el, c.which, SPEC[c.which].def);
  }

  var drag = null;

  /* ★ 三条分隔条的选择器写在这一处，四个处理器共用。
   *   ⚠️ 别再手抄成字符串字面量：加了导航栏那条之后一共三个类，抄漏一个的
   *      表现是"某一条拖不动"，而且四个处理器里只坏一个，最难查。 */
  var SEL = ".dsapp-split-v, .dsapp-split-h, .dsapp-sess-handle, .dsapp-rail-handle";

  /* 拖动方向 → 增量。★ 每个量各有各的"变大的方向"，由**被调的那一栏在
   *   把手左边还是右边**决定：
   *     在把手左边 → 往右拖 = 变宽（sess_w 会话列表、menu_w 主菜单、
   *                                tasks_w 执行历史、filespage_w 文件管理区）
   *     在把手右边 → 往左拖 = 变宽（files_w 对话页产物栏）
   *     在把手下面 → 往上拖 = 变高（composer_h 输入区）
   *   ⚠️ 左右两种的符号**相反**。照抄错的一边，手感就是"反着来的"，
   *      而这个错误在代码里看不出任何异常 —— 拖动是好的，只是方向拧了。
   *
   *   ⚠️ tasks_w 和 filespage_w 都是**左边**那一组，别因为名字里带"files"
   *      就把 filespage_w 跟 files_w 归一堆：files_w 那一栏在「言出法随」页
   *      **右边**（消息流在左、产物栏在右），filespage_w 在「文件」页
   *      **左边**（文件管理区在左、预览在右）。同名的东西方向相反。
   *      归错组的症状很轻 —— 拖起来是"反的"，但宽度确实在变，
   *      不盯着看不会觉得是 bug。 */
  function dragDelta(which, e) {
    if (which === "composer_h") return drag.y - e.clientY;
    if (which === "sess_w" || which === "menu_w" || which === "tasks_w" ||
        which === "filespage_w") {
      return e.clientX - drag.x;
    }
    return drag.x - e.clientX;
  }

  document.addEventListener("pointerdown", function (e) {
    if (e.button !== undefined && e.button !== 0) return;   /* 只认左键 */
    var el = e.target.closest && e.target.closest(SEL);
    if (!el) return;
    e.preventDefault();
    var c = current(el);
    drag = { el: el, which: c.which, start: c.val,
             x: e.clientX, y: e.clientY, moved: false };
    el.classList.add("dsapp-split-on");
    root.classList.add(c.which === "composer_h" ? "dsapp-resizing-h" : "dsapp-resizing-v");
    /* 拖出窗口/拖到别的元素上也要收得到后续事件 */
    try { el.setPointerCapture(e.pointerId); } catch (err) { /* 老浏览器 */ }
  });

  document.addEventListener("pointermove", function (e) {
    if (!drag) return;
    e.preventDefault();
    var d = dragDelta(drag.which, e);
    if (!d && !drag.moved) return;
    drag.moved = true;
    /* ★ 输入区第一次真的动了才从"自动高度"切成固定高度。在 pointerdown 就切
     *   的话，单纯点一下分隔条（没拖）也会把输入区钉成当前像素高度 —— 那个
     *   高度是窗口给它的，换个窗口尺寸就不对了。
     *   （这一条只对 composer_h 有意义，但放在这里不影响另外两个：它们的
     *     applyPanel 就是一次 setVar。） */
    applyPanel(drag.which, clampPanel(drag.which, drag.start + d, drag.el));
  });

  function endDrag(e) {
    if (!drag) return;
    var d = drag;
    drag = null;
    d.el.classList.remove("dsapp-split-on");
    root.classList.remove("dsapp-resizing-v", "dsapp-resizing-h");
    try { d.el.releasePointerCapture(e.pointerId); } catch (err) { /* noop */ }
    if (!d.moved) return;    /* 只是点了一下，什么都没变，不用上报 */
    var c = current(d.el);
    report(d.el, d.which, Math.round(c.val));
  }

  document.addEventListener("pointerup", endDrag);
  document.addEventListener("pointercancel", endDrag);

  document.addEventListener("dblclick", function (e) {
    var el = e.target.closest && e.target.closest(SEL);
    if (!el) return;
    e.preventDefault();
    reset(el);
  });

  /* 键盘那条路。分隔条本身 tabindex=0，聚焦之后方向键就能挪。
   * ⚠️ 只认方向键，别的键一律放行 —— 在这里 preventDefault 会吃掉
   *    Tab（走不掉）和 Enter。 */
  document.addEventListener("keydown", function (e) {
    var el = e.target.closest && e.target.closest(SEL);
    if (!el) return;
    var c = current(el);
    var step = e.shiftKey ? 50 : 10;
    /* ★ 方向键的**语义**是"把这条线往哪边推"，所以左/右的含义跟着面板走 ——
     *   和上面 dragDelta 是同一套符号，改一处就得改另一处。
     *   在把手**左边**的那三栏（任务导航栏 / 主菜单 / 执行历史栏）：
     *   ArrowRight = 变宽。
     *   在把手**右边**的（文件区）：ArrowLeft = 变宽。
     *
     * ⚠️⚠️ V13.5 item 2 加 tasks_w 时**漏了这一处**。它是和 dragDelta
     *    分开写的第二份符号表，所以症状是"鼠标拖是对的、方向键是反的"：
     *    用户 Tab 到那条分隔条上按方向键，宽度往反方向跳。拖动是绝大多数
     *    人用的那条路，所以这个错很难在界面上被撞见 —— 而它一旦被撞见，
     *    看起来就像"这一页的键盘操作全乱了"。
     *    加新面板时**两处一起改**，别只改 dragDelta。 */
    var grow, shrink;
    if (c.which === "composer_h") { grow = "ArrowUp";   shrink = "ArrowDown"; }
    else if (c.which === "sess_w" || c.which === "menu_w" ||
             c.which === "tasks_w" || c.which === "filespage_w") {
      grow = "ArrowRight"; shrink = "ArrowLeft";
    } else { grow = "ArrowLeft"; shrink = "ArrowRight"; }

    var delta, want = null;
    if (e.key === grow)        delta = step;
    else if (e.key === shrink) delta = -step;
    else if (e.key === "Home") want = SPEC[c.which].def;
    if (delta === undefined && want === null) return;
    e.preventDefault();
    if (want === null) want = clampPanel(c.which, c.val + delta, el);
    applyPanel(c.which, want);
    report(el, c.which, want);
  });

  /* ---- 和服务端那段 <script> 的约定 --------------------------------------
   *
   * 服务端每次下发尺寸时会先 `removeProperty()` 把内联变量清掉，好让样式表
   * 里那份说了算（不然内联值会一直压着：设置页把 420 改成 500，页面纹丝
   * 不动，控制台一个错都没有）。但**拖动过程中不能清** —— 清的那一下宽度
   * 会跳回上一次存的值。
   *
   * 两边靠这个旗子对齐：这里在按下时立起来、松手时放倒，那边清之前看一眼。
   * ⚠️ 旗子挂在 window 上，不挂在闭包变量里：那段脚本和这里是两个作用域。 */
  window.dsappDragging = false;

  /* 用捕获阶段，跑在上面那些处理器**之前**：松手时 endDrag() 要发上报，而那
   * 之前旗子就得先放倒（服务端的回应虽然到不了这么快，但顺序摆正了就不用
   * 去想"到底谁先"）。 */
  document.addEventListener("pointerdown", function (e) {
    if (e.target && e.target.closest && e.target.closest(SEL)) {
      window.dsappDragging = true;
    }
  }, true);
  ["pointerup", "pointercancel"].forEach(function (ev) {
    document.addEventListener(ev, function () { window.dsappDragging = false; }, true);
  });
})();

/* ---- 技能列表：拖着排序（V13.2 item 13）--------------------------------- */

/* 用户原话：「skills需要能够支持按照名称、时间等信息进行排序，并且可以拖拽
 *           自定义顺序」。
 *
 * ★ 拖的时候**直接挪 DOM**（不是画一条占位线、松手再重排）：拖动过程中看到
 *   的就是最后的顺序，松手不需要"跳一下"。松手后只做一件事 —— 把当前
 *   从上到下的 id 报上去，服务端存下来（见 dsapp_skill_order_set）。
 *
 * ⚠️ 只有 `.dsapp-skill-drag` 那个手柄是 draggable，整行不是：整行可拖的话
 *    "点标题展开""选中简介里的一段字"都会变成开始拖，而那两件事用户天天在
 *    做。拖动时用 setDragImage 把**整行**当影子，所以看起来还是拖了一整行。
 *
 * ⚠️ 用 HTML5 的 drag 事件，不用 pointer 事件（分隔条那条用的是 pointer）：
 *    这里要的正是"拖到别的元素**上面**"这个语义，dragover 直接给的就是
 *    目标行；用 pointer 得自己拿 elementFromPoint 去撞，撞出来的还是同一个
 *    东西，只是多一层自己维护的坐标计算。
 *
 * ⚠️ `dragover` 里**必须** preventDefault，否则 drop 永远不触发（浏览器的
 *    默认行为是"不接受放置"）。这是 HTML5 拖拽最容易漏的一句，漏了的表现
 *    是"能拖、影子也在动、松手什么都没发生"。 */
(function () {
  var dragRow = null;      /* 正在拖的那一行 */
  var fromList = null;     /* 它原来在哪个列表里 */
  var origOrder = null;    /* 拖之前从上到下的 id，用来在"拖到列表外面"时还原 */
  var dropped = false;

  function rows(list) {
    return Array.prototype.slice.call(
      list.querySelectorAll(":scope > .dsapp-skill-row"));
  }

  function idsOf(list) {
    return rows(list).map(function (r) {
      var h = r.querySelector(".dsapp-skill-drag");
      return h ? h.getAttribute("data-id") : null;
    }).filter(function (x) { return x; });
  }

  function report(list) {
    var host = list.closest("[data-input-order]") || list;
    var inputId = host.getAttribute("data-input-order");
    if (!inputId || !window.Shiny) return;
    Shiny.setInputValue(inputId, idsOf(list), { priority: "event" });
  }

  document.addEventListener("dragstart", function (e) {
    var h = e.target.closest && e.target.closest(".dsapp-skill-drag");
    if (!h || h.getAttribute("draggable") !== "true") return;
    dragRow = h.closest(".dsapp-skill-row");
    if (!dragRow) return;
    fromList = dragRow.parentElement;
    origOrder = idsOf(fromList);
    dropped = false;
    dragRow.classList.add("dsapp-skill-dragging");
    if (e.dataTransfer) {
      /* 有些浏览器（Firefox）不给 dataTransfer 就**不开始拖** */
      e.dataTransfer.effectAllowed = "move";
      try { e.dataTransfer.setData("text/plain", h.getAttribute("data-id")); }
      catch (err) { /* 老浏览器 */ }
      try { e.dataTransfer.setDragImage(dragRow, 12, 12); } catch (err) { /* noop */ }
    }
  });

  document.addEventListener("dragover", function (e) {
    if (!dragRow) return;
    var over = e.target.closest && e.target.closest(".dsapp-skill-row");
    if (!over || over === dragRow || over.parentElement !== fromList) return;
    e.preventDefault();          /* ← 不写这句 drop 不会触发，见上面 */
    if (e.dataTransfer) e.dataTransfer.dropEffect = "move";

    /* 落在上半还是下半 → 插到它前面还是后面 */
    var r = over.getBoundingClientRect();
    var after = e.clientY > r.y + r.height / 2;
    var ref = after ? over.nextSibling : over;
    if (ref === dragRow || ref === dragRow.nextSibling) return;   /* 已经在那了 */
    fromList.insertBefore(dragRow, ref);

    rows(fromList).forEach(function (x) {
      x.classList.remove("dsapp-skill-over-top", "dsapp-skill-over-bot");
    });
    over.classList.add(after ? "dsapp-skill-over-bot" : "dsapp-skill-over-top");
  });

  document.addEventListener("drop", function (e) {
    if (!dragRow) return;
    e.preventDefault();          /* 不拦的话浏览器会尝试打开被拖的东西 */
    var list = fromList;         /* ⚠️ 必须在 cleanup() 之前取：它会把 fromList 清掉 */
    dropped = true;
    cleanup();
    if (list) report(list);
  });

  /* dragend 一定会发（drop 之后也发，被取消时也发），所以清理放在这里。
   * ⚠️ 拖到列表**外面**松手时（effectAllowed 对不上、或者落在空白处）
   *    drop 不会触发，但 DOM 已经被 dragover 挪过了 —— 不还原的话用户看到
   *    顺序变了、刷新一下又回去了，而且他并没有"放下"过。 */
  document.addEventListener("dragend", function () {
    if (!dragRow) return;
    var wasDropped = dropped;
    var list = fromList, order = origOrder;
    cleanup();
    if (wasDropped || !list || !order) return;
    var now = idsOf(list);
    if (now.join(",") === order.join(",")) return;
    /* 按原来的 id 顺序把行放回去 */
    var byId = {};
    rows(list).forEach(function (r) {
      var h = r.querySelector(".dsapp-skill-drag");
      if (h) byId[h.getAttribute("data-id")] = r;
    });
    order.forEach(function (id) {
      if (byId[id]) list.appendChild(byId[id]);
    });
  });

  function cleanup() {
    var all = document.querySelectorAll(".dsapp-skill-row");
    for (var i = 0; i < all.length; i++) {
      all[i].classList.remove("dsapp-skill-dragging",
                              "dsapp-skill-over-top", "dsapp-skill-over-bot");
    }
    dragRow = null; fromList = null; origOrder = null; dropped = false;
  }

  /* 键盘：手柄聚焦之后，上下方向键把这一行挪一格。和拖拽走**同一条上报
   * 路径**（挪完 DOM 就报当前顺序），所以两条路不会各自演化出一套语义。 */
  document.addEventListener("keydown", function (e) {
    var h = e.target.closest && e.target.closest(".dsapp-skill-drag");
    if (!h || h.getAttribute("draggable") !== "true") return;
    if (e.key !== "ArrowUp" && e.key !== "ArrowDown") return;
    var row = h.closest(".dsapp-skill-row");
    var list = row && row.parentElement;
    if (!list) return;
    e.preventDefault();
    if (e.key === "ArrowUp") {
      var prev = row.previousElementSibling;
      if (!prev || !prev.classList.contains("dsapp-skill-row")) return;
      list.insertBefore(row, prev);
    } else {
      var next = row.nextElementSibling;
      if (!next || !next.classList.contains("dsapp-skill-row")) return;
      list.insertBefore(next, row);
    }
    /* 挪完焦点还在手柄上（我们挪的是同一个节点，不是重建一个）——
     * 连按就能一路挪到底，这是这个写法顺带的好处。 */
    report(list);
  });
})();

/* ---- 左侧全局导航：拖着重排顺序（V13.11 item 3）-------------------------- */

/* 用户原话：「最左侧导航栏也需要可以通过拖拽改变位置」。
 *
 * ⚠️ 「改变位置」有两种读法，都实现了，别搞混：
 *      · 拖**宽**那条栏   → V13.5 item 8，menu_w，把手在栏的右边缘
 *                           （.dsapp-rail-handle，走的是 pointer 事件那条路）
 *      · 拖**动里面的项** → 就是这一段，nav_order，把手是每一项左边那个 ⠿
 *    两件事共用一个"最左边那条栏"，但是两个量、两条上报路径。
 *
 * ★ 和技能列表那段（.dsapp-skill-drag）是**同一套做法**，理由也逐条相同：
 *   拖的时候直接挪 DOM、松手只报一次顺序、dragover 必须 preventDefault、
 *   拖到外面松手要还原。差别只有三处：
 *     1. 行是 `.dsapp-rail-link`，把手是 `.dsapp-rail-grip`，id 是 `data-nav`
 *     2. 宿主只有**一个**（就是这条栏），不像技能有"未分组/各个文件夹"
 *     3. 上报的是**顶层**的 input（`nav_order`），因为这条栏长在 app.R 的
 *        外壳里、不在任何模块里，id 没有命名空间前缀
 *
 * ⚠️ 只有 `.dsapp-rail-grip` 是 draggable，整行不是 —— 而且 app.R 那边给
 *    `<a>` 显式加了 `draggable="false"`。<a href> 在浏览器里**天生可拖**，
 *    不关掉的话用户按住行拖会触发浏览器的"拖链接"，影子是有的、但松手什么
 *    都不发生，看起来就是"这个功能没做"。
 *
 * ⚠️ 拖动期间**不重画这条栏**。服务端收到 nav_order 之后只存库、不 bump
 *    任何会让 dsapp_main_ui 重渲染的东西（见 app.R 里那条 observeEvent）。
 *    重画的话用户拖到一半的第二次拖动会被冲掉，而且视觉上会闪一下。 */
(function () {
  var dragRow = null;      /* 正在拖的那个 .dsapp-rail-link */
  var list = null;         /* 它所在的 .dsapp-rail-nav */
  var origOrder = null;    /* 拖之前从上到下的 value，用来在"拖到栏外"时还原 */
  var dropped = false;

  /* ⚠️ 这两个都**把宿主当参数收**，不读上面的 `list` —— 这不是风格问题：
   *    drop 那条路上必须"先 cleanup()（它会把 list 置空）、再上报"，
   *    而 cleanup() 之后读 `list` 拿到的是 null，上报**静默变成空操作**。
   *    症状极难查：拖动本身完全正常（DOM 挪了、影子在动、松手也不报错），
   *    只有"刷新之后顺序回去了"。写完当场踩到 —— 技能那段之所以是
   *    report(list) 而不是 report()，就是为了这个，照抄时漏了。 */
  function rows(el) {
    return el ? Array.prototype.slice.call(
      el.querySelectorAll(":scope > .dsapp-rail-link")) : [];
  }

  function idsOf(el) {
    return rows(el).map(function (r) {
      return r.getAttribute("data-nav");
    }).filter(function (x) { return x; });
  }

  function report(el) {
    if (!el || !window.Shiny) return;
    var inputId = el.getAttribute("data-input-order");
    if (!inputId) return;
    Shiny.setInputValue(inputId, idsOf(el), { priority: "event" });
  }

  document.addEventListener("dragstart", function (e) {
    var h = e.target.closest && e.target.closest(".dsapp-rail-grip");
    if (!h || h.getAttribute("draggable") !== "true") return;
    dragRow = h.closest(".dsapp-rail-link");
    if (!dragRow) return;
    list = dragRow.parentElement;
    if (!list) { dragRow = null; return; }
    origOrder = idsOf(list);
    dropped = false;
    dragRow.classList.add("dsapp-rail-dragging");
    if (e.dataTransfer) {
      /* 有些浏览器（Firefox）不给 dataTransfer 就**不开始拖** */
      e.dataTransfer.effectAllowed = "move";
      try { e.dataTransfer.setData("text/plain", h.getAttribute("data-nav")); }
      catch (err) { /* 老浏览器 */ }
      try { e.dataTransfer.setDragImage(dragRow, 12, 12); } catch (err) { /* noop */ }
    }
  });

  document.addEventListener("dragover", function (e) {
    if (!dragRow) return;
    var over = e.target.closest && e.target.closest(".dsapp-rail-link");
    /* ⚠️ over.parentElement 必须比一下：鼠标移到别的栏上（比如以后再加一条
     *    侧栏）时不能把行挪过去 —— 这条栏的顺序是**一个整体**，不是可以
     *    跨栏搬运的东西。 */
    if (!over || over === dragRow || over.parentElement !== list) return;
    e.preventDefault();          /* ← 不写这句 drop 不会触发，见上面 */
    if (e.dataTransfer) e.dataTransfer.dropEffect = "move";

    /* 导航项是**上下**排的，所以比的是 Y 的中线 —— 和技能那一行一样。
     * ⚠️ 别改成比 X：这条栏窄的时候（menu_w 拖到 180）一行里的横向差别
     *    很小，判出来的落点会来回跳。 */
    var r = over.getBoundingClientRect();
    var after = e.clientY > r.y + r.height / 2;
    var ref = after ? over.nextSibling : over;
    if (ref === dragRow || ref === dragRow.nextSibling) return;   /* 已经在那了 */
    list.insertBefore(dragRow, ref);

    rows(list).forEach(function (x) {
      x.classList.remove("dsapp-rail-over-top", "dsapp-rail-over-bot");
    });
    over.classList.add(after ? "dsapp-rail-over-bot" : "dsapp-rail-over-top");
  });

  document.addEventListener("drop", function (e) {
    if (!dragRow) return;
    e.preventDefault();          /* 不拦的话浏览器会尝试打开被拖的链接 */
    dropped = true;
    /* ⚠️ 先把宿主抓下来，cleanup() 会把 list 置空 —— 顺序反了上报就是
     *    空操作（见上面 report 那段）。 */
    var had = list;
    cleanup();
    report(had);
  });

  /* dragend 一定会发（drop 之后也发，被取消时也发），所以清理放在这里。
   * ⚠️ 拖到栏**外面**松手时 drop 不触发，但 DOM 已经被 dragover 挪过了 ——
   *    不还原的话用户看到顺序变了、刷新一下又回去了，而他并没有"放下"过。 */
  document.addEventListener("dragend", function () {
    if (!dragRow) return;
    var wasDropped = dropped;
    var l = list, order = origOrder;
    cleanup();
    if (wasDropped || !l || !order) return;
    if (idsOf(l).join(",") === order.join(",")) return;
    var byId = {};
    rows(l).forEach(function (r) {
      byId[r.getAttribute("data-nav")] = r;
    });
    order.forEach(function (id) {
      if (byId[id]) l.appendChild(byId[id]);
    });
  });

  function cleanup() {
    rows(list).forEach(function (r) {
      r.classList.remove("dsapp-rail-dragging",
                         "dsapp-rail-over-top", "dsapp-rail-over-bot");
    });
    dragRow = null; list = null; origOrder = null; dropped = false;
  }

  /* 键盘：把手聚焦之后，上下方向键把这一项挪一格。和拖拽走**同一条上报
   * 路径**，所以两条路不会各自演化出一套语义。
   *
   * ⚠️ 这条不是"锦上添花"：拖拽只能用鼠标，而这条栏是**全局导航**，
   *    对触摸板不好使的人、键盘用户来说，"顺序被自己拖乱了却改不回来"
   *    是实打实的用不了（设置页的「恢复默认」能救，但那是全量重置）。 */
  document.addEventListener("keydown", function (e) {
    var h = e.target.closest && e.target.closest(".dsapp-rail-grip");
    if (!h || h.getAttribute("draggable") !== "true") return;
    if (e.key !== "ArrowUp" && e.key !== "ArrowDown") return;
    var row = h.closest(".dsapp-rail-link");
    var l = row && row.parentElement;
    if (!l) return;
    e.preventDefault();
    if (e.key === "ArrowUp") {
      var prev = row.previousElementSibling;
      if (!prev || !prev.classList.contains("dsapp-rail-link")) return;
      l.insertBefore(row, prev);
    } else {
      var next = row.nextElementSibling;
      if (!next || !next.classList.contains("dsapp-rail-link")) return;
      l.insertBefore(next, row);
    }
    /* 挪完焦点还在把手上（我们挪的是同一个节点，不是重建一个）——
     * 连按就能一路挪到底。 */
    report(l);
  });
})();

/* ---- 「单次回复上限」那排建议值：选中态跟着真值走（V13.11 item 4）--------
 *
 * 背景：那排 4K/8K/32K/128K/1M/4M 是 mod_model.R 里 renderUI 出来的，`.on`
 * 是**渲染那一刻**按当时的值算的；而这一块只在厂商/模型/思考模式变化时重建
 * （故意不跟着值重建——那会把用户正在输入的内容顶掉）。所以用户拖滑块、或者
 * 直接在输入栏里填个数之后，亮着的还是旧的那一档。症状是"我明明填的 4M，
 * 亮的却是 1M"，用户没法相信屏幕上哪个数才算数。
 *
 * 做法：服务端只负责**初值**，之后每次变化都在这里对齐。不去碰输入框本身，
 * 只改 class，所以不会跟 Shiny 的绑定打架。
 *
 * ⚠️ 认的是 `data-tok`（mod_model.R 挂在 button 上的），不要去解析 onclick 里
 *    那串 Shiny.setInputValue —— 改一次消息格式就悄悄失效了。
 */
(function () {
  function sync(val) {
    var chips = document.querySelectorAll(".dsapp-sug-chip[data-tok]");
    var n = parseInt(val, 10);
    var hit = false;
    for (var i = 0; i < chips.length; i++) {
      var t = parseInt(chips[i].getAttribute("data-tok"), 10);
      var on = isFinite(n) && t === n;
      chips[i].classList.toggle("on", on);
      if (on) hit = true;
    }
    /* 值不在任何一档（比如手填的 9999999）→ 一个都不亮，这是对的：
     * 硬凑一档反而是在骗人。 */

    /* ★ V13.14 item 22：滑块右端那格「不设上限」的高亮。
     *
     * 判据和 chip 用**同一份输入**（输入栏里的字），所以两者永远不可能
     * 同时亮着 —— 空框就是"不设上限"，而空框本来就落进上面那个"一个都
     * 不亮"的分支，不需要额外互斥。
     *
     * ⚠️ 要显式判一次空串：`parseInt("")` 是 NaN，上面那圈靠 isFinite 挡住
     *    了，但这里不能靠 n —— 空串正是**要**亮的那一种。 */
    var lab = document.querySelector(".dsapp-maxtok-end-hi");
    if (lab) lab.classList.toggle("on", val === "" || !isFinite(n) || n <= 0);
    return hit;
  }

  function inputEl() {
    return document.getElementById("model-max_tokens");
  }

  /* ── 怎么知道值变了：不数事件，直接读输入栏 ──────────────────────────
   *
   * 本来想按"三条路各挂各的监听"来写，实测发现数不通（Chromium + Shiny
   * 1.10，settings 页点「1M」那一下）：
   *
   *   手填      原生 input + change 都发 → 挂 addEventListener 能收到
   *   拖滑块    服务端 updateNumericInput 回写输入栏，**一个原生事件都不发**
   *   点 chip   同上，什么都不发（输入栏里的数却真的变了）
   *
   * 而且 `shiny:inputchanged` 也是 jQuery 的 $(document).trigger() 发的，
   * **原生监听器一律收不到** —— 挂它的话会是一段看着像在工作、其实永远
   * 不执行的死代码，比不写还坏。
   *
   * 所以这里改成读**真值**（输入栏里的数）而不是听事件：值变了就对齐。
   * 谁改的、怎么改的都不用管，服务端 dsapp_param_clamp 夹过一轮之后也
   * 自动跟上（这点是挂事件做不到的——夹完那一轮同样不发事件）。 */
  var last = null;
  setInterval(function () {
    /* ⚠️ 先看这块在不在，不在就什么都不做：这段代码在**每一个**页面上都跑，
     *    而主界面的对话是流式输出的，别在那儿白读 DOM。
     *    ⚠️ 判据要**两个都看**（chip 和右端那格）：量程很小的模型一个建议值
     *       都摆不出来（dsapp_maxtok_suggestions 会全过滤掉），那时 chip 是
     *       空的，但「不设上限」那一格还在 —— 只判 chip 的话它永远不亮。 */
    if (!document.querySelector(".dsapp-sug-chip[data-tok]") &&
        !document.querySelector(".dsapp-maxtok-end-hi")) {
      last = null;
      return;
    }
    var i = inputEl();
    if (!i || i.value === last) return;
    last = i.value;
    sync(i.value);
  }, 300);

  /* 手填的时候这层让高亮**当拍**就跟上（不用等上面那 300ms 的拍子）。
   * 认 id 而不是认 e.name：这是原生 DOM 事件，target 就是那个输入框。 */
  ["input", "change"].forEach(function (ev) {
    document.addEventListener(ev, function (e) {
      var t = e.target;
      if (!t || !t.id || !/(^|-)max_tokens$/.test(t.id)) return;
      last = t.value;
      sync(t.value);
    }, true);
  });

  /* ⚠️ 这里**故意没有** MutationObserver。曾经想用一个盯着整棵文档的
   *    childList 观察器来处理"renderUI 重建后重新对齐"，但：
   *      (a) temp_ui 重建时滑块、输入栏、chip 行是**同一批**从同一个 kval
   *          画出来的，服务端算的 .on 本来就是对的，不需要事后补救；
   *      (b) 代价是每插一个节点都要 querySelectorAll 一次 —— 而这个应用
   *          的主界面在**流式输出**，一秒钟往 DOM 里插几十上百个节点。
   *    上面两条已经把三条改值的路（手填 / 拖滑块 / 点 chip）全盖住了。 */
})();

/* ---- 别的页 → 言出法随：把一段提示词交给对话页（V13.11 item 5）-----------
 *
 * ★ V16.1 item 4 起，这条通道**不只是文献速递在用** —— 云工具页的
 *   「TCGA 数据挖掘」「单细胞分析」两块也是把开场白丢进来、由这里转发。
 *   所以下面这段读的时候把"文献速递页"理解成"任何想开一个新对话的页"。
 *
 * 那些页自己不检索、也不发请求。它们把"新建对话 + 把这段提示词发出去"
 * 交给对话页做（理由见 R/mod_lit.R 顶上那段），中间这一步就是本函数：
 *
 *   1. 切到「言出法随」那一页（走服务端，见 dsappNav 的说明）
 *   2. 把提示词发给**对话模块**那个带命名空间的 input
 *
 * ⚠️ 那个 input 的真名（`chat-lit_go`）由 mod_chat 跟着 dsapp:init 一起
 *    下发，存在 dsappIds.litGo 里。**不要**在这里写死 `"chat-lit_go"` ——
 *    `chat-` 是模块命名空间，改一次模块 id 就静默失效（点了没反应，
 *    而且没有任何报错），这正是 dsappIds 这套东西存在的理由。
 */
Shiny.addCustomMessageHandler("dsapp:lit_go", function (m) {
  if (!m) return;
  /* 先切页再发：反过来的话，用户会先看到对话页闪一下旧内容。
   * 两者都是 setInputValue，服务端按到达顺序处理，所以这顺序是有效的。 */
  if (window.dsappNav) dsappNav("chat");
  if (!dsappIds.litGo) return;
  Shiny.setInputValue(dsappIds.litGo, {
    prompt: m.prompt || "",
    title:  m.title  || "",
    skills: m.skills || []
  }, { priority: "event" });
});

/* ---- 云工具页：图标式二级菜单切面板（★ V16.1 item 4）----------------------
 *
 * 用户原话：「蛋白质设计只是云工具的一部分，做成图标式二级菜单，比如再加一
 *           TCGA挖掘工具、单细胞分析工具」。
 *
 * ★ 为什么这件事在**前端**做，服务端一个 input 都不收：
 *   三个面板始终在 DOM 里，切的只是 class。走服务端就得 renderUI 重画，
 *   而重画会把「结合蛋白设计」那十几个参数控件连同用户已经填好的值一起
 *   铲掉 —— 填一半去隔壁看一眼再回来，参数全没了。那比不能切还难受。
 *
 * ⚠️ 这里**不碰** bslib / bootstrap 的 tab（data-bs-toggle 那一套）：本仓库
 *    的页签绑定跟 bootstrap 那套纠缠很深（app.R 顶上四十行写的就是它怎么把
 *    左栏点瘫的），一个页面内的装饰性切换没必要去惹它。自己认 data-tool /
 *    data-panel 两个属性，就是两行 classList.toggle 的事。
 *
 * ⚠️ 用**事件委托**（挂在 document 上），不逐个按钮 addEventListener：
 *    这一页是 renderUI 出来的，节点会被整体重建，绑在节点上的监听器跟着
 *    一起没 —— 症状是"刷新后能点、用一会儿就点不动"，而且不报错。
 */
document.addEventListener("click", function (e) {
  var t = e.target && e.target.closest ? e.target.closest(".dsapp-cloud-tile") : null;
  if (!t) return;
  var key = t.getAttribute("data-tool");
  if (!key) return;
  e.preventDefault();
  /* 只在这一页里找同伙：别页若哪天也有同名类，不至于跨页互相改。 */
  var root = t.closest(".dsapp-page") || document;
  root.querySelectorAll(".dsapp-cloud-tile").forEach(function (el) {
    el.classList.toggle("is-active", el === t);
  });
  root.querySelectorAll(".dsapp-cloud-panel").forEach(function (el) {
    el.classList.toggle("dsapp-cloud-hidden",
                        el.getAttribute("data-panel") !== key);
  });
});

/* ---- 云工具页：工具清单 / 编排路线 上那些「点一下」的按钮（★ V16.4）--------
 *
 * 用户原话：「按照 单细胞云平台Agent工具构建提示词.md 来优化单细胞云工具；
 *           按照 TCGA数据库挖掘云平台Agent工具构建提示词.md 来优化 TCGA
 *           数据挖掘模块」。
 *
 * 那两份文档里各有一张几十行的工具注册表，界面照它画出来（见
 * R/mod_cloudtool.R 的 mod_cloudtool_tool_row）。**每一行都是一个按钮**，
 * 但 R 那边只注册**一个** observeEvent：
 *
 *   · 逐个 actionButton + 逐个 observeEvent 的话，文档里加一个工具就要在 R
 *     里多注册一个观察者（现在是 49+58 个），而"忘了加"的表现是那一行点了
 *     没反应 —— 不报错。
 *   · 所以按钮用 data-* 装着"点的是哪个工具的哪个字段"，这里统一收口。
 *
 * ⚠️ input 的真名（`cloudtool-tool_go`）带模块命名空间，**不能**写死：
 *    写在容器上的 data-go 属性是 R 用 ns() 算好塞进来的，改一次模块 id
 *    也不会静默失效（和 dsappIds.litGo 那条同理，见上面 lit_go 的 ⚠️）。
 * ⚠️ 必须带 nonce：Shiny 对**相同**的值不重复触发事件，连点两下同一个按钮
 *    第二下就没了（本仓在发送按钮上踩过，见 dsappSendSeq）。
 * ⚠️ 用事件委托挂在 document 上：这些行是 renderUI 出来的，筛一次关键字
 *    整片节点就重建，绑在节点上的监听器跟着一起没 —— 症状是"筛一次之后就
 *    点不动了"，而且不报错。切面板那一段的 ⚠️ 讲的是同一件事。
 */
document.addEventListener("click", function (e) {
  var b = e.target && e.target.closest ? e.target.closest(".dsapp-cloud-go") : null;
  if (!b) return;
  var host = b.closest("[data-go]");
  if (!host) return;
  var id = host.getAttribute("data-go");
  if (!id || !window.Shiny || !Shiny.setInputValue) return;
  e.preventDefault();
  Shiny.setInputValue(id, {
    kind:  b.getAttribute("data-kind") || "",
    key:   b.getAttribute("data-key")  || "",
    plan:  b.getAttribute("data-plan") || "",
    nonce: Math.random()
  }, { priority: "event" });
});

/* ---- 分析中的进度条（V13.12 item 7）--------------------------------------
 *
 * 用户原话：「正在分析的时候总是闪屏，换成一个进度条或者转圈的效果吧」。
 *
 * ★ 为什么由前端自己判，而不是服务端发条消息过来：
 *   · 判断依据在 DOM 上全摆着 —— 正在流式输出有 .dsapp-cursor，正在跑任务
 *     有 .dsapp-run-chip / .dsapp-run-live。读它们不欠谁的人情。
 *   · 服务端那条路（sendCustomMessage）在**模块**里到底通不通，这个仓库里
 *     有过两种互相矛盾的记录（app.js 这边说能用，skins.R / utils.R 说不能，
 *     两边还都有"修好了"的案底 —— 见 utils.R 的 dsapp_session）。为一个
 *     装饰性的进度条去踩那颗雷不值。
 *   · 最关键的是：服务端每 200ms 重画一次消息流。任何"跟着重画"的指示器
 *     都会被拆掉重建，而 CSS 动画是元素一换就从头开始的 —— 那正是用户
 *     说的"闪"。所以这个条一次都不许重建（见 mod_chat.R 里的说明）。
 *
 * ⚠️ 只切 class，不碰别的属性/内容：本函数由观察整页的定时器调用，动了
 *    DOM 会把自己再触发一次。
 * ⚠️ 判据要带**宽限期**：Shiny 换 DOM 的那一瞬间 .dsapp-cursor 会短暂缺席，
 *    采到那一帧就会把条关掉、下一帧又打开 = 闪。所以记的是"最后一次看见
 *    忙到现在过了多久"，600ms 之内都算还忙着。
 */
(function () {
  var GRACE = 600;          /* 最后一次看见"忙"之后，再撑这么久才收工 */
  var lastBusy = 0;
  /* ★ V15.6 item 3：转圈那颗也要一份自己的"最后一次看见"。见下面 busySpin。 */
  var lastSpin = 0;

  function tick() {
    var bars = document.querySelectorAll(".dsapp-progress");
    /* ★ V15.5 item 8：输入框左下角那颗转圈也挂在这一拍上。
     * ⚠️ 它不跟着上面的 `return` 走 —— 那条早退是"这一页没有进度条就不干"，
     *    而转圈和进度条是两个独立的存在（对话页两个都有，别的页可能只有一个）。 */
    var spins = document.querySelectorAll(".dsapp-hint-spin");
    if (!bars.length && !spins.length) return;
    /* ⚠️ 转圈的判据里多一个 `.dsapp-busy`（发送按钮上那颗）：点下去到服务端
     *    回话之间还没有 .dsapp-cursor/.dsapp-wait，但用户已经该看到反馈了。
     *    进度条**故意不跟着加** —— 它现在的行为是量过的，不动它。 */
    var busy = !!document.querySelector(
      ".dsapp-cursor, .dsapp-wait, .dsapp-run-chip, .dsapp-run-live");
    var busySpin = busy || !!document.querySelector(".dsapp-busy");
    var now = Date.now();
    if (busy) lastBusy = now;
    var on = busy || (now - lastBusy) < GRACE;
    /* ★★ V15.6 item 3：这颗转圈以前是**直接采样**的，没有宽限期 —— 而
     *    Shiny 换 DOM 的那一瞬间 `.dsapp-cursor` 会短暂缺席（与上面进度条
     *    遇到的是同一件事）。采到那一帧就把 is-on 摘掉、下一帧再挂上，而
     *    `display:none → inline-block` 会让 CSS 动画**从 0 度重来**。
     *    用户看到的正是「正在返回信息的小框频繁地闪」。
     *    进度条那条宽限期是 V15.4 加的，这颗当时漏了，补上。 */
    if (busySpin) lastSpin = now;
    var spinOn = busySpin || (now - lastSpin) < GRACE;
    for (var i = 0; i < bars.length; i++) {
      bars[i].classList.toggle("is-on", on);
    }
    for (var j = 0; j < spins.length; j++) {
      spins[j].classList.toggle("is-on", spinOn);
    }
  }

  /* 采样要防抖：一次 flush 里 Shiny 可能连着改几十处 DOM，
   * 每次都去 querySelector 是白烧的。 */
  var timer = null;
  function schedule() {
    if (timer) return;
    timer = setTimeout(function () { timer = null; tick(); }, 120);
  }

  $(document).on("shiny:connected shiny:idle", schedule);
  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", schedule);
  } else {
    schedule();
  }
  /* 兜底：一直忙、但一直没有新 DOM 变化的时候（比如模型在闷头思考），
   * 上面那条路一次都不会触发，进度条会自己收掉。每秒补一次采样。 */
  setInterval(tick, 1000);
})();

/* ---- 活人感提示词轮换（★ V15.4 item 3）-----------------------------------
 *
 * 用户原话：「在思考的时候加个转圈的图案，提示用户"模型正在思考"？或者加
 * 一些有活人感的提示词，例如："院士别催了，我正在全力思考"、"冒了烟"的
 * 思考中；你可以再想十个不重复的，随机使用」。
 *
 * ★ 为什么轮换必须在前端做：
 *   那行字长在 output$wait_box 里，而那一格的重画理由被刻意收窄到三个粗
 *   粒度信号（新一轮 / 开始 / 结束）—— 目的就是让里面那颗转圈不被每 200ms
 *   拆掉重建。轮换要是走服务端，就得给那一格加一个每秒一跳的定时器，
 *   等于把刚掐掉的"闪屏"原样装回来。
 *
 * ★ 服务的只画一次：把 12 句用 U+001F 拼成一个字符串写在空 span 的
 *   `data-quips` 属性上（拼法见 R/utils.R 的 DSAPP_THINK_QUIPS）。
 *   这里读属性、切数组、定时换 textContent。
 *
 * ⚠️ 用 textContent，不用 innerHTML —— 提示词是我们自己写的，但这个节点的
 *    每一处变化都该是"换一句话"，不是"允许一段 HTML"。
 * ⚠️ 每一拍都重新 querySelector，不缓存节点：服务端重画那一格时旧节点会被
 *    丢掉，缓存下来的引用指向一棵已经不在页面上的树，写进去没人看得见
 *    （不报错，就是不动）。
 * ⚠️ 索引记在**模块级**，不跟着节点走。否则每次服务端重画都会从第一句重新
 *    开始 —— 用户会觉得"怎么老是这一句"。
 */
(function () {
  /* ⚠️ 写成 String.fromCharCode(31)，别在这里直接嵌那个控制字符：
   *    它在编辑器、diff、复制粘贴里都看不出来，谁一格式化就被吃掉。
   *    服务端那一侧同理，用的是 R 的 "\u001f"（见 R/utils.R）。
   *    U+001F（Unit Separator）是 ASCII 里为"分隔字段"留的码位，
   *    提示词正文里不可能出现它。 */
  var SEP = String.fromCharCode(31);
  /* ★★ V15.6 item 2：换句的节拍从**纯墙钟**改成**跟着新内容走**。
   *   用户原话：「活人感的提示词刷新的太快了，有新结果出现的时候间隔着
   *   刷新即可」。
   *   改之前这里只有 EVERY = 3200 一条判据：时间一到就换下一句。模型一个字
   *   都没吐的那几十秒（长思考、工具在跑）它照换不误 —— 用户看到的是"话一直
   *   在跳"，而那段时间其实什么新东西都没有。
   *   现在两道闸：①离上一句至少 EVERY；②这一段时间里**确实有新内容**。
   *   ⚠️ EVERY 同时要**大于**一段思维链的典型到达间隔，否则闸②形同虚设。 */
  var EVERY = 6500;              /* 两句之间至少停这么久（毫秒）*/
  /* 一直没有新内容时也别让同一句挂太久 —— 长工具调用可以安静几十秒，
   * 一动不动的小框看起来像页面死了。这一条只兜底，不是主节拍。 */
  var STALE = 20000;
  var TICK  = 400;               /* 扫描间隔：要能接住服务端刚画出来的新节点 */
  var idx = 0;                   /* 模块级：重画不重置 */
  var shownAt = 0;
  var fresh = false;             /* 上一句贴出去之后，有没有新内容进来 */

  /* ★ "有新内容"这件事由 dsapp:think 处理器广播（它每贴出一段思维链就发一次，
   *   见上面那个 handler）。用事件而不是在这里自己轮询 DOM：正文一开始，
   *   思维链那个节点就被拆掉了，而"新内容"不该由这个轮换器自己定义一份。
   * ⚠️ 这里**只置标志位**，换句仍然归 pick() —— 一拍里可能连着来了好几段，
   *    在这里直接换句会一次跳过去好几句。 */
  document.addEventListener("dsapp:activity", function () { fresh = true; });

  function pick() {
    var box = document.querySelector(".dsapp-wait-box [data-quips]");
    if (!box) return;
    var raw = box.getAttribute("data-quips") || "";
    if (!raw) return;
    var list = raw.split(SEP);
    if (list.length < 2) { box.textContent = list[0] || ""; return; }

    var now = Date.now();
    /* 节点是刚画出来的（上一拍还没有）：接着刚才那句往下走，别跳回第一句。
     * 判据用 textContent 是否为空 —— 服务端画出来的永远是空 span。
     * ⚠️ 刚贴出去的那一句算"已经看过了"，fresh 一并清掉：否则节点重建的那一
     *    拍会把上一轮攒下的 fresh 用掉，紧接着又换一句（连着跳两下）。 */
    if (!box.textContent) {
      shownAt = now;
      fresh = false;
      box.textContent = list[idx % list.length];
      return;
    }
    /* ★ V15.6 item 2 的两道闸：没到间隔不换；这段时间没有新内容也不换
     *   （除非同一句已经挂了 STALE 那么久）。 */
    if ((now - shownAt) < EVERY) return;
    if (!fresh && (now - shownAt) < STALE) return;
    idx = (idx + 1) % list.length;
    shownAt = now;
    fresh = false;
    box.textContent = list[idx];
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", function () { setInterval(pick, TICK); });
  } else {
    setInterval(pick, TICK);
  }
})();

/* ---- 秒数自己走字（V13.12 item 20）-------------------------------------- */

/* 用户原话：「分析进行时页面还是会刷新，取消这个机制，实时更新蹦出新结果
 * 就好」。
 *
 * 「这个机制」指的是服务端**按定时器**把同一格反复重画。实测跑一轮，光
 * 「已用 N 秒」那一格就被重画 145 次，其中 95 次画出来的 HTML **一个字
 * 都没变**（66%）。那 95 次不带来任何新信息，只是把 DOM 换一遍。
 *
 * 现在服务端只在**真的有新内容**时才重画（字符数变了、日志多了几行、
 * 状态变了），秒数交给这里自己走 —— 纯前端，一次网络往返都不花。
 */

/* ⚠️ 格式必须和 R/health.R 的 dsapp_fmt_duration() **逐字一致**。
 *    服务端画第一帧、这里接着往下走；两边格式不一样的话，用户会看到
 *    文字在「45 秒」和「0.8 分钟」之间来回跳。改一边就得改另一边。 */
function dsappFmtDuration(sec) {
  if (!isFinite(sec) || sec < 0) sec = 0;
  if (sec < 60) return Math.round(sec) + " 秒";
  if (sec < 3600) return Math.round(sec / 60) + " 分钟";
  if (sec < 86400) return (sec / 3600).toFixed(1) + " 小时";
  var d = Math.floor(sec / 86400), h = Math.floor((sec % 86400) / 3600);
  return h > 0 ? d + " 天 " + h + " 小时" : d + " 天";
}

/* ⚠️ 不能用服务端的绝对时间戳算"现在几秒"。服务端和浏览器的钟不一定对得上
 *    （差几分钟都常见），那样秒数会当场跳一下。所以只认**服务端画这一格时
 *    写的秒数**（data-secs），再叠上"本地从看见它到现在过了多久"：
 *
 *        data-secs + (performance.now() - 第一次看见它的时刻) / 1000
 *
 *    Shiny 每次重画都会换掉这个元素，data-t0 跟着没了 —— 正好，等于每来一次
 *    真消息就用服务端的数字重新对一次表。
 *
 * data-fmt 只有两种，都是**有调用方**的（多一种就得在这里加一档）：
 *    secs —— 对话页那个 token 框：「 · 已用 95 秒」（分钟级也说秒，看生成
 *            耗时的人要的就是秒）
 *    dur  —— 实时任务卡片：「 · 已跑 3 分钟」（那是分钟级的事，用秒读着累）
 */
function dsappElapsedTick() {
  var els = document.querySelectorAll(".dsapp-elapsed[data-secs]");
  for (var i = 0; i < els.length; i++) {
    var el = els[i];
    var base = parseFloat(el.getAttribute("data-secs"));
    if (!isFinite(base)) continue;
    var t0 = parseFloat(el.getAttribute("data-t0"));
    if (!isFinite(t0)) { t0 = performance.now(); el.setAttribute("data-t0", String(t0)); }
    var s = base + (performance.now() - t0) / 1000;
    if (s < 0) s = 0;
    el.textContent = el.getAttribute("data-fmt") === "dur"
      ? " · 已跑 " + dsappFmtDuration(s)
      : " · 已用 " + Math.floor(s) + " 秒";
  }
}
setInterval(dsappElapsedTick, 1000);

/* ---- 预览图片：加载中转圈 + 失败自己重试（★★ V15.6 item 15）---------------
 *
 * 用户原话：「预览区的图片又裂了，然后等一会又出现了，如果是因为未加载，
 * 可以在加载的时候转圈」。
 *
 * 「先裂、等一会又好了」在这条路上有两个都已坐实的成因：
 *
 *   ① **读到一个正在写的文件**。图片是从工作区/文件区现读现发的（服务端
 *      readBin 整份读，见 R/files.R 的 dsapp_preview_url），而产物是实时
 *      进列表的（跑着的任务也会列出来，3 秒一轮）。file.info 拿到大小之后、
 *      readBin 读之前，写脚本可能又写进去一截/整个重写 —— 读到的是半个
 *      PNG，浏览器解码失败 = 碎图。下一轮重画时文件已经写完，图就出来了。
 *   ② **完全没有兜底**：读到 0 字节或者 404/500 时，<img> 只会渲染成一个
 *      十几像素高的碎图，界面上不报错、也不会自愈。用户唯一的办法是再点
 *      一次 —— 这正是"时灵时不灵"的由来。
 *
 * 所以这里做两件事，都不需要用户动手：
 *   · 加载期间在那个位置摆一颗转圈（**加载慢是有原因的**：单进程 Shiny +
 *     20MB 闸门 + 同步整份读，图片请求要排在别人后面）；
 *   · 失败**自己重试**三次（带 cache-buster，每次间隔拉长），重试还不成才
 *     显示一句人话。成因①靠这个自愈 —— 文件写完的那一次就成了。
 *
 * ⚠️ img 的 load/error **不冒泡**，只能挂**捕获阶段**（第三个参数 true）；
 *    挂冒泡的话一个事件都收不到，而且不报错 —— 整块功能静默失效。
 * ⚠️ 转圈是**真节点**（Bootstrap 的 spinner-border，本仓已有的那套），
 *    不是 CSS 背景图：背景图转不起来（<img> 是替换元素，::before/::after
 *    不生成），而且这样能直接复用 @keyframes dsapp-spin。 */
(function () {
  var RETRY_MAX = 3;              /* 最多自己重试几次 */
  var RETRY_BASE = 1200;          /* 第一次重试等这么久，之后逐次加倍 */

  /* 哪些图算"预览图"。三类：
   *   ① 文件页那条路自己画的（.dsapp-img）；
   *   ② 对话页/缩略图那两条（外面有 .dsapp-preview-img / .dsapp-thumb-img
   *      容器，里面那颗 <img> 是 Shiny 的 imageOutput 生成的，加不上类）；
   *   ③ ★ V15.6 item 15：**markdown 正文里的图**（外面是 .dsapp-preview-md）
   *      —— 报告里插图走的就是这一条（`dsapp_md_inline_images()` 换进去的
   *      src），而"预览区"三个字用户指的主要就是它。漏了它的话，报告图裂了
   *      照样没人管：没转圈、不重试、就那么空着。
   * 论坛正文也带 .dsapp-preview-md（见 mod_forum.R），一并覆盖，无害。 */
  function isPreview(img) {
    if (!img || img.tagName !== "IMG") return false;
    if (img.classList.contains("dsapp-img")) return true;
    return !!(img.closest &&
              img.closest(".dsapp-preview-img, .dsapp-thumb-img, .dsapp-preview-md"));
  }

  function spinBox(img) {
    var s = img.nextSibling;
    if (s && s.nodeType === 1 && s.classList &&
        s.classList.contains("dsapp-img-spin")) return s;
    s = document.createElement("span");
    s.className = "spinner-border spinner-border-sm dsapp-img-spin";
    s.setAttribute("role", "status");
    s.setAttribute("aria-label", "图片加载中");
    /* ⚠️ 插在图片**后面**（不是前面）：插前面会把同一行里后面的元素
     *    往右推一格，图片一加载完抽掉又推回来 —— 那正是"闪"。 */
    img.parentNode.insertBefore(s, img.nextSibling);
    return s;
  }

  function spinOff(img) {
    var s = img.nextSibling;
    if (s && s.nodeType === 1 && s.classList &&
        s.classList.contains("dsapp-img-spin")) s.parentNode.removeChild(s);
  }

  function mark(img) {
    if (img.dataset.dsappImgState === "loading") return;
    img.dataset.dsappImgState = "loading";
    img.classList.add("is-loading");
    img.classList.remove("is-broken");
    spinBox(img);
    /* 已经加载完的（缓存命中，或者我们标记得太晚）当场收掉 ——
     * 否则那颗转圈会一直挂在一张好好的图旁边。 */
    if (img.complete && img.naturalWidth > 0) done(img);
  }

  function done(img) {
    img.dataset.dsappImgState = "ok";
    img.classList.remove("is-loading");
    img.classList.remove("is-broken");
    spinOff(img);
  }

  function failed(img) {
    var n = parseInt(img.dataset.dsappImgRetry || "0", 10);
    if (!(n >= 0)) n = 0;
    if (n < RETRY_MAX) {
      img.dataset.dsappImgRetry = String(n + 1);
      /* 重试时等一会：成因①是"文件还在写"，立刻重试多半还是半个文件。 */
      setTimeout(function () {
        var u = img.getAttribute("src") || "";
        if (!u) return;
        u = u.replace(/([?&])_r=\d+/, "$1").replace(/[?&]$/, "");
        img.setAttribute("src", u + (u.indexOf("?") >= 0 ? "&" : "?") +
                          "_r=" + Date.now());
      }, RETRY_BASE * (n + 1));
      return;
    }
    /* 三次都没成：说人话，并且**别再转**了。 */
    img.dataset.dsappImgState = "broken";
    img.classList.remove("is-loading");
    img.classList.add("is-broken");
    spinOff(img);
  }

  document.addEventListener("load", function (e) {
    if (isPreview(e.target)) done(e.target);
  }, true);

  document.addEventListener("error", function (e) {
    if (isPreview(e.target)) failed(e.target);
  }, true);

  /* 新插进来的预览图：先摆上转圈。
   * ⚠️ MutationObserver 的回调是微任务，排在 img 的 load 事件（宏任务）
   *    前面，所以正常情况下"先标记、后加载完"的顺序是稳的；缓存命中的
   *    那种极端情况由 mark() 里的 complete 检查兜住。 */
  function scan(root) {
    if (!root || root.nodeType !== 1) return;
    if (isPreview(root)) mark(root);
    var imgs = root.querySelectorAll ? root.querySelectorAll("img") : [];
    for (var i = 0; i < imgs.length; i++) if (isPreview(imgs[i])) mark(imgs[i]);
  }
  var mo = new MutationObserver(function (muts) {
    for (var i = 0; i < muts.length; i++) {
      var added = muts[i].addedNodes;
      for (var j = 0; j < added.length; j++) scan(added[j]);
    }
  });
  function observeAll() {
    mo.observe(document.body, { childList: true, subtree: true });
    scan(document.body);
  }
  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", observeAll);
  } else {
    observeAll();
  }
})();
