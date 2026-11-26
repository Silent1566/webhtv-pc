# 同轨片段高亮、显示开关与跳片尾连播

## 用户可见变化

- 片段色彩直接绘制在原进度轨道的相应区间内，与已播/缓存共用同一位置与高度，不再画上方窄条。正常可读颜色平涂完整轨高，低对比颜色只加最小轨内端点；自定义RGB不变，滑块、拖动和区间外缓存显示保持原样。
- 右键「跳过片段」和对应设置页均有「显示片段高亮」开关，默认开启并持久化。关闭仅隐藏颜色，不关闭识别、悬停、自动跳过，也不清空自定义颜色。
- 片尾跳过落点为文件末尾时，应用直接作为本集完成处理，复用自动连播/循环/季边界/聚合/队列策略。不再重开当前视频到精确duration后等待EOF。有限片尾段后面仍有彩蛋/正片时，只跳段末。

## 原片尾不连播原因

旧路径一律将片段目标交给安全seek。目标在buffer外时重开当前URL到总时长；重开又清除了短时skip-seek因果标记，而且HLS不保证在精确末尾打开后再给一个可用EOF。日志里因此可以有“跳过片尾/重开至duration/播放成功”，却没有下一集。现在明确的文件末尾完成意图直接进入既有完成裁决，不依赖EOF或5秒墙钟窗口。普通用户拖动/seek仍走原伪结束保护，不因这个新通道误连播。

## 真实动作与副作用验证

隔离PlayerPage回归中观察到：

```text
opens=[skip.mp4,next.mp4]
starts=[null,null]
seeks=[]
```

下一集实际打开一次，没有当前流duration重开，不需要人为completed=true。矩阵覆盖关闭autoNext、末集/无剧集、单集与列表循环、确认接受/拒绝、慢下一集超过5秒、重复事件、下一集失败、有限片尾、季边界、聚合集数与文件队列。

审查修复的完成责任：

- 跳到文件末尾时，通过原writer把旧集历史按总时长记为完成；旧timer、transition、dispose不会覆回片尾起点。新集按新代际记录实际位置。真实DB断言旧集1000000/1000000，新集实际500000/1000000。
- 用户回拖或重新播放解除完成位置覆盖。重新播放测试先唤醒控制栏，命中真实按钮并观察Media/Player playing与暂停UI，在未注入新位置时先读回805000，之后仅位置700事件读回700000；不是用人工playing=true替代按钮。
- 「本集结束后关闭」在next/repeat/queue分流前优先停止，清除计划；显式跳片尾和自然EOF均覆盖，重复通知不会继续前进。

## 视觉证据

同fixture、1000×320、同主题：

- 暗色：[Before](track-overlay-dark-before.png) / [After](track-overlay-dark-after.png)
- 亮色：[Before](track-overlay-light-before.png) / [After](track-overlay-light-after.png)
- 新增开关，900×1100：[暗色After](highlight-toggle-dark-after.png) / [亮色After](highlight-toggle-light-after.png)。新增开关无可靠Before。

真实RepaintBoundary光栅结果已检查；像素测试覆盖整轨RGB、无上方残留、隐藏后与无片段native整图一致、RTL/端点/时长边界、thumb和未标记buffer区域、关闭颜色仍有悬停/缩略图。

## 最终验证与范围

Lead独立顺序验证：播放与完成338项、轨道/可见性/颜色/设置114项、视觉2项，合计454项通过；全包 `dart analyze --fatal-infos .` 无问题，`git diff --check` 通过。独立审查最终outro矩阵26/26通过，输出无hit-test miss/异常；所有T1/T2/T3发现均已修复。

媒体输入、网络标定和数据库均为隔离fixture，实际生产页面/策略/数据库writer运行；不声称真外部影视或mpv解码E2E。季度进度确认共用writer的完成位置/身份输入，未额外独立查询season表，不将此写成独立实测。

本轮只改工作区代码与证据，未修改用户配置/数据库、未提交、未重建或替换已运行应用。
