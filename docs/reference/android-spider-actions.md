# Android Spider 操作、导航与登录契约（一手源码调研）

## 结论与边界

本次只研究、不实现。README.md:144–150 指定 WebHomeTV 为 Android 参照，FongMi 为上游，MisaTV 为比较对象。用户已确定首个交付目标是**当前来源的手动配置能工作**，不是先交付泛型 action 或新版 FongMi Dialog；本文件仅为这一决策提供事实边界，不实施登录机制。

**必须分开三条通道：**

1. **WebHomeTV 显式 action 卡片**：非空字符串 `action` → `spider.action(String)` / type-4 URL GET → Result JSON → msg 提示。目录是另一条 category 导航，不是 action。[W1][W2][W3][W4]
2. **本次 PanConfig 遗留配置卡片**：协调者的独立 payload 调查报告显示它们是普通 Vod，点击走 `detailContent([id])`，在源内产生 Android UI 副作用，再返回占位详情。它们不是上述显式 action 协议；单补 action dispatcher 不会使它们进入新通道。该 payload 的证据归属与未验证部分见 §3。
3. **较新 FongMi Runtime/Dialog**：另有声明式 JSON、Future、源内 callback 和 Web/Cookie 登录契约。**这些 Runtime/Dialog 类不存在于本次固定的 WebHomeTV catvod 源码树**，不能倒推它已支持新版 ABI，也不能把它的 Dialog callback 当成旧 PanConfig 的 AlertDialog listener。[F1][F2][F3][C1]

不以标题、quark 等 ID 字样、空播放地址或单纯字符串命中证明操作行为。下文 upstream 事实以具体调用与返回链为依据；PC 选项是调研后的边界选项，不是实施承诺。不做 Android widgets 全量模拟、不构建应用、不执行登录或用户操作；“不支持就返回空列表/空字符串伪装成功”已排除。

## 1. 固定版本与证据索引

