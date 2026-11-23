# 完整性、时序与漂移检测面：逐行还原与手段评估

分析对象：`/tmp/stripe-out-4.5.45/beautified.js`（6158 行，out-4.5.45）及其模块拆分 `/tmp/stripe-re-20261122/modules-pretty/mod-NN.js`。
辅助：`/tmp/stripe-js-dl/v3_plain.js`（1.2 MB 单行）、`/tmp/stripe-ctrl-dl/shared.js`（901 KB 单行）、`/tmp/stripe-re-20261122/inner.html`、`/tmp/stripe-recon/*.json`、`/Applications/AnyBrowser.app/.../Chromium Framework`。
安全：全部只做文本/字节读取，未执行任何节点脚本。

所有「推断」均显式标注；其余结论都有 文件:行 或 二进制 offset 或抓包 JSON 路径。

---

## 0. 结论摘要

1. **本采集器没有任何主动反篡改**。`Proxy`/`Reflect`/`Object.getOwnPropertyDescriptor`/`debugger`/`Function.prototype.toString`/`native code`/`webdriver`/`cdc_`/`domAutomation`/`MutationObserver`/`chrome.runtime`/`document.all`/`caller` 在 6158 行里**全部 0 命中**（§11 有逐项计数）。它不验证函数是否被 hook，不验证属性描述符，不扫 `window` 的 keys，不做 debugger 计时。
2. 但它**被动上传两个极细的 JS 注入探针**：`Object.keys(document)` 与 `Object.keys(navigator)`（beautified.js:1274-1275），且 `b.n`（模块求值瞬间的 `performance.now()`）与全部 15 项 `calculationTimeMs` 一起上行。任何可枚举自有属性、任何 hook 开销、任何抛错栈都会现形。
3. 因此项目文档里「零 JS 注入 / 禁止扩展注入」的写法（docs/stripe-fingerprint-mock-plan.md:417、:733）**已经落后于当前代码**：现在无条件装入一个 MAIN world、all_frames、document_start 的扩展（`Sources/AnyBrowserCore/IdentityShim.swift`，由 `BrowserRuntime.swift:282-283、537-539` 强制挂载），另外默认还装 PasskeyBox（`dist/.../PasskeyBox/manifest.json:24-45`，同样是 MAIN world + all_frames + document_start）。
4. 就本采集器而言，这两个注入**都不在它读的值里留下痕迹**（不动 navigator 键、不建带 id/name 的节点），但会改变 `t/at/b.n` 的分布，并把非原生 getter 暴露给会做 toString 检查的第三方脚本。结论要从「零注入」修正为「零**指纹值**注入 + 两个受审计的常驻注入」。
5. 对「新设备」最致命的是 `id`：它是 15 项 value 以空格连接的 **无盐 md5**（beautified.js:1322-1327），是跨 Profile、跨会话、跨 cookie 的设备类标识。所有 Profile 共用 host 字体位串、同一屏幕、同一 UA 时，新 Profile 的 `id` 完全相同——服务端一眼归并。
6. 身份铸造链是独立的第二条链：`m.stripe.com` 的响应体就是 `{"muid":"…","guid":"…","sid":"…"}`，由 inner 帧正则校验后用 `postMessage(…, "*")` 回传上层，上层只把 **42 字符**值写成 1 年期 `__stripe_mid` / 30 分钟 `__stripe_sid` cookie（§7）。「新设备」必须同时换指纹和 cookie jar。

---

## 1. 证据基线与计时基础设施

### 1.1 `now()` 与 `timer()`

`mod-00.js:29-40`（beautified.js:102-114）：

```js
function c(){ var e=m("win").performance; return e&&e.now?e.now():Date.now() }   // now
function u(e){ var t=m("now")(); return { result:e(), duration:m("now")()-t } }  // timer
```

- `now` 每次调用都重新读取 `win.performance`。页面若替换 `performance.now`，采集器直接采信——这是页面注入能无声控制计时的入口，也是内核/扩展 hook 会让计时漂移的原因。
- `timer` 只包住 **同步调用**：`e()` 返回 promise 后立刻取 `duration`，异步段不在 `duration` 里。

### 1.2 `Extractor.extract(withTelemetry)` 逐行

`mod-02.js:27-56`（beautified.js:548-581）：

```js
value: function(e){                       // e = withTelemetry
  if(e){
    var t = h("timer")(this.extractor),   // 同步跑 extractor
        n = t.result,                     // promise
        r = t.duration,                   // 同步段耗时
        o = h("now")();                   // promise 创建后的 t0
    return n.then(function(e){
      var t = h("now")(),                 // 解析瞬间 t1
          n = e.async ? t - o : 0,        // 只有解析值带 async:true 才计墙钟
          i = +(r + n).toPrecision(5);    // calculationTimeMs = 同步 + (async ? 墙钟 : 0)
      return "object"!==_(e)
        ? { value:e, internalValue:e, calculationTimeMs:i }
        : { value:e.value,
            internalValue:e.internalValue||e.value,
            activeTimeMs: e.calculationTimeMs ? +e.calculationTimeMs.toPrecision(5) : null,
            calculationTimeMs:i }
    })
  }
  return this.extractor().then(function(e){ return { value:e } })  // 无遥测：只有 value
}
```

要点：

- 计时单位是 `performance.now()` 毫秒，`toPrecision(5)` → **5 位有效数字的浮点数**，不是整数。
- `activeTimeMs`（上行字段 `at`）只来自 extractor 自己返回的 `calculationTimeMs`，且必须为**真值**；0 或缺失 → `null` → 序列化时被丢弃。
- 分支一（返回字符串）：`value === internalValue === 结果`，没有 `at`。15 项里 12 项是这一形态。
- 分支二（返回对象）：只有 `j` Fonts 与 `n` HasAdBlocker 会带 `{async:true, calculationTimeMs}`（`mod-18.js:131-135,158-163`；`mod-28.js:20-38`）。`o` Canvas 返回对象但**不带** `calculationTimeMs`（`mod-08.js:24-27`），所以 `a.o` 有 `t` 无 `at`。
- 无遥测分支（`withTelemetry=false`）**完全没有计时**，只有 `{value}`。入口 `extract` 在这个版本是空桩 `function L(e){}`（beautified.js:1297），所以实际只有有遥测的 `p` 路径被使用。

