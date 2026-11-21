/// PC 推送页（安卓 `app/src/main/assets/index.html` 的「推送」面板 + 剧名一栏）。
///
/// 为什么内联成字符串而不是资源文件：整页只有两栏，走 `pubspec` 资源会让
/// "换一次设备名"变成重新打包；这里按请求渲染，页面**不引用任何外部资源**
/// （局域网里的手机可能没有外网，引用 CDN 会白屏）。
///
/// 与安卓的差异只有一处：安卓的推送面板只有「播放网址」一栏，剧名要写成
/// `地址|剧名`；这里给剧名单独一栏，方便直接填。
library;

/// 渲染推送页 HTML。
///
/// [deviceName] 是 PC 在局域网里的名字（`SyncState.deviceName`），只做展示，
/// 必须转义后再插入。
String buildPushPage({required String deviceName}) =>
    _pushPageTemplate.replaceAll('%DEVICE%', _escapeHtml(deviceName));

/// 页面模板（raw string：`$` 与反斜杠原样保留给 HTML/JS）。
const String _pushPageTemplate = r'''<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>推送播放 · WebHTV PC</title>
<style>
  :root { color-scheme: dark; }
  * { box-sizing: border-box; }
  body { margin: 0; min-height: 100vh; display: flex; align-items: center; justify-content: center;
         background: #101216; color: #e8eaed;
         font-family: system-ui, -apple-system, "Noto Sans SC", "PingFang SC", "Microsoft YaHei", sans-serif; }
  main { width: min(92vw, 460px); padding: 28px; border-radius: 14px; background: #181b21;
         border: 1px solid #262b33; }
  h1 { font-size: 18px; margin: 0 0 6px; }
  p.hint { margin: 0 0 18px; font-size: 12px; line-height: 1.7; color: #9aa3af; }
  label { display: block; font-size: 12px; color: #9aa3af; margin: 14px 0 6px; }
  input { width: 100%; padding: 11px 12px; border-radius: 10px; border: 1px solid #2c323c;
          background: #101216; color: #e8eaed; font-size: 15px; }
  input:focus { outline: 2px solid #6ea8fe; outline-offset: 1px; border-color: #6ea8fe; }
  button { width: 100%; margin-top: 18px; padding: 12px; border: 0; border-radius: 10px;
           background: #6ea8fe; color: #0b1020; font-size: 15px; font-weight: 600; cursor: pointer; }
  button:disabled { opacity: .6; cursor: default; }
  #status { margin-top: 14px; font-size: 13px; min-height: 18px; color: #9aa3af; }
  #status.ok { color: #6ee7a8; }
  #status.err { color: #ff9f9f; }
</style>
</head>
<body>
<main>
  <h1>推送到 %DEVICE%</h1>
  <p class="hint">填写播放地址即可在 PC 上直接播放。剧名可选：填了 PC 会用它匹配元数据（海报、剧集信息），不填就用地址里的文件名。已开启「接收推送」才可用。</p>
  <form id="push-form">
    <label for="url">播放地址</label>
    <input id="url" name="url" type="text" inputmode="url" autocomplete="off" autocapitalize="off"
           placeholder="http://… / magnet:… / D:/视频/剧集.mkv" required>
    <label for="title">剧名（可选）</label>
    <input id="title" name="title" type="text" autocomplete="off" placeholder="例如：庆余年 第二季">
    <button id="submit" type="submit">推送到 PC</button>
  </form>
  <div id="status" role="status"></div>
</main>
<script>
  var form = document.getElementById('push-form');
  var status = document.getElementById('status');
  var submit = document.getElementById('submit');
  function say(text, kind) {
    status.textContent = text;
    status.className = kind || '';
  }
  form.addEventListener('submit', async function (event) {
    event.preventDefault();
    var url = document.getElementById('url').value.trim();
    var title = document.getElementById('title').value.trim();
    if (!url) { say('请填写播放地址', 'err'); return; }
    submit.disabled = true;
    say('正在推送…');
    try {
      var body = new URLSearchParams();
      body.set('url', url);
      body.set('title', title);
      var response = await fetch('/action?do=push', { method: 'POST', body: body });
      var text = (await response.text()).trim();
      if (response.ok) say('已推送，PC 正在播放', 'ok');
      else say('推送失败：' + (text || ('HTTP ' + response.status)), 'err');
    } catch (error) {
      say('推送失败：' + error, 'err');
    } finally {
      submit.disabled = false;
    }
  });
</script>
</body>
</html>
''';

String _escapeHtml(String value) => value
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#39;');
