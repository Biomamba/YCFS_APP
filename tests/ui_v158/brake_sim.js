// 对照组：拿**两版 app.js 里真实的刹车代码**（不是重写一遍），喂同一个假时钟，
// 看"每 N 秒重载一次、每次都断"这种链路下，刹车到底踩不踩得下去。
//
// 为什么要有这一份：浏览器探针（probe_heal_brake.py）必须把 4 轮压缩到几分钟，
// 而**压缩过的节奏下，V15.11 那版也会踩刹车**（3 分钟窗口装得下 3 次）——
// 于是那个探针**分不出新旧**，证明不了这次修的是什么。分开量的是节奏：
// 线上是 120 秒一次，这一份就是量 120 秒。
//
// 用法（在仓库根目录）：  node tests/ui_v158/brake_sim.js
// ⚠️ 它读的是 `history_Version/Test_V15.11_20261003/www/app.js` 这个**归档快照**
//    作为"旧版"。要是把那一版挪走/重命名了，这里会**直接抛错**（extract 找不到
//    那一段就 throw）—— 那是有意的：静默地拿两个一样的文件对照，量出来的
//    "没差别"看着完全合理，但什么都没证明。
var fs = require('fs');
var path = require('path');
var ROOT = path.resolve(__dirname, '..', '..');

function read(rel) { return fs.readFileSync(path.join(ROOT, rel), 'utf8'); }

function extract(rel) {
  var s = read(rel);
  var i = s.indexOf('var DSAPP_HEAL_GRACE_MS');
  var j = s.indexOf('function dsappHealCancel');
  if (i < 0 || j < 0) throw new Error('在 ' + rel + ' 里找不到刹车那一段');
  return s.slice(i, j);
}

function run(path, cadenceMs, rounds) {
  var store = {};
  var sandbox = {
    Date: { now: function () { return sandbox.__now; } },
    sessionStorage: {
      getItem: function (k) { return (k in store) ? store[k] : null; },
      setItem: function (k, v) { store[k] = String(v); },
      removeItem: function (k) { delete store[k]; }
    },
    console: console
  };
  sandbox.__now = 0;
  var body = extract(path);
  var f = new Function('Date', 'sessionStorage', 'console', '__nowBox',
    body + '\nreturn {count: dsappHealCount, strike: dsappHealStrike, ' +
           'max: DSAPP_HEAL_MAX, win: (typeof DSAPP_HEAL_WINDOW_MS==="undefined"?null:DSAPP_HEAL_WINDOW_MS)};');
  var box = { v: 0 };
  var api = f({ now: function () { return box.v; } }, sandbox.sessionStorage, console, box);
  var reloads = 0, braked = null, counts = [];
  for (var r = 1; r <= rounds; r++) {
    var c = api.count();
    counts.push(c);
    if (c >= api.max) { braked = r; break; }
    api.strike(); reloads++;
    box.v += cadenceMs;
  }
  return { reloads: reloads, braked: braked, counts: counts, win: api.win, max: api.max };
}

var OLD = 'history_Version/Test_V15.11_20261003/www/app.js';
var NEW = 'www/app.js';
function line(tag, path, cadence, rounds) {
  var r = run(path, cadence, rounds);
  console.log("  " + tag + "  每轮开刷前的计数=[" + r.counts.join(",") + "]" +
              "  自动重载 " + r.reloads + " 次" +
              "  刹车=" + (r.braked === null ? "** 从没踩下去 **" : ("第 " + r.braked + " 轮停手")));
}
console.log('== 线上真实节奏：每 120 秒整页重载一次，连续 8 轮 ==');
line('V15.11（旧）', OLD, 120000, 8);
line('V15.12（新）', NEW, 120000, 8);
console.log('\n== 探针用的压缩节奏（20 秒一次，连续 8 轮）==');
line('V15.11（旧）', OLD, 20000, 8);
line('V15.12（新）', NEW, 20000, 8);
console.log('\n旧版窗口 ' + (run(OLD, 120000, 2).win / 1000) + ' 秒 / 上限 ' +
            run(OLD, 120000, 2).max + ' 次 —— 窗口里最多装得下 ' +
            Math.floor(run(OLD, 120000, 2).win / 120000 + 1) + ' 笔，够不到上限。');