### 1.3 运行方式与并发形状

`promiseWrappedExtractors` 是朴素的 `map`（`mod-05.js:2-6`），15 个 extractor 在 `S` 里被**按固定顺序同步全部启动**（`mod-06.js:175-198`，beautified.js:1371-1401）：

```js
_ = now();                                        // t 的起点
o = promiseWrappedExtractors(t, function(e,t){
  var n=e.value, r=e.calculationTimeMs, _=(e.internalValue,e.activeTimeMs);
  B("CanvasExtractor");                           // 只引用，不调用
  var o=[n,r]; return _ && o.push(_), o;
});
return MPromise.all(o).then(function(o){
  var i = +(now()-_).toPrecision(5);              // 顶层 t = 全部启动到全部解析
  ...
})
```

- 因此 15 项的同步开销是**串行累加**进顶层 `t` 的；异步尾（Fonts 的 50 ms 分片、AdBlock 的 20 ms）是并行等待。
- `internalValue` 在 `S` 的映射里被逗号表达式丢弃（`(e.internalValue, e.activeTimeMs)`），永不上行。
- `CanvasExtractor` 只在 `S` 里被 `B("CanvasExtractor")` 取了一下引用，`canvasB64` 的 `n` 从未赋值 → 顶层 `i` 字段**恒为 undefined，JSON 里没有这个键**。

### 1.4 `b.n`（loadedTime）

`mod-06.js:50` = beautified.js:1222：`var v=B("now")();` —— 模块 6 求值时执行一次，之后恒定。它输出到 `b.n`（beautified.js:1276）。

- 它把「本帧加载到这个模块」的耗时写死进每条报文；同一帧内多次 ping 的 `b.n` 完全相同。
- 它包含该帧在 document_start 执行的所有扩展/注入脚本。真实抓包 `/tmp/stripe-recon/font-off.json` 里 `loadedTime: 42.69999998807907`；引擎探针 `/tmp/stripe-re-20261122/engine-probe/*.json` 落在 34.3–50.6 ms。数量级稳定，但注入变重会整体抬高。

---

## 2. 15 个 extractor 的返回形态（决定 `at` 与 `unavailable`）

| 字母 | 类 | 返回形态 | `async` | `at` | 可达 `unavailable` |
|---|---|---|---|---|---|
| a | CookieSupport `mod-16.js:15-17` | `cookieEnabled.toString()` 字符串 | 否 | 否 | 否（navigator 假则 `""`） |
| b | DoNotTrack `mod-17.js:15-27` | `"true"/"false"/""` | 否 | 否 | 否 |
| c | Language `mod-20.js:15-22` | join 字符串 | 否 | 否 | 否 |
| d | Platform `mod-21.js:15-17` | `navigator.platform` | 否 | 否 | 否 |
| e | Plugins `mod-22.js:17-28` | 拼接字符串 | 否 | 否 | 否 |
| f | ScreenSize `mod-23.js:15-23` | `availW+"w_"+availH+"h_"+colorDepth+"d_"+dpr+"r"` | 否 | 否 | 否（属性缺失拼出 `undefined`） |
| g | TimeZoneOffset `mod-24.js:15-21` | `(-date.getTimezoneOffset()/60).toString()`；`date` 是模块加载时的 `new Date`（`mod-01.js:27`） | 否 | 否 | 否 |
| h | TouchSupport `mod-25.js:15-21` | `"true"/"false/""` | 否 | 否 | 否 |
| i | AvailableStorage `mod-12.js:15-28` | `"<name>-enabled" / "<name>-unavailable" / "<name>-disabled"` 逗号连接 | 否 | 否 | 是（第三种字符串，非哨兵） |
| j | Fonts `mod-18.js:112-165` | 55 位 `"0"/"1"` 串 | **是** | **是** | **是**（`mod-18.js:113`、`:141`） |
| k | GraphicsConfiguration `mod-19.js:14-16` | 恒 `""` | 否 | 否 | 否 |
| l | UserAgent `mod-26.js:15-17` | `navigator.userAgent` | 否 | 否 | 否 |
| m | FlashVersion `mod-27.js:15-32` | 恒 `""`；`mimeTypes` 缺失 → `"mime-types-unavailable"` | 否 | 否 | 第三种字符串 |
| n | HasAdBlocker `mod-28.js:15-43` | `"true"/"false"` | **是** | **是** | 否 |
| o | CanvasId `mod-08.js:17-33` | 32 hex md5 | 否 | **否** | **是**（`mod-08.js:28-30`） |

`at` 只可能出现在 `a.j` 与 `a.n`（beautified.js:1385 的 push 条件）。`o` 的对象**没有** `calculationTimeMs`，所以 `a.o` 的 `at` 永远缺省。

---

## 3. `unavailable` 的精确写入条件

### 3.1 Canvas（`mod-08.js:17-33`，beautified.js:1780-1802）

```js
var e = b("doc").createElement("canvas");
try{
  e.height=60; e.width=400; e.style.display="inline";
  var t=e.getContext("2d");
  t.textBaseline="alphabetic"; t.fillStyle="#f60"; t.fillRect(125,1,62,20);
  t.fillStyle="#069"; t.font="11pt Arial";
  t.fillText("Cwm fjordbank glyphs vext quiz, 😃",2,15);
  t.fillStyle="rgba(102, 204, 0, 0.7)"; t.font="18pt Arial";
  t.fillText("Cwm fjordbank glyphs vext quiz, 😃",4,45);
  var n=e.toDataURL();
  return MPromise.resolve({ value: md5(n), internalValue: n })
} catch(e){ return MPromise.resolve("unavailable") }
finally{ e && e.parentNode && e.parentNode.removeChild(e) }
```

任何一步抛错（`getContext` 返回 null 后取属性、`toDataURL` 被限制、字体/画布实现异常）→ **字符串 `"unavailable"`**，`at` 不存在。绘制尺寸 400×60，最终 `toDataURL` 的 PNG 长度与真实 Chrome 同尺寸不同（真实抓包 `/tmp/stripe-recon/font-off.json` 的 `canvas.len = 21050`，只是参考量）。

### 3.2 Fonts（`mod-18.js:112-165`）