| 项目 | 分支 / 固定提交 | 证据用途 |
| --- | --- | --- |
| [webhtv/webhtv](https://github.com/webhtv/webhtv) | main / `4e30ffaf219b1db15fe5662aeff6f9820e2b32bf` | 真正的 Android 参照：点击、action/detail/category、Activity 与 JAR 初始化 |
| [FongMi/TV](https://github.com/FongMi/TV) | fongmi / `e7e7dd06250ca53da3c594ca4f6befc02e56b1d1` | 新版 Runtime/Dialog、Web 登录宿主与生命周期 |
| [FongMi/CatVodSpider](https://github.com/FongMi/CatVodSpider) | main / `ab5b0057ed041058ea815954b7e682fd7e07179e` | 上游自己的 Demo、Market 与开发说明；不是第三方博客 |
| MisaTV 本地副本 | `.probe/misatv-src/MisaTV-main/`；本次未能证明副本 SHA | 只作本地 MethodChannel/Android Application 对照，不用于上游版本结论 |
| PC 当前工作树 | 以文末本地 file:line 为准，含其他任务原有改动 | 只读最小协议/运行时比较；不是干净提交基线 |

GitHub REST API 返回 rate-limit 403；改用 `git ls-remote --symref … HEAD`、浅层稀疏源读取与 `rev-parse HEAD`固定提交。canonical CatVodTVOfficial 仓库链接当前无法读取，未用它作论据。没有递归克隆其他项目。

可复核的有限源码摘录：`.probe/android-action-reference/{webhtv,fongmi,catvod}-source-excerpts.txt`；提交清单：`.probe/android-action-reference/pins.json`。共 4 个持久 scratch 文件；外部链接均固定完整 SHA。原始源码缓存位于本轮独占临时目录，已在文档核验后删除。

## 2. Android host/source → payload → 方法与结果 → PC 缺口

| 通道 / 宿主契约 | payload 形状与检测 | 实际方法、参数、返回语义 | PC 缺少的 seam |
| --- | --- | --- | --- |
| WebHomeTV 显式操作 [W1][W2][W3][W4] | Vod 独立字段 `action:String`；`isAction()`仅检查 getAction 非空。先 action，再 folder，再普通详情 | site type=3 调 `site.recent().spider().action(action)`，**传 action 字符串，不传 vod_id/整张卡片**；返回 JSON Result；分类页 observer 显示 `result.getMsg()` | Dart SiteRuntime 没有 action；CatVod adapter 不声明/绑定 action；IPC 虽保留 action 名称但最终没有执行分支（§6） |
| WebHomeTV type=4 操作 [W4] | 同一 action 字段，其值是请求 URL；type 是 Site 类型，不是卡片 “type=action” | `OkHttp.string(action)`读取 URL，Result.fromJson；不是调用 detail，不追加通用 cate/params/callback envelope | 需要对应 HTTP 操作语义/安全边界；不能把源 URL 当本机命令 |
| WebHomeTV 目录导航 [W1][W2][W7] | `vod_tag:"folder"`或非空 Cate 对象；Cate 是 land/circle/ratio 样式对象，不是 action 参数。[W11]file 或未匹配项走普通分支 | 分类页 `openFolder(item.id,mExtends)`；category ABI 为 `categoryContent(String tid,String pg,boolean filter,HashMap<String,String> extend)`；保留分页/筛选上下文 | 已有 Vod.isFolder/category 部分；不应为配置卡片伪造 folder 或误解释 cate |
| WebHomeTV 普通详情，可承载旧式副作用 [W2][W5][W8] | 不满足 action/folder → VideoActivity；host 不按配置名称自动识别操作 | `detailContent(List<String> ids)`，host 传 `Arrays.asList(id)`并解析返回列表；源的任意 Android UI 调用发生在此方法内部，详情 JSON 未必表达 UI | 外部 JVM 不提供真实 Activity、UI 主线程或原生 listeners；普通详情返回不能表达“弹窗已经成功” |
| PanConfig 遗留输入/清除/登录 | 协调者 payload 证据：普通四字符串 Vod，无 action/tag；quarkmanual 的源内 C(id,key,title,currentValue) → Activity 分支 | 非空 Activity 分支是原生 EditText/AlertDialog + 保存 listener；空 Activity 分支是源的提示/配置网页 fallback；占位 F(id) 是详情结果，不是交互结果 | **不是通用 action 缺一个方法**；须确认源内回调/存储或已有配置网页的具体业务接口，见 §3。新版 JSON Dialog 不能自行替代 |
| 新 FongMi 直接原生 UI [F1][C3] | 显式 action 可用 URL 参数触发 Market，但 dialog 不是 Result 字段 | Market.action(url) 主 Handler.post(showDownload)，返回 {}；主线程才 getActivity，检查不可用/finishing/destroyed；destroy 清理 dialog | 同进程 Android Activity/Looper/窗口/下载回调不是 JVM 类型垫片能保证的能力 |
| 新 FongMi 声明式 Dialog [F1][F2][F3][F4][F5][C1][C2] | 调用期 options JSON，含 title/message/inputs/buttons/qrcode 等；callback 是**第二个函数参数**，不放 options 里 | Spider.dialog(JSONObject,Dialog.Callback) → Runtime.dialog(String,Function) → CompletableFuture<String>；按钮 event={button,values}，callback 回 JSON patch，最终确认回 {button,values}，取消回 null | 需要由源进程发起的宿主 UI 请求、相关联的按钮事件/patch/完成/取消通道和工作期限语义，不只是主机→源 action RPC |
| 新 FongMi Web/Cookie 登录 [F6][F7][F8][C2] | action 返回 `{"web":{"url":"https://…","mode":"browser","cookie":[{"url":"https://…","keys":["session"]}]}}`（示意，非实测服务） | action observer → WebActivity.handleAction → takeWeb → 打开 Android WebView；CookieManager 记录进入前快照，满足同源、某组 keys 全非空且至少一个变化时 flush 并关闭 | 需共享的浏览器 Cookie 容器、完成判据/来源作用域；外部系统浏览器不会自动把 Cookie 回传 JVM，尚待产品决策 |

### 2.1 第一条通道的原始 clickable flow

~~~text
TypeFragment.onItemClick(Vod)
  if item.isAction():
    SiteViewModel.action(siteKey, item.getAction())
      execute(TaskType.ACTION, action LiveData, SiteApi.action)
        type 3 -> recent Spider.action(String)
        type 4 -> GET action URL
        -> Result.fromJson(String)
      -> action LiveData
    TypeFragment observer -> Notify.show(result.getMsg())
  else if item.isFolder(): openFolder(item.id, existing filters)
  else: VideoActivity.start(...) -> detailContent([item.id])
~~~

该优先级在 WebHomeTV leanback TypeFragment:253–261 和 mobile TypeFragment:192–199 都可核对。[W2][W3] HomeActivity:615–618 也先处理 action，但不能把分类页 observer 的行为无条件套给所有页面。[W12]

`vod_tag="action"`、标题叫“登录”、额外 `type/params/callback`字段不是上述检测条件。`params`在 HTTP/category/proxy 等局部方法中有不同意义，不存在这些 pinned 源码证明的通用 “action object” envelope。类型4 URL请求、类型3单 String ABI 与 Dialog options 是三个不同的数据接口。[W1][W4][C1]

返回 `{"msg":"…","code":0}`可产生提示；WebHomeTV getMsg 仅在 code=0 且 msg 非空时给出文本。源码存在宽松 Result.fromJson 错误降级和其他 site type 返回 empty 的历史实现，但这不构成 PC 应静默吞掉不支持功能的标准。[W6] CatVod 的实际 Demo.action("toast") 返回 Response.notify，Response.notify 经 create() 输出 parse=0、jx=0、msg；另一支 native_toast 直接调用 Runtime.toast 并返回 {}，再次说明返回值不是所有副作用的表示。[C2][C4]

WebHomeTV action 与普通 result/player 使用不同 TaskType。新请求取消同类旧 Future；有 TIMEOUT_VOD，taskId 检查抑制旧结果；取消不是中止任意第三方 Android 副作用的保证。[W9]

## 3. 第二条通道：PanConfig detail 副作用不能冒充 typed action

**证据归属：**本节 PanConfig 内部事实来自协调者转交的独立 payload 子任务；本研究没有在限定边界外反编译该 payload。公开的 pinned WebHomeTV/FongMi host 不是这份第三方 PanConfig 的源码。不能给它编造 GitHub source:line，也不能宣称 App.activity() 就是 InitOrigin.getActivity() 的具体实现。

已只读复核协调者提供的 **raw-schema证据**：`.probe/panconfig-action-diagnosis/run3-output.txt:1–15`（命令：`run2-command.json:18–36`）。入口为 `com.github.catvod.spider.PanConfigGuard`；category quark 的4张卡片每张仅含 vod_id/vod_name/vod_pic/vod_remarks；quarkmanual detail 仅含 vod_id/vod_name/vod_content，后者提示未弹窗时打开网页版配置中心。日志报告 Activity null、Toast仅stderr替代、缺 `android.app.ActivityThread`，并明确 `NO_INIT_NO_ACTION_NO_SAVE`。本探针不是完整初始化/登录/保存流程，也没有验证网页可用性。

协调者独立验收补充：当前 host.jar SHA-256=`fe5231b029a4bda60acbaf9d07e3a22dfce608bc11d0c4448d595da59027703e`；报告此次受限probe未产生 outbound/write 事件、复制的 prefs目录为空。SecurityManager 的 deniedConnect=0 **不证明配置后的分类/扫码路径无网络，也不是OS级egress firewall**；最终probe未执行Init、QR详情或保存，限制外推。**这是宿主hash，不是payload hash；没有保存发生不能当成“保存成功”。**

协调者提供的控制流摘要：

~~~text
category: quark / qkregister / quarkmanual / quarkclear
  -> merge.l.k 四字符串 Vod（无 action / vod_tag）
item click -> 普通 detailContent([id])
  quark -> PanConfig$1 -> F(id) 详情占位
  quarkmanual -> C(id, Wex_quark_cookie, title, currentValue)
    -> PanConfig$42 / $42$1 -> InitOrigin.getActivity()
       null: 提示 local/configURL
       nonnull: $49 -> EditText + AlertDialog + saver listener
~~~

因此 Android host 的“导航到详情”不是错误；真实交互在源内执行，返回 F(id) 也不能证明输入/登录完成。**通用 action(String) dispatcher 即使完全实现，也不会被这些无 action 字段的卡片调用。**

公开 upstream 能独立证明的宿主前提：[W8][W10]

- JAR loader 调可选的 `com.github.catvod.spider.Init.init(android.content.Context)`，参数是实际 `App.get()`（Application），然后创建 Spider、写入 siteKey、调 `spider.init(App.get(), ext)`。
- App 注册 Android `Application.ActivityLifecycleCallbacks`；onActivityResumed 保留当前 Activity，onActivityPaused 清空；App.activity() 返回当前对象，App.post 使用主 Handler。
- 这既不是桌面 Context 垫片，也不是“构造一个 Activity 名字的类”就能达到的 UI 能力。真实源可能自行在可选 Init 里注册 Activity 回调；**该 InitOrigin 注册链必须由 payload 证据单独核实**，本 host 源码不足以推定。

独立 payload 子任务随后补充了原始/转译产物hash和具体 bytecode offsets，见下面 §3.1；本研究只读复核了 raw-schema 文件，静态反编译证据由该子任务提供，不能当成已执行保存证据。

仍待 payload/集成证据精确化：配置网页 URL 是否实际可访问、接口/参数/鉴权/监听地址；自动登录是否依赖 WebView Cookie 或其他 token；注册/清除的状态写入与 refresh 行为；持久化 key/文件和源实例缓存失效；Activity null fallback 是否只是提示而非可执行完整替代。**不得直接把 local/configURL 字符串当已可用桌面接口。**

### 3.1 遗留 source/host 精确二进制证据（独立 payload 子任务提供）

证据目录：`.probe/panconfig-action-diagnosis/`；完整报告 `report.md`。下面的 offset 是 **JVM bytecode offset，不是 DEX offset 或 Java源码行**。这些不是公开FongMi源文件，必须与它们各自的payload hash绑定。

| 产物 | SHA-256 |
| --- | --- |
| 原始安装 payload.jar | `6644bed20cf19aac6003726da48d6124497840b1e09ad52b97b8c5a8764023f3` |
| payload-dex/dexBundles/classes.jar 转译产物 | `e5058576e50f5a43b9721790fa0142dd57829d0b379cced71e40e9b6ec532da6` |
| index.jar | `620afed882618749e5a9fbb558f8eb847f4a4a4c6f6a5369f6b9099331849138` |

| 原始点击后的 source 方法/精确参数 | bytecode控制流与返回 | 子任务的文件:行证据 |
| --- | --- | --- |
| `PanConfig.C(String id,String key,String title,String current)` | 0 new $42；9 ctor(this,key,title,current)；12 InitOrigin.execute(runnable)；16 F(id)；19 areturn。UI异步启动与占位detail返回分离 | `focused-javap.txt:4328–4340` |
| `PanConfig$42.run()` | 0 new $42$1；8 delay=800；11 InitOrigin.post(runnable,800) | `ui-persistence-javap.txt:28–36` |
| `PanConfig$42$1.run()` | 31 InitOrigin.getActivity；38 ifnonnull54；45 fallback文本；50 w0.a.h；53 return。非空分支54 new $49；65 ctor(PanConfig,Activity,title,current,key)；68 InitOrigin.post | `ui-persistence-javap.txt:50–86` |
| `PanConfig$49.run()` | 70 new EditText；99 setText(current)；327 AlertDialog.Builder；343 setView；346 show；376 new save listener m；387 ctor($49,EditText,title,key)；392 setOnClickListener | `ui-routes-javap.txt:33–239` |
| saver `m.onClick(View)`默认分支 | 54 getText；60 trim；68空值检查；86检查Cookie:前缀；95 substring(7)；107 y0.e.p0(value,key)；110 PanConfig.r refresh；119 Toast。**静态保存分支存在≠probe已保存** | `server-cookie-javap.txt:947–1000` |
| `y0.e.H()` / `I(key,default)` / `p0(Object value,String key)` | H：0 InitOrigin.context；3 NewWexFnw_preferences；7 Context.getSharedPreferences(name,0)。I：H→getString(key,default)。p0的String分支：14 H；17 edit；27 putString(key,value)；32 apply | `ui-persistence-javap.txt:2489–2534,8227ff` |

对应PC持久化host路径由子任务提供：`EntryLoader.java:216–220`用 siteDir/.webhtv-context；`DexNative.java:221–253`注入Application wrapper；`WebhtvContext.java:36–42`映射 shared_prefs/NewWexFnw_preferences.properties；`WebhtvPreferences.java:105–125,140–147`载入构造时snapshot并保存。该路径链没有显示跨站点传播；仍须验证目标实例cache/refresh，不能以文件路径代替行为验收。

这条链已经解释**为什么当前手动配置先补host交互/保存边界，而不是先补Spider.action**：source通过 Runnable/Activity/Android listener自己持有key/title/current与保存逻辑；主机只收到同步detail占位。若选native desktop输入，必须保留这条具体保存链/刷新语义；若选网页fallback，必须验证源网页实际的表单/保存接口。旧listener不能自动视作新版Dialog.Callback。

## 4. 第三条通道：新版 FongMi 声明式 Dialog 与登录

### 4.1 精确签名与数据方向

以下签名直接来自固定 FongMi Java 源码；括号后的 descriptor 是按这些源码类型的 JVM 擦除形式记录，不声称本轮构建或执行了 upstream 二进制。[F1][F2][F3]

| 接口 | Java 签名 / JVM descriptor | 方向 |
| --- | --- | --- |
| action | `String action(String)`；`(Ljava/lang/String;)Ljava/lang/String;` | host→source；旧/新版本均有，默认返回不同，不能用基类默认值证明支持 |
| detail | `String detailContent(List<String>)`；`(Ljava/util/List;)Ljava/lang/String;` | host→source；旧配置副作用入口 |
| Spider.dialog | `JSONObject dialog(JSONObject, Dialog.Callback) throws Exception`；`(Lorg/json/JSONObject;Lcom/github/catvod/utils/Dialog$Callback;)Lorg/json/JSONObject;` | source→host，源 worker 同步等待 |
| Dialog.Callback | `JSONObject onAction(JSONObject) throws Exception`；`(Lorg/json/JSONObject;)Lorg/json/JSONObject;` | UI event→源 worker；返回 patch，不是调用 Spider.action |
| Runtime.dialog | `static CompletableFuture<String> dialog(String, Function<String,CompletableFuture<String>>)`；`(Ljava/lang/String;Ljava/util/function/Function;)Ljava/util/concurrent/CompletableFuture;` | source请求→host Future；callback Future 是单次事件更新 |
| Runtime.setDialog | `static void setDialog(BiFunction<String,Function<String,CompletableFuture<String>>,CompletableFuture<String>>)`；`(Ljava/util/function/BiFunction;)V` | host注入执行能力 |
| Runtime.setActivity / activity | `setActivity(Supplier<Activity>)` / `Activity activity()`；`(Ljava/util/function/Supplier;)V` / `()Landroid/app/Activity;` | host提供动态 Activity，不保存失效页面 |

App.attachBaseContext:90–93 注入 Runtime Context、Activity supplier、UI线程 toast consumer 与 `SpiderDialog::show`。JarLoader.newSpider:201–203 另外注入 siteKey、按站点 Net 和 Local；这也是新版 source ABI 的依赖，不只是补一个 Spider 方法。[F9][F11]

### 4.2 options、event、patch、completion

以下示意按第一方开发文档/Demo 缩减，**不是新增 PC 协议设计**。[C1][C2]

~~~json
{
  "title": "登录", "cancelable": true,
  "inputs": [
    {"name":"phone","type":"phone","required":true},
    {"name":"code","type":"text"}
  ],
  "buttons": [
    {"id":"send","label":"发码","close":false,"validate":["phone"]},
    {"id":"confirm","label":"确认"}
  ]
}
~~~

按钮验证通过后的 event：`{"button":"send","values":{"phone":"…","code":"001234"}}`。源 callback 可回 `{"errors":{"phone":"…"}}`保持窗口，或 `{"values":{"code":""},"close":false}`更新值；成功回 close=true 后最终 completion 返回 {button,values}。验证码保持字符串。callback 不在 options JSON 内序列化。[C1][F4]

支持的有限宿主语义：text/phone/number/password/textarea/select/multiselect；value 为字符串，多选字符串数组；required/长度/选项检查；buttons 最多3个、close=false 必须有 callback；validate 控制本次需检查字段；message、qrcode、data URI image、copyable；patch 可更新值/错误、按钮和输入 enabled 状态。业务验证与网络请求属于源，不属于宿主 widgets。[C1]

### 4.3 工作线程、期限、取消与会话寿命

- Dialog.show 拒绝主线程阻塞调用。Runtime 返回 Future，宿主 App.post 展示 UI；按钮事件经队列交回**原源 worker**，callback 回 patch Future；UI完成处理再次 App.post。不能在 JVM 请求线程等待时封死同一 IPC 接收线程，否则无法接收按钮/取消。[F2][F4]
- 无可用 FragmentActivity、错误参数或 callback 异常 → exceptional completion；未注入 Dialog host → UnsupportedOperationException("Dialog requires a compatible App")。不是成功空返回。[F1][F4]
- UI等待期间 Dialog.waitForAction 使用 CallTimeout.suspendCurrent；suspend 连父 scope 一并挂起，resume 用剩余预算继续计时；callback 执行恢复计时，网络超时并不因此暂停。[F2][F5][C1]
- 普通 dismiss 与 Activity ON_DESTROY 完成 null。请求取消关闭窗口、取消 event Future、移除 lifecycle observer 并释放视图引用；源 Dialog.close 取消自己所有 pending请求，Spider.close先关闭 Dialog，再关闭 JS/Net。[F3][F4]
- 取消/释放不能保证硬中止任意 Java 计算/第三方阻塞；callback 须配合中断。确认、取消、异常是三种不同终态，不得当成同一种 {} 成功。[C1]
- 登录发码/验证由源 callback 执行；第一方文档明确：确认返回后才保存凭据，取消不套用登录结果。Dialog 本身不是凭据仓库，也不是通用业务登录 API。[C1]

### 4.4 Web 登录是另一个明确结果契约

新版 FongMi 的 Home/Vod/Folder/Collect action observer 调 `WebActivity.handleAction`。该函数先消费 `Result.takeWeb()`，打开 WebActivity，再显示 msg；不是把 web JSON 解释为原生表单。Demo.web 用 Web.url/mode/cookie 构造返回。[F6][C2]

Web.url 必须为 HTTP(S) 可解析 URL；mode 仅 browser/view；cookie 是 {url,keys} 分组，url 可默认网页地址。进入前 snapshot 初值；完成时必须当前页面同源、某一组所有 key 非空、至少一个 key 值较初值改变，CookieManager.flush 后关闭。这是宿主 CookieManager 的状态检测，不是服务器已验证所有业务登录条件的保证。[F7][F8]

JsHost.getCookie/setCookie 使用 WebViewCookies，source Net 可共享此容器；第一方文档另区分隔离 `net.session()`：自带 Cookie 与缓存，不共享 WebView/站点缓存，close 取消自身请求/等待/串流/连接并丢弃自己的状态。**外部浏览器、App WebView Cookie、临时 Session、旧 PanConfig 的持久化配置不是同一个会话容器。**[F10][C5]

## 5. MisaTV 本地对照：不能替代真正 Android 参照

本地 `jar_spider_android.dart:289–305`用 MethodChannel invoke({method,args,className}) → {ok,data/error}；不是源主动发 UI 请求的双向 Dialog 协议。Android `SpiderHostPlugin.kt:404–464`逐项反射 home/category/detail/search/player/live/proxy，其他方法返回“未知方法”；无 action 分支。init:360–365 使用 appContext；MainActivity.kt:6–16 在配置 Flutter engine 时绑定真实 Application，插件:98–105、635–685解决 Application 类型获取；**绑定 Application 不等于已给旧源提供可显示窗口的 Activity 或 Runtime.setDialog。**

这些是本地代码事实而非 SHA 固定的外部 upstream结论。Android 原生 DexClassLoader/ART 支持只能证明类加载环境，不证明用户动作已经连通。

## 6. 当前 PC 最小比较与所需 IPC/source seam

只读比较落点：

- `apps/desktop-flutter/lib/core/protocol.dart:962–1018,1022–1064`：Vod 已独立保存 vodTag，unknown字段（包括 action/cate）进 extra；isFolder 识别 folder/cate。**字段保留不等于 action click 分流存在。**
- `apps/desktop-flutter/lib/services/spider_router.dart:62–95`：SiteRuntime 只有 home/category/detail/search/play。
- `sidecars/spider-host-jvm/src-android-shim/src/com/github/catvod/crawler/Spider.java:52–54`：action(String) 签名已在但返回 null；这只是链接/继承垫片。
- `sidecars/spider-host-jvm/src/webhtv/spider/CatVodSpiderAdapter.java:258–282`：capabilities推断不包括 action，也没有对 action 方法的执行绑定。
- `sidecars/spider-host-jvm/src/webhtv/spider/SidecarServer.java:326–337,400–417`：外层 switch **已有 case action**，但内层 call() 无 action分支，落到 UnsupportedMethodException。因此准确描述是“保留了名字、未接通执行”，不能只靠搜索 action 断言支持。

最小 coherent seam 分层（不是实施方案）：

| 目标 | 至少必须保持的契约 | 不能顺带承诺 |
| --- | --- | --- |
| 显式 action 卡片的兼容 | 原 action值/来源key；host→source方法与能力声明；非媒体结果/提示、取消/错误；type4 URL语义与策略 | 旧 PanConfig 输入/登录；任意 Android UI；新版 Dialog 或浏览器 Cookie |
| 旧配置 UI 的替代入口 | 由真实 payload 证据确定入口、表单键/值、保存/清除/登录回调和状态容器；若选源已有配置网页，验证路由/鉴权/实例刷新 | 仅靠非空 Activity垫片就实现所有 Android View/listeners；仅靠空详情判定用户动作成功 |
| 新版声明式 Dialog source兼容 | source→host请求及相关联request/session ID、按钮event→原source callback、patch→host、最终result/null/error、关闭/owner寿命、等待期限挂起 | 尚无证据的旧payload能调用新版 ABI；callback可直接序列化成JSON；单向 action RPC 足够 |
| Web/Cookie 登录兼容 | 受控网页容器与 Cookie共享/变更完成判据；来源作用域和生命周期；明确取消/失败；源确认证据后的保存 | 系统浏览器 Cookie可自动读取；全局跨源共享凭据；临时session自动持久化 |

新版 Android是同进程 Future/function调用。桌面外部 JVM 必须将跨进程的函数身份、事件关联、返回patch及取消转换为显式消息；现有主机→源 detail/action请求响应本身不能传 Java Function对象。这是由源码接口方向推导的必要接口事实，不规定字段名、UI组件或完整 emulator。

## 7. 已由 Android 先例确定 / 仍需产品决定

**Settled：**用户已选当前来源手动配置作为首个交付目标（不是新版Dialog先行）；显式 action字符串与目录/详情分流；source method精确签名；普通 detail可产生源内UI副作用；真正 Activity/主线程/生命周期必要；新版 Dialog event/patch/null/error/取消/期限；业务验证在源，确认后保存；Web/Cookie 与隔离session区别。

**Assumed：**本次 PanConfig 原始payload分类/方法链以协调者独立证据为准，不把未来schema变化当同一来源；不复制GPL实现，本次只记录接口事实；MisaTV仅本地比较。

**Ruled out：**按标题猜 action；强行把所有配置详情改调 action；吞掉 unsupported回空；原生widgets全量模拟；无证据宣称新版 Runtime已在 WebHomeTV。

**Completion / 后续已定：**已依据raw schema确认当前手动配置是detail副作用通道。用户随后选择先让当前配置中心手动输入可用，兼容源账号全应用共享；首阶段只适配已证实的夸克/百度 Cookie 手动输入与清除、取消不写和刷新。采用桌面输入及显式账号读通道，不依赖尚未验证的网页，不模拟原生 widgets，不将新 FongMi Dialog 直接套到旧 PanConfig。实施契约见 `docs/superpowers/plans/2026-11-24-panconfig-manual-accounts.md`；这段记录用户选择，不是调研代替产品决策。

## 8. 证据限制与验收提示

- 公开 upstream是源码阅读，未运行APK、未做网络登录、未证明任意第三方 jar可用。
- 三个源码版本独立固定，FongMi/CatVodSpider 当前版本比 pinned WebHomeTV 更丰富；不能混用host ABI。
- PanConfig 第三方内部没有可引用公开GitHub源码；§3.1已收录独立payload任务提供的二进制hash/精确method offsets，本文明确隔离该证据归属与静态/运行时证据。
- 源自定义原生Activity UI没有通用声明式JSON抽取标准；“适配旧源所有UI”不属于这里证明的最小桌面能力。
- 复核应检查三lane不合并、固定SHA链接、PC外层action名称与内层缺口区别，以及真正取消/确认/异常语义。没有生产文件修改。

## 一手源码链接（均固定提交）

- [W1] [app/src/main/java/com/fongmi/android/tv/bean/Vod.java:65–276](https://github.com/webhtv/webhtv/blob/4e30ffaf219b1db15fe5662aeff6f9820e2b32bf/app/src/main/java/com/fongmi/android/tv/bean/Vod.java#L65-L276)
- [W2] [app/src/leanback/java/com/fongmi/android/tv/ui/fragment/TypeFragment.java:137–269](https://github.com/webhtv/webhtv/blob/4e30ffaf219b1db15fe5662aeff6f9820e2b32bf/app/src/leanback/java/com/fongmi/android/tv/ui/fragment/TypeFragment.java#L137-L269)
- [W3] [app/src/mobile/java/com/fongmi/android/tv/ui/fragment/TypeFragment.java:192–205](https://github.com/webhtv/webhtv/blob/4e30ffaf219b1db15fe5662aeff6f9820e2b32bf/app/src/mobile/java/com/fongmi/android/tv/ui/fragment/TypeFragment.java#L192-L205)
- [W4] [app/src/main/java/com/fongmi/android/tv/api/SiteApi.java:222–228](https://github.com/webhtv/webhtv/blob/4e30ffaf219b1db15fe5662aeff6f9820e2b32bf/app/src/main/java/com/fongmi/android/tv/api/SiteApi.java#L222-L228)
- [W5] [app/src/main/java/com/fongmi/android/tv/api/SiteApi.java:114–141](https://github.com/webhtv/webhtv/blob/4e30ffaf219b1db15fe5662aeff6f9820e2b32bf/app/src/main/java/com/fongmi/android/tv/api/SiteApi.java#L114-L141)
- [W6] [app/src/main/java/com/fongmi/android/tv/bean/Result.java:108–208](https://github.com/webhtv/webhtv/blob/4e30ffaf219b1db15fe5662aeff6f9820e2b32bf/app/src/main/java/com/fongmi/android/tv/bean/Result.java#L108-L208)
- [W7] [catvod/src/main/java/com/github/catvod/crawler/Spider.java:26–47](https://github.com/webhtv/webhtv/blob/4e30ffaf219b1db15fe5662aeff6f9820e2b32bf/catvod/src/main/java/com/github/catvod/crawler/Spider.java#L26-L47)
- [W8] [app/src/main/java/com/fongmi/android/tv/api/loader/JarLoader.java:124–215](https://github.com/webhtv/webhtv/blob/4e30ffaf219b1db15fe5662aeff6f9820e2b32bf/app/src/main/java/com/fongmi/android/tv/api/loader/JarLoader.java#L124-L215)
- [W9] [app/src/main/java/com/fongmi/android/tv/model/SiteViewModel.java:120–212](https://github.com/webhtv/webhtv/blob/4e30ffaf219b1db15fe5662aeff6f9820e2b32bf/app/src/main/java/com/fongmi/android/tv/model/SiteViewModel.java#L120-L212)
- [W10] [app/src/main/java/com/fongmi/android/tv/App.java:63–154](https://github.com/webhtv/webhtv/blob/4e30ffaf219b1db15fe5662aeff6f9820e2b32bf/app/src/main/java/com/fongmi/android/tv/App.java#L63-L154)
- [F1] [catvod/src/main/java/com/github/catvod/Runtime.java:15–60](https://github.com/FongMi/TV/blob/e7e7dd06250ca53da3c594ca4f6befc02e56b1d1/catvod/src/main/java/com/github/catvod/Runtime.java#L15-L60)
- [F2] [catvod/src/main/java/com/github/catvod/utils/Dialog.java:24–85](https://github.com/FongMi/TV/blob/e7e7dd06250ca53da3c594ca4f6befc02e56b1d1/catvod/src/main/java/com/github/catvod/utils/Dialog.java#L24-L85)
- [F3] [catvod/src/main/java/com/github/catvod/crawler/Spider.java:26–154](https://github.com/FongMi/TV/blob/e7e7dd06250ca53da3c594ca4f6befc02e56b1d1/catvod/src/main/java/com/github/catvod/crawler/Spider.java#L26-L154)
- [F4] [app/src/main/java/com/fongmi/android/tv/ui/dialog/SpiderDialog.java:90–650](https://github.com/FongMi/TV/blob/e7e7dd06250ca53da3c594ca4f6befc02e56b1d1/app/src/main/java/com/fongmi/android/tv/ui/dialog/SpiderDialog.java#L90-L650)
- [F5] [catvod/src/main/java/com/github/catvod/utils/CallTimeout.java:25–118](https://github.com/FongMi/TV/blob/e7e7dd06250ca53da3c594ca4f6befc02e56b1d1/catvod/src/main/java/com/github/catvod/utils/CallTimeout.java#L25-L118)
- [F6] [app/src/main/java/com/fongmi/android/tv/ui/activity/WebActivity.java:70–99](https://github.com/FongMi/TV/blob/e7e7dd06250ca53da3c594ca4f6befc02e56b1d1/app/src/main/java/com/fongmi/android/tv/ui/activity/WebActivity.java#L70-L99)
- [F7] [app/src/main/java/com/fongmi/android/tv/bean/Web.java:15–85](https://github.com/FongMi/TV/blob/e7e7dd06250ca53da3c594ca4f6befc02e56b1d1/app/src/main/java/com/fongmi/android/tv/bean/Web.java#L15-L85)
- [F8] [app/src/main/java/com/fongmi/android/tv/ui/activity/WebActivity.java:171–207](https://github.com/FongMi/TV/blob/e7e7dd06250ca53da3c594ca4f6befc02e56b1d1/app/src/main/java/com/fongmi/android/tv/ui/activity/WebActivity.java#L171-L207)
- [F9] [app/src/main/java/com/fongmi/android/tv/App.java:87–93](https://github.com/FongMi/TV/blob/e7e7dd06250ca53da3c594ca4f6befc02e56b1d1/app/src/main/java/com/fongmi/android/tv/App.java#L87-L93)
- [F10] [app/src/main/java/com/fongmi/android/tv/api/loader/JsHost.java:19–54](https://github.com/FongMi/TV/blob/e7e7dd06250ca53da3c594ca4f6befc02e56b1d1/app/src/main/java/com/fongmi/android/tv/api/loader/JsHost.java#L19-L54)
- [C1] [docs/development.md:432–498](https://github.com/FongMi/CatVodSpider/blob/ab5b0057ed041058ea815954b7e682fd7e07179e/docs/development.md#L432-L498)
- [C2] [app/src/main/java/com/github/catvod/spider/Demo.java:267–625](https://github.com/FongMi/CatVodSpider/blob/ab5b0057ed041058ea815954b7e682fd7e07179e/app/src/main/java/com/github/catvod/spider/Demo.java#L267-L625)
- [C3] [app/src/main/java/com/github/catvod/spider/Market.java:54–99](https://github.com/FongMi/CatVodSpider/blob/ab5b0057ed041058ea815954b7e682fd7e07179e/app/src/main/java/com/github/catvod/spider/Market.java#L54-L99)
- [C4] [app/src/main/java/com/github/catvod/utils/Response.java:25–34](https://github.com/FongMi/CatVodSpider/blob/ab5b0057ed041058ea815954b7e682fd7e07179e/app/src/main/java/com/github/catvod/utils/Response.java#L25-L34)
- [C5] [docs/development.md:215–220](https://github.com/FongMi/CatVodSpider/blob/ab5b0057ed041058ea815954b7e682fd7e07179e/docs/development.md#L215-L220)

[W1]: https://github.com/webhtv/webhtv/blob/4e30ffaf219b1db15fe5662aeff6f9820e2b32bf/app/src/main/java/com/fongmi/android/tv/bean/Vod.java#L65-L276
[W2]: https://github.com/webhtv/webhtv/blob/4e30ffaf219b1db15fe5662aeff6f9820e2b32bf/app/src/leanback/java/com/fongmi/android/tv/ui/fragment/TypeFragment.java#L137-L269
[W3]: https://github.com/webhtv/webhtv/blob/4e30ffaf219b1db15fe5662aeff6f9820e2b32bf/app/src/mobile/java/com/fongmi/android/tv/ui/fragment/TypeFragment.java#L192-L205
[W4]: https://github.com/webhtv/webhtv/blob/4e30ffaf219b1db15fe5662aeff6f9820e2b32bf/app/src/main/java/com/fongmi/android/tv/api/SiteApi.java#L222-L228
[W5]: https://github.com/webhtv/webhtv/blob/4e30ffaf219b1db15fe5662aeff6f9820e2b32bf/app/src/main/java/com/fongmi/android/tv/api/SiteApi.java#L114-L141
[W6]: https://github.com/webhtv/webhtv/blob/4e30ffaf219b1db15fe5662aeff6f9820e2b32bf/app/src/main/java/com/fongmi/android/tv/bean/Result.java#L108-L208
[W7]: https://github.com/webhtv/webhtv/blob/4e30ffaf219b1db15fe5662aeff6f9820e2b32bf/catvod/src/main/java/com/github/catvod/crawler/Spider.java#L26-L47
[W8]: https://github.com/webhtv/webhtv/blob/4e30ffaf219b1db15fe5662aeff6f9820e2b32bf/app/src/main/java/com/fongmi/android/tv/api/loader/JarLoader.java#L124-L215
[W9]: https://github.com/webhtv/webhtv/blob/4e30ffaf219b1db15fe5662aeff6f9820e2b32bf/app/src/main/java/com/fongmi/android/tv/model/SiteViewModel.java#L120-L212
[W10]: https://github.com/webhtv/webhtv/blob/4e30ffaf219b1db15fe5662aeff6f9820e2b32bf/app/src/main/java/com/fongmi/android/tv/App.java#L63-L154
[F1]: https://github.com/FongMi/TV/blob/e7e7dd06250ca53da3c594ca4f6befc02e56b1d1/catvod/src/main/java/com/github/catvod/Runtime.java#L15-L60
[F2]: https://github.com/FongMi/TV/blob/e7e7dd06250ca53da3c594ca4f6befc02e56b1d1/catvod/src/main/java/com/github/catvod/utils/Dialog.java#L24-L85
[F3]: https://github.com/FongMi/TV/blob/e7e7dd06250ca53da3c594ca4f6befc02e56b1d1/catvod/src/main/java/com/github/catvod/crawler/Spider.java#L26-L154
[F4]: https://github.com/FongMi/TV/blob/e7e7dd06250ca53da3c594ca4f6befc02e56b1d1/app/src/main/java/com/fongmi/android/tv/ui/dialog/SpiderDialog.java#L90-L650
[F5]: https://github.com/FongMi/TV/blob/e7e7dd06250ca53da3c594ca4f6befc02e56b1d1/catvod/src/main/java/com/github/catvod/utils/CallTimeout.java#L25-L118
[F6]: https://github.com/FongMi/TV/blob/e7e7dd06250ca53da3c594ca4f6befc02e56b1d1/app/src/main/java/com/fongmi/android/tv/ui/activity/WebActivity.java#L70-L99
[F7]: https://github.com/FongMi/TV/blob/e7e7dd06250ca53da3c594ca4f6befc02e56b1d1/app/src/main/java/com/fongmi/android/tv/bean/Web.java#L15-L85
[F8]: https://github.com/FongMi/TV/blob/e7e7dd06250ca53da3c594ca4f6befc02e56b1d1/app/src/main/java/com/fongmi/android/tv/ui/activity/WebActivity.java#L171-L207
[F9]: https://github.com/FongMi/TV/blob/e7e7dd06250ca53da3c594ca4f6befc02e56b1d1/app/src/main/java/com/fongmi/android/tv/App.java#L87-L93
[F10]: https://github.com/FongMi/TV/blob/e7e7dd06250ca53da3c594ca4f6befc02e56b1d1/app/src/main/java/com/fongmi/android/tv/api/loader/JsHost.java#L19-L54
[C1]: https://github.com/FongMi/CatVodSpider/blob/ab5b0057ed041058ea815954b7e682fd7e07179e/docs/development.md#L432-L498
[C2]: https://github.com/FongMi/CatVodSpider/blob/ab5b0057ed041058ea815954b7e682fd7e07179e/app/src/main/java/com/github/catvod/spider/Demo.java#L267-L625
[C3]: https://github.com/FongMi/CatVodSpider/blob/ab5b0057ed041058ea815954b7e682fd7e07179e/app/src/main/java/com/github/catvod/spider/Market.java#L54-L99
[C4]: https://github.com/FongMi/CatVodSpider/blob/ab5b0057ed041058ea815954b7e682fd7e07179e/app/src/main/java/com/github/catvod/utils/Response.java#L25-L34
[C5]: https://github.com/FongMi/CatVodSpider/blob/ab5b0057ed041058ea815954b7e682fd7e07179e/docs/development.md#L215-L220

[W11]: https://github.com/webhtv/webhtv/blob/4e30ffaf219b1db15fe5662aeff6f9820e2b32bf/app/src/main/java/com/fongmi/android/tv/bean/Cate.java#L10-L36
[W12]: https://github.com/webhtv/webhtv/blob/4e30ffaf219b1db15fe5662aeff6f9820e2b32bf/app/src/leanback/java/com/fongmi/android/tv/ui/activity/HomeActivity.java#L615-L625
[F11]: https://github.com/FongMi/TV/blob/e7e7dd06250ca53da3c594ca4f6befc02e56b1d1/app/src/main/java/com/fongmi/android/tv/api/loader/JarLoader.java#L192-L204