- `ctx` 缺失：`return O("ctx") ? new MPromise(calculateFonts) : MPromise.resolve("unavailable")`（`:112-114`）。`ctx` 来自 `mod-01.js:30-33` 在模块加载时 `document.createElement("canvas").getContext("2d")` 的共享上下文；取不到就是永久 `unavailable`。
- 任一 base font 的 `measureText` 抛错：`safeMeasureText`（`mod-18.js:117-125`）返回 `"UNAVAILABLE_WIDTH"`，外层 `:139-143` 立刻 `e({async:true, value:"unavailable", calculationTimeMs: now()-n})` → **对象 + 真值 at**。

### 3.3 错误通道的 `id:"unavailable"`

见 §4：它与上面两个哨兵不在同一层（顶层 `id`），但会造出常量 `id` 的报文。

### 3.4 其他近似串

- `"sessionStorage-unavailable"` / `"localStorage-unavailable"`：`win[t]` 为假（属性被删/替换），`mod-12.js:23`。`setItem` 抛错则是 `"-disabled"`。
- `"mime-types-unavailable"`：`navigator.mimeTypes` 为假，`mod-27.js:25`。

**真实 Chrome 几乎只会得到常规值**：`i` 两项 enabled、`j` 55 位、`o` 32 hex。哨兵出现即说明环境被动过或引擎/注入坏了。

---

## 4. 错误上报：字段、序列化与可达路径

### 4.1 构造（`mod-10.js:57-75`，beautified.js:2260-2272）

```js
l = function(e){
  return JSON && "function"==typeof JSON.stringify
    ? e ? I("safeBeacon")(JSON.stringify({
        id:"unavailable", e:e, message:e.message, error:e.toString(),
        fileName:e.fileName, lineNumber:e.lineNumber, columnNumber:e.columnNumber,
        stack:e.stack, tag:"$npm_package_version", src:"js"
      }))
      : I("safeBeacon")(JSON.stringify({ id:"unavailable", tag:"$npm_package_version", src:"js" }))
    : I("safeBeacon")(e.toString()),
  e
}
```

- `safeBeacon`（`:52-56`）= `beacon(btoa(encodeURIComponent(JSON.stringify(x))), version)`，`version` 缺省 `"6"` —— 错误报文**固定发往 `/6`**，与调用方的 `/4` 无关。
- `e` 是 Error 实例：`JSON.stringify(Error)` 在 V8 只序列化自有**可枚举**属性 → `{}`；`message/stack` 非枚举 → 只剩 `message`、`error`、`stack` 三个字符串字段。
- `fileName/lineNumber/columnNumber` 是 Mozilla 扩展，V8 的 Error 没有（**推断**，与本地 Chrome 行为一致）→ 三个键会被 `JSON.stringify` 丢弃；`stack` 是 Chrome 唯一带源码位置的字段。
- `stack` 会原样带出 `https://m.stripe.network/out-4.5.45.js:1:NNNN`；若异常发生在被注入的 getter 里，栈顶还会出现 `chrome-extension://<id>/…`。这就是注入实体在 Stripe 侧留下的**唯一自报身份**。

### 4.2 触发路径

- `p`/getDevice（`mod-10.js:80-104`）：`I("getDevice")(…).catch(I("beaconErrorHandler"))`，外层再 `try/catch` 同步抛错，同样落到 `beaconErrorHandler`（`:87-93`）。
- `b`/send（`mod-10.js:95-104`）：只有同步段 `try/catch`；`safeBeacon` 的 promise 拒绝**不会**转成错误报文。
- `beacon` 在 `t == null`、非 200、`win.StripeM` 缺失时 `r()` 拒绝（`mod-29.js:20-34`）。由于 `p` 对 beacon 挂了 `.catch(beaconErrorHandler)`，**m.stripe.com 一旦非 200，会紧跟一条最小 `{id:"unavailable",tag,src}` 报文**（`e` 为 undefined 分支）。
- 能导致 promise 拒绝的 extractor：只有 `j` Fonts（`calculateFonts` 同步抛错）与 `n`（executor 内抛错）。同步抛错（例如 `cookieEnabled` 为 null 时的 `.toString()`）会从 `timer(this.extractor)` 直接冒出 `extract`，`map` 不捕获 → `S` 同步抛 → `p` 的 `try` 捕获。

### 4.3 自相矛盾条件

- `id:"unavailable"` 报文的 `id` 是常量，**不含 md5**；若同一帧里绝大部分请求都是常规 `id`，偶尔一条 `unavailable`（尤其带 `chrome-extension://` 栈）是强信号。
- 若 `e` 为真值，字段里**有** `e/message/error/stack`；若为假值，只剩 3 个键。两者形状互斥。
- `version` 固定 6 而常规 ping 可能是 4：同一 renderer 里 `/4` 与 `/6` 交错本身正常（`b` 用调用方 version），但错误永远 `/6`。

---

## 5. sessionStorage `id` 与 md5 漂移比较

### 5.1 计算

`mod-06.js:137-141`（beautified.js:1322-1327）：

```js
c = _()(n, function(e){ return e[0] }).join(" "),   // 只取 15 个 value，空格连接
u = B("md5")(c)                                      // 32 hex，UTF-8（mod-07.js:65-75）
```

- 输入**只含 value**：不含 `t`、`at`、`internalValue`、URL、UA-CH、cookie。
- 空数组元素（`b.i`/`b.j`）以空串参与，连续空格也是输入的一部分。
- `md5` 是 blueimp 库（`mod-07.js`），UTF-8 编码后取 hex。

### 5.2 比较（beautified.js:1352-1353）

```js
O = 2===h || m.get("id") !== u;   // h = sourceData.v2
m.set("id", u)
```

- `MStorage` 默认 `sessionStorage`（`mod-00.js:42-48`）；构造时还会留下 `sessionStorage["1"]="1"`（`:46`）。
- `sessionStorage` 不可用 → `get` 返回 null、`set` 静默失败（`mod-00.js:59-64`）→ `null !== u` 永真 → **每次请求都发特征**，`a` 永不为 null。
- `v2===2` 时强制发特征（`vt()` 的 ping 带 `v2:2`，`v3_plain.js` 偏移 592588 处）。
- `v2` 来自 inner 收到的消息载荷或 hash 里的 `version=(4|6)`；`v2||1`（beautified.js:1355）把 undefined/0 变 1，但字符串 `"2"` 会原样上行且 `2===h` 为假。

### 5.3 自相矛盾条件

| 现象 | 含义 |
|---|---|
| 同一 tab 连续两条，`a` 非 null 且 `id` 相同 | sessionStorage 失效或 `set` 被拦 |
| 同一 tab 连续两条，`a` 为 null 但 `id` 变了 | 值在漂移但去重逻辑没跟上（伪造/缓存错位） |
| `a` 为 null 而 `a.j.at`/`a.n.at` ≈20 ms | `_mf`/`_ab` 应命中却重算了 |
| 每条都是 `a` 非 null 且 `a.n.at` ≈20 ms，但 `b.i` 说 `sessionStorage-enabled` | get/set 半可用（quota 或代理脚本） |
| 不同 Profile 首访 `id` 相同 | 见 §0.5，值是同一套 |

`_ab`（AdBlock，`mod-28.js:17,33`）与 `_mf`（Fonts，`mod-18.js:129,158`）同样在 sessionStorage；命中时 `at` 从 ≈20 ms 掉到 ≈0.0x，且 Fonts 缓存命中**不带** `internalValue`。

---

## 6. URL / title / referrer 的盐值分段哈希

### 6.1 固定盐与分区

`mod-04.js:62`（beautified.js:853）：`URL_SALT = "7766e861-8279-424d-87a1-07a6022fd8cd"` —— **全站固定、不含设备熵**。

`sha256WithSalt(e)`（`:63-65` / 853-856）：`sha256(unescape(encodeURIComponent(e)) + URL_SALT)`，输出是 **base64url**（`mod-09.js:55-57` 的 `a`），不是 hex。

`PartitionedUrl`（`:39-60` / 830-851）：regex 切出 scheme/authority(/去掉 userinfo)/path/query/fragment，`toString` 用 `filter(Boolean).join("")` 拼回。

`SequentialSplitterAndHasher`（`:66-95` / 858-907）+ 预算（`:103-139` 与常量 `:216-220`）：

- authority：`total = 40`，`full = 40` → 每个片段全哈希。
- path：`total = max(1, min(30, remaining))`。
- query/fragment：`total = max(1, remaining)`。
- `shouldPartialHash()`：`!isLastHash() && hashedCount >= 10` → 第 11 个起只保留 **6 字符**前缀；最后一个片段哈希**剩余整段**。
- 分隔符：authority 用 `[/.:]`；path/query/fragment 用 `[/#?!&+,=]`。

`hashUrlWithAuthorityCheck`（`:146-150` / 989-993）：

- authority 是 `checkout.stripe.com` / `qa-checkout.stripe.com` / `edge-checkout.stripe.com`（`:99-102`）→ 走 `hashUrl`，但 authority 片段**保留明文**（`:130-131`）。
- authority 是 `//stripe.com`、`//stripe.com.`、`*.stripe.com`、`*.stripe.com.`（`:96-98`）→ **整条 URL 原样明文**。
- 其他 → 按默认预算全哈希。

`getUrlDomain`（`:151-156` / 995-1001）：取 authority、去掉前导 `//`、在 `:port` 处截断。`b.u`/`b.v` 在哈希**之前**计算，所以域名与哈希同时存在（beautified.js:1341-1348）。

### 6.2 组装顺序（beautified.js:1335-1349）

`b.a..b.e` 先从 hash（非空时）或 search 里取 referrer/url/title/muid/sid；`a`→`u`, `b`→`v` 先算域名；然后 `a`、`b` 过 `hashUrlWithAuthorityCheck`，`c` 过 `sha256WithSalt`；`d`(muid)/`e`(sid) **保持明文**。

`queryStringValueForKey`（`mod-00.js:50-57`）：`slice(1).split("&").filter(x => x.indexOf(key+"=") !== -1)[0]`，再 `decodeURIComponent(split("=")[1]) || ""`。只看**第一个**匹配段，值在第二个 `=` 处截断，且 `key=` 是子串匹配。

### 6.3 自相矛盾条件

- URL 哈希是**确定性**的：同一 URL 在任何设备上哈希相同。它只做归一化，不是设备标识；`b.w` 才是每请求新鲜量。
- `b.u`/`b.v` 明文域名必须与 `b.a`/`b.b` 的 scheme/authority 部分来自同一 URL；对 `onboarding.stripe.com` 这类非 checkout 的 Stripe 主机，`b.b` 是哈希而 `b.u` 仍泄露域名——这是设计如此，不是矛盾。
- 若代理重写 URL 而页面 `location` 不变（或反之），`b.b` 与 `b.u` 会指向不同主机。
- 明文 `stripe.com` 主机：`b.b` 不带哈希，重写者若给它哈希就是矛盾。
- `b.a`/`b.b` 为空时是 `""`；`b.c` 为空时也是 `""`（`sha256WithSalt` 对 falsy 直接返回）——空串不是哈希。
- 分段预算让长 URL 的后段只剩 6 字符，同前缀不同尾段的 URL 可碰撞；服务端不会用哈希做唯一键。

---

## 7. iframe postMessage 校验与身份铸造链

### 7.1 inner 侧（`inner.html` 内联脚本）

```js
var e=document.createElement("script"); e.defer=!0; e.src="out-4.5.45.js";
e.onload=function(){
  window.StripeM && (e=location.hash, /ping=false/.test(e) || (
     e=(e=e.match(/version=(4|6)/))?e[1]:"4", StripeM.p({t:!0,v:e})));
  e=function(e){ if(window.opener||window.parent||window) try{
      var i=((t=JSON.parse(e.data)).message||t).action, t=t.message?t.message.payload:t;
      switch(i){
        case"ping": StripeM.p({t:!0,o:{muid:t.muid,sid:t.sid,referrer:t.referrer,url:t.url,title:t.title,v2:t.v2},v:t.version||"4"}); break;
        case"track": if(!t.source||!t.data)return; StripeM.b({muid:t.muid,sid:t.sid,url:t.url,source:t.source,data:t.data},t.version||"4")
      }
  }catch(e){}}, window.addEventListener("message",e,!1))
}
```

- 监听器**不做 origin 校验**；`window.opener||window.parent||window` 里第一个真值即可。
- 消息形状两种：`{message:{action,payload}}` 或扁平 `{action,payload}`；`version` 缺省 `"4"`。
- hash 里带 `ping=false` 时连首 ping 都跳过；`version=(4|6)` 决定 `/4` 或 `/6`。

### 7.2 inner → 上层（`mod-10.js:22-46`，beautified.js:2213-2242）

```js
var t = I("win").opener || I("win").parent || I("win");
if(t && I("isValidIframePostMessage")(e)) try{
  try{
    var n=JSON.parse(e), r=n.guid, _=n.muid, o=n.sid;
    t.postMessage(JSON.stringify({originatingScript:"m2", payload:{guid:r,muid:_,sid:o}}), "*")
  }catch(n){
    t.postMessage(JSON.stringify({originatingScript:"m", payload:e}), "*")
  }
}catch(e){}
```

`isValidIframePostMessage`（`mod-00.js:64-67`）：

```js
var s=/^{"muid":"[\w-]+","guid":"[\w-]+","sid":"[\w-]+"}$/m
l = e => "string"==typeof e && MSG_REGEX.test(e)
```

- 正则要求**恰好三个键、顺序固定、无空白、值只有 `[\w-]` 且非空**。多一个键或顺序不同就落到 `m` 分支（`m` 分支转发原始 `e`）。
- `targetOrigin` 是 `"*"`；接收方自己校验。
- `e` 就是 **beacon 的响应文本**：`getDevice` 的 send 回调是 `safeBeacon(e, mPostMessage, n)`（`mod-10.js:75-79`）→ `beacon(...).then(mPostMessage)`，XHR 200 时响应体原样传入。

### 7.3 上层来源校验与 ID 落盘（v3_plain.js，单行文件，用 byte offset）

- `_handleMessage`（偏移 587936-588760）：`if((0,E.qZ)(r) && "string"==typeof n)` → `JSON.parse` → 只接受 `originatingScript==="m2"` → 取 `{guid,muid,sid}` → `_guid=l`、`_muid=_getID("merchant",muid)`、`_sid=_getID("session",sid)` → `_onIdsUpdate` → resolve `_idsPromise`。
- `qZ(e)`（偏移 372373-372560）：`(0,a.vj)(e) || (!sameOrigin(e,"") && (sameOriginJs(e) || stripeHost(e) || linkHost(e)))`；`stripeHost` 只认 `stripe.com` / `*.stripe.(com|me|dev)`（偏移 372025-372100），`sameOriginJs` 只认 `https://js.stripe.com/v3/`（偏移 372219）。`a.vj` 读一个从未赋值的 `trusted_outer_origin`，恒 false。
- 所以实际能过校验的 origin 只有 `js.stripe.com`、`*.stripe.com`、`*.stripe.me/.dev`、`link.com` 族。**`m.stripe.network` 不在名单里** —— inner 的 parent 是放在 `js.stripe.com` 上的 m-outer 页，由它中转（**推断**：中转函数不在这两个已下载 bundle 里，m-outer 页的内联脚本未取到）。
- `pt(e)=42===e.length`（偏移 587697）；`_getID`（偏移 591827-592560）：cookie 不存在 → 用传入值；只用 42 字符值才写 cookie；`__stripe_mid`（`mt` 的 merchant 分支）默认过期 31536e6 ms（1 年），`__stripe_sid` 18e5 ms（30 分钟），`domain="."+location.hostname`、`SameSite=Strict`、https 加 `secure`（cookie 写入器 `ce`，偏移 569572-569750）。
- `_getID` 的随机源 `uR`（偏移 347158-347400）：`crypto.randomUUID()`（36 字符）或手写回退；配合 `pt` 的 42 长度说明**真正的 42 字符值来自服务端响应**，不是本地生成。
- 查询串的挂载方式确认了「hash 优先」的设计：`_createIFrame`（偏移 190979-191932）最后一行是 `c.src = frameURL + (s ? "#" : "") + s`，appParams 全部在 `#` 之后；`mod-06.js` 的 `browserFeatures` 因此先读 `location.hash`、空才退回 `location.search`（beautified.js:1264）。

### 7.4 协议闭环

- 首访 `muid/sid` 可能是 `"NA"`（`_getID` 的缺省），随 hash 进入 inner → `b.d="NA"`、`b.e="NA"`。
- m.stripe.com 的响应体恰好是 `{"muid":"…","guid":"…","sid":"…"}`（由 §7.2 的正则反推，**强推断**）；同一文本还写进 `StripeM.__sid`（`mod-29.js:31`，beautified.js:5628）。
- 上层收到后写 cookie 并把 ids 交给后续 `vt()` 的 ping；`vt()` 首次执行后置 `yt=true` 不再重发（`v3_plain.js` 偏移 592588-592700）。
- 因此会话内出现两套 `b.d`/`b.e`（先 NA 后有值）是**正常的**；`b.h` 每请求都变。

### 7.5 自相矛盾条件

- `b.d`/`b.e` 长度非 42 且非 `"NA"` → 上游塞了伪造值，cookie 不会落盘。
- `b.e`（sid）在 30 分钟内突变 → 不是同一个 sid 链。
- postMessage 用了 `"*"`，若被第三方 window 抢答，`origin` 校验会挡掉非 Stripe origin，但挡不住同 origin 的另一段脚本。
- 响应体只要一个字节不匹配正则（多键、顺序、空白），`m2` 就降级为 `m`，上层 `_handleMessage` **只认 m2** → guid/muid/sid 不更新 → cookie 不写。于是「有请求、有 200、但 ID 永远 NA」就是一条可直接识别链条断裂。
- `withCredentials=true`（`mod-29.js:24-27`）要求 CORS 允许凭据；剥掉 CORS 响应头 → 状态非 200 → §4.2 的错误哨兵。

---

## 8. 非提取类的结构字段

| 字段 | 代码 | 语义 | 矛盾判据 |
|---|---|---|---|
| `b.f` | `mod-06.js:60-67` | `new Audio` 后 `mozSrcObject===null && srcObject===undefined` | 引擎代际探针，148 恒 false |
| `b.g` | `:69-75` | `ArrayBuffer()` 无 new 是否抛错 | 148 恒 true |
| `b.h` | `:77-83` | `Array.from("hello")` 是否可用 | 恒 true |
| `b.i` | `:96` / beautified:1274 | `Object.keys(document)` | 真实 `["location"]`（`/tmp/stripe-re-20261122/chrome-baseline.json`、`engine-probe/*.json`）；多键 = 有命名 DOM 注入 |
| `b.j` | `:97` / beautified:1275 | `Object.keys(navigator)` | 真实 `[]`；非空 = 可枚举自有属性注入 |
| `b.n` | `:50,98` / beautified:1222,1276 | 模块求值时的 `performance.now()` | 同帧恒定；应低于同帧 `t` 的总量级 |
| `h`（顶层） | `mod-06.js:116-124`（beautified:1300-1309） | `crypto.getRandomValues(80/8=10 字节)` → 20 hex | 必须 20 位小写 hex；`Math.random().toString(16)` 回退会是变长且带 `0.` |
| `v2` | `mod-06.js:160` / beautified:1355 | `h||1` | 只应 1 或 2 |
| `src`/`tag` | `mod-06.js:163-164` / beautified:1358-1359 | 字面量 `"js"`、`"$npm_package_version"` | 常量，改动即伪造 |
| `i`（顶层） | `mod-06.js:165` / beautified:1360 | `canvasB64`，从未赋值 | JSON 中**不存在**该键 |
| `b.w` | `mod-06.js:126-129`（beautified:1312-1315） | `Date.now()+":"+sha256Hex(nonce+(Date.now()+1))` | 明文 ms + 64 hex；与 `h` 绑定 |

`b.w` 的两个 `Date.now()` 之间有 1 ms 的固定偏移；若系统时钟在两次调用间倒退或跳变，`w` 仍能自洽（hash 用的是第二次取值），只是 ms 跳跃。`sha256Hex`（`mod-09.js:58-66`）输出 64 位 hex。

`v2===2` 时 `a` 恒发；`v2===1` 时按 §5 去重。

---

## 9. 自相矛盾清单（按报文内 / 跨报文 / 环境）

**单报文内：**

1. `id` ≠ md5(`a.a..a.o` 的 `v` 空格连接) —— 服务端可无条件重算。
2. 顶层没有 `i` 键：`canvasB64` 从未赋值（§1.3）；抓包 `/tmp/stripe-recon/signup-capture.json` 未覆盖 fingerprint POST，判据来自代码，出现 `i` 即伪造。
3. `at` 出现在 `a.a`–`a.i`、`a.k`–`a.m`、`a.o` 上。
4. `a.n.at` 存在而 `a.n.v` 不是 `"true"/"false"`；或 `a.j.at` 存在而 `a.j.v` 不是 55 位 0/1。
5. `a.o.v` 非 32 hex。
6. `a.j.v.length !== 55`。
7. `id` 非 32 hex；`h` 非 20 hex；`v2` 非 1/2；`src`/`tag` 变形。
8. `b.j` 非空；`b.i` 出现 `location` 之外的键。
9. `b.d`/`b.e` 非 42 且非 `"NA"`。
10. `b.n`、`t`、`at` 不是 5 位有效数字浮点，或 `at > t`。
11. `b.u`/`b.v` 与 `b.a`/`b.b` 的主机层次不一致（尤其明文 stripe.com 主机却给了哈希）。
12. 顶层 `i` 出现值。

**跨报文：**

13. 同一 tab 连续两条，`id` 不变而 `a` 非 null（v2=1 时）。
14. 同一 tab 连续两条，`id` 变而 `a` 为 null。
15. `a` 为 null 而 `at` ≈20 ms（缓存应当命中）。
16. `h` 重复；`w` 不前进或与服务器时钟差过大。
17. 已发过 42 字符 `b.d` 后回落为 `"NA"`。
18. 前一条 `b.j=[]`、后一条多出键（或反之）。

**环境/跨源：**

19. `b.i` 说 `sessionStorage-enabled` 但 `id` 从不命中、`at` 从不降。
20. `b.i` 含 `-unavailable`（属性被删）而 `i` 两项仍 enabled。
21. `b.c`（title sha256）与外部导航路径不符：SPA 每 5 s 检查 `location.href` 变化并重 ping（`v3_plain.js` 偏移 588877-589000 的 `_startIntervalCheck`），title 会随路由变。
22. `b.n` 同帧恒定：如果重放器每次都换 `b.n`，就是合成报文。
23. `navigator.webdriver`：整个采集器不读，但 shared.js 偏移 473311 用一个 Safari-only 存储探测 `if(O&&P(t)&&!navigator.webdriver)` 门控，headless/自动化身份会影响这条路。
24. `maxTouchPoints` 被 v3/shared 的浏览器识别读取（v3 偏移 263221、shared 偏移 474628），与 `h` TouchSupport 成对外部一致性。

---

## 10. 三种手段分别踩中哪些面

| 面 | 内核级改写 | 页面注入（addScriptToEvaluateOnNewDocument / MAIN world 扩展） | 网络改写（代理/MITM 改 POST） |
|---|---|---|---|
| 15 个 value | 原生产出，`id` 自然正确 | 可改，但每次改动都要同步 `id`；hook 返回值类型错会抛错进栈 | 可改，但必须重算 `id`；页面内其它读者看不到 |
| `b.i`/`b.j` | **不产生键**（探针 `nkeys:[]`、`dkeys:["location"]` 在 `--fingerprint-platform=windows` 等全部设置下都不变） | 直接上报：`defineProperty(...,{enumerable:true})` 或赋值即写进 `b.j`；带 id/name 的 DOM 写进 `b.i` | 完全绕开：页面里真被注入的键在网线上看不见，网线改的键页面里看不见（两边若不同步就是矛盾） |
| `t`/`at`/`b.n` | 原生速度，分布真实 | hook 开销直接计入；`measureText`/`clientHeight` hook 会抬高 `a.j.t/at`、`a.n.t/at`；document_start 脚本抬高 `b.n` | 可改写，但必须保持「at 仅 j/n」「at ≤ t」「首访 ≈20 ms、缓存 ≈0」 |
| `unavailable` | 引擎 bug 才会出现 | hook 抛错即产生 `a.o.v`/`a.j.v` 的哨兵或顶层 `id:"unavailable"` | 可选择性改写，但要与 `at`/`id` 一致 |
| 错误栈 | 无 | `chrome-extension://<id>/…` 进 `stack` | 可重写 body 里的 `stack` 文本 |
| 身份链（muid/sid/`__sid`） | 不涉及；cookie 由 v3 自己写 | 不涉及（除非 hook `crypto.randomUUID` 等） | 必须透传响应体，否则正则不匹配 → m2 消失 → cookie 不写 |
| URL/标题哈希 | 不涉及 | 不涉及 | 只与明文 `u/v` 互证；盐固定可复算 |
| CORS/凭据 | 不涉及 | 不涉及 | 必须保留 `Access-Control-Allow-Origin` + `Allow-Credentials`，否则 200 变错误路径 |
| 版本演进 | 需跟引擎 | 需跟页面生命周期 | 需跟 payload 结构（无压缩，解码成本低但字段多） |

**代码事实支撑**：内核侧 `--fingerprint-*`/`--disable-spoofing` 的开关表在框架二进制 226227354 起（`…j7ffingerprinting-client-rects-noise.fingerprinting-canvas-measuretext-noise.fingerprinting-canvas-image-data-noise.fingerprint.fingerprint-brand.fingerprint-brand-version.disable-spoofing…`），`BROWSER_NATIVE_FINGERPRINTING` 在 232997031，`clientrects_noise_x` 在 233761441。

---

## 11. 「零 JS 注入」复核

### 11.1 采集器自身：零主动反篡改（命中计数）

对 `/tmp/stripe-out-4.5.45/beautified.js`（6158 行）逐 token `grep -o | wc -l`：

| token | 命中 | 说明 |
|---|---|---|
| `Proxy` | **0** | 不做 Proxy trap 检测 |
| `Reflect` | **0** | 无 Reflect |
| `Object.getOwnPropertyDescriptor` | **0** | 不查描述符 |
| `debugger` | **0** | 无断点计时 |
| `Function.prototype.toString` / `native code` | **0 / 0** | 不校验函数来源 |
| `webdriver` / `cdc_` / `domAutomation` / `_phantom` / `__driver` | **0** | 无自动化指纹 |
| `MutationObserver` | **0** | 无 DOM 变更监控 |
| `permissions` / `Notification` / `chrome.runtime` / `document.all` / `caller` / `arguments.callee` | **0** | 无扩展/权限探针 |
| `Object.prototype.toString` | 3 | 全是 Babel helper / process 探测（beautified.js:1203、3489、5887） |
| `toString` 总计 | 19 | 3 个 `Object.prototype`（1203、3489、5887）、1 个 `Symbol.toStringTag`（31）；其余是 `cookieEnabled.toString()`（3120）、`e.toString()`（2265、2270、4713、4882）、`r.toString()`（5429）、`(16)` 进制（1303、1308、2040）、URL 对象 `toString`（839、972、1347、1348、2311） |
| `Error` | 18 | 多为 `TypeError`/错误回调；仅 4 个 `new Error` 全在 timers/process shim（6011、6014、6142、6150），采集路径**不主动造栈** |
| `Symbol` | 132 | Babel/polyfill 基础设施 |

**结论**：采集器对「函数是不是原生」「有没有人改过 navigator」本身零检查。它的反篡改完全是被动的：值自洽性 + 服务端交叉判定 + `b.i`/`b.j`/计时/哨兵/栈。

### 11.2 外围 bundle 有极少量检查，但不在采集路径

- `webdriver` 全仓只有 **1 处**，`shared.js` 偏移 473311：`if(O&&P(t)&&!navigator.webdriver)` 门控 Safari 的 storage 探测；不进入 payload。
- `String(e).indexOf("[native code]")`：`v3_plain.js` 偏移 863086（浏览器特性探测）与 1206789（模块 67717）；`shared.js` 模块 99915。用于 `Promise`/`Promise.prototype.finally` 等 polyfill 判定，读的是全局构造函数，不是指纹属性。
- `Reflect`（v3 6 / shared 12）与 `getOwnPropertyDescriptor`（4 / 6）全部来自 Babel/TS 装饰器/`Object.assign` helper，不是检测。
- `maxTouchPoints`：v3 263221、shared 474628，仅用于 iPad/Safari 判定。
- `headless`、`__playwright`、`__puppeteer` 三个 bundle **全 0**。

旧文档 `docs/stripe-fingerprint-mock-plan.md:290` 说「完整 bundle 对 `navigator.webdriver`、`maxTouchPoints` 也是 0 命中」——对采集器成立，对 v3/shared **不成立**（各 1 处，但均为行为分支而非上报）。

### 11.3 代码事实：当前有两套常驻 MAIN world 注入

1. **IdentityShim**（`Sources/AnyBrowserCore/IdentityShim.swift`）
   - `isNeeded` 恒 true（`:23-25`），`BrowserRuntime.swift:282-283` 每次启动准备，`:537-538` 追加进 `--load-extension`。
   - manifest：`host_permissions:["<all_urls>"]`、`all_frames:true`、`match_about_blank:true`、`match_origin_as_fallback:true`、`run_at:"document_start"`、`world:"MAIN"`（`:64-71`）。
   - 脚本（`:84-165`）：document_start 里先做 `new OffscreenCanvas(1,1).getContext('2d')` + `probe.measureText` 探针（`:106-108`）；只在宽度 <1（引擎的 measureText 乘性 bug）时激活；`Reflect.apply`/`Object.getOwnPropertyDescriptor`/`Object.defineProperty` 全部在页面脚本前捕获（`:91-96`）；对 12 个 `TextMetrics` getter 用对象字面量访问器重定义，保留原 `set`/`enumerable`/`configurable`（`:146-152`）。
   - 不变量测试：不改 `globalThis` 自有键/符号（`Tests/AnyBrowserCoreTests/IdentityShimTests.swift:114-119`）；getter 的 `name="get width"`、`length=0`、own 属性只有 `length,name`、无 `prototype`、`{}` 上调用抛 `Illegal invocation`、`enumerable` 保持 true（`:136-156`）；注入两次幂等（`:157-159`）。
   - **不可见面**：`b.j`（不碰 navigator）、`b.i`（不建节点）、全局键。
   - **可见面**：`TextMetrics.prototype.*.get.toString()` 是 `get width() {…}`（非 `[native code]`）；document_start 的探针开销进入 `b.n`；每次 `measureText` 的 getter 多一层 apply/WeakMap。
2. **PasskeyBox**（`dist/AnyBrowser.app/Contents/Resources/Extensions/PasskeyBox/manifest.json:24-45`，默认 `loadPasskeyBox:true`，`LaunchOptions.swift:35,49`）
   - `inject.js` 在 MAIN world、`all_frames`、`document_start`，不改 navigator、不建节点（`inject.js:98-296`）。
   - 替换 `CredentialsContainer.prototype.create/get` 与 `PublicKeyCredential` 三个静态方法（`:252-253、273-275`）；`replaceMethod` 继承原描述符的 `writable/enumerable`（`:176-184`）。
   - 恒返回 `isUserVerifyingPlatformAuthenticatorAvailable()=true`、`isConditionalMediationAvailable()=true`（`:257-262`）——对 Stripe 采集器不可见，对其它 WebAuthn 探测可见。
   - `content.js` 会在需要时把 `<passkey-box-ui>`（自定义标签，无 id/name）挂到 `documentElement`（`content.js:275,327-337`），不进 `Object.keys(document)`；带 open shadow root。

### 11.4 结论修正

- 「零 JS 注入」对**采集器实际读取的 15 个值**成立：两个注入都不碰它们。
- 对**结构探针**（`b.i`/`b.j`）也成立：都保持 `[]` / `["location"]`。
- 但它不是字面意义的零注入：两个 MAIN world 脚本常驻，`b.n` 分布与 `t/at` 尾部被抬高，`toString` 可见性由「全原生」降为「两个扩展的函数非原生」。
- 对「新设备」的含义：注入本身**不会**让新 Profile 露馅；真正决定归并的是 `id` 的值集合（§0.5）与 cookie jar。
- 正确写法应改为：**值层零注入（engine-first），注入只允许做「不改变值、不产生键、不建节点」的运行时修补，并纳入 E2E 断言（`b.j===[]`、`dkeys===["location"]`、无 `id:"unavailable"` 报文、`at` 只出现在 j/n）。**

---

## 12. 对 AnyBrowser 的行动建议

**P0（新设备语义）**

1. 把 `id` 当设备类标识对待：新 Profile 必须让至少一项高熵值变化。默认 `.font` 关闭时，所有 Profile 的 `a.j.v` 是宿主 macOS 的同一 55 位串（真实抓包 `/tmp/stripe-recon/font-off.json` 的 `fontBits`），屏幕/CPU/UA 也常相同，只剩 canvas 种子在变。优先补平台字体向量 + 屏幕/DPR/colorDepth（计划文档 §P0 已有方向）。
2. 新 Profile = 空 cookie jar（无 `__stripe_mid`/`__stripe_sid`）+ 空 sessionStorage。换 seed 而保留 cookie 的语义要按「同设备升级」处理并写进 UI 文案。
3. 验收加一条：两个全新 Profile 的首条报文 `id` 必须不同；`b.d` 首条可以是 `"NA"`，但第二条必须是 42 字符且与首条不同。

**P1（注入卫生）**

4. 在任何 E2E 快照里断言 `b.j===[]`、`b.i===["location"]`；IdentityShim/PasskeyBox 升级时跑同一断言。
5. 保持 shim 的现状约束：MAIN world、document_start、无全局键、无 DOM、保留 getter 描述符形状、幂等。若要更进一步，给 getter 加 `toString` 补丁会引入新的注入面（利：骗过第三方；弊：`Function.prototype.toString` 本身被改），建议单独评估。
6. 记录 `b.n` 的基线分布（本机探针 34–51 ms，真实抓包 42.7 ms），shim/PasskeyBox 改动后对比；不要让它单边抬到 100 ms 量级。

**P1（时序与缓存）**

7. 不要按导航清 sessionStorage；只在新身份或 full-reset 时清。保留 `id`/`_mf`/`_ab` 的自然 per-tab 生命周期。
8. 保留 m.stripe.network 帧的布局与存储权限：AdBlock bait 依赖 `clientHeight/clientWidth`，Fonts 依赖共享 ctx；禁扩展/内容阻断器对该帧动手。
9. 不要预置 `_ab`/`_mf`；命中时 `at` 会掉到 ≈0，这是正常且必须出现的。

**P2（URL/错误）**

10. 不改 `location.hash` 里的 `url/title/referrer/muid/sid/version`；代理不重写 m.stripe.network 的 inner.html/out-*.js 路径。
11. 保证 m.stripe.com 的 CORS 头不被剥（`withCredentials` + 读 `responseText`），否则触发 §4.2 的错误哨兵与身份链断裂。
12. E2E 断言不出现 `id:"unavailable"`；出现即视为回归。

**P3（根治）**

13. 修引擎 `CanvasRenderingContext2D::measureText` 的乘性因子 bug（`clientrects_noise_x` 派生值被当成乘数），让 shim 可以下线；届时 `a.j.t/at` 回到纯原生、getter `toString` 回到 `[native code]`。

**不建议**

- 用网络改写替代环境层：可以跑但维护成本高，且页面内其它消费者（v3 自己的 UA 判定、Elements 尺寸、Passkey）拿不到改写值。
- 用 Proxy 包 navigator：`Object.keys(navigator)` 必然多键（Proxy 的 ownKeys 会透出），且 `navigator` 的 `instanceof`/原型链容易破坏。
- 给 `navigator.plugins`/`mimeTypes` 做 JS 替换：固定 5 条 PDF 表极易被写坏，且 `b.j` 会多键。

---

## 13. 未解 / 仅推断

1. m-outer 页（`js.stripe.com/v3/m-outer-*.html`）里把 m.stripe.network 帧的 m2 消息转给商家页的那段内联脚本未下载到；本文 §7.3 的「parent 是中转页」是结构推断。
2. m.stripe.com 响应体就是 `{"muid","guid","sid"}` 的三键 JSON：由 `MSG_REGEX`（唯一被校验的字符串形态）与 `m2` 分支的取值反推，未见真实响应抓包。
3. `he`（是否允许第三方 cookie/帧）的具体来源模块未逐行读完；按两处行为（`!he` 时不建帧、guid 随机）可确定它是「可建帧」布尔。
4. `GET /v1/consumers/accounts/sign_up` 的 400 抓包不含 fingerprint 响应；`/tmp/stripe-recon/*.json` 只覆盖注册调用与一次页面环境枚举。
5. 引擎的 `measureText` 因子是「按 document 初始化时用 seed 计算」而非每次调用随机——依据是 `IdentityShimTests.swift:27-29` 的固定值断言与 `clientrects_noise_x` 字符串；上游原版 ungoogled 是每次 document 随机，AnyBrowser 做过改造（推断）。