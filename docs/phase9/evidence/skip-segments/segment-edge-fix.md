# 半像素边缘的双色叠色修复

## 为什么上一轮仍能看见双色

当前运行包的`libapp.so`时间晚于上一轮overlay修改，不能归因旧包。上一轮将原生已播轨道高度统一为3px，去掉了整数几何的上下突出部分，但原生轨道仍先绘在片段色下面。轨道位于半像素边界时，分类色的抗锯齿像素会与下方琥珀已播/蓝色缓存合成，因此中心像素虽然是分类色，边缘仍混入第二种颜色。

新的确定性回归保持片段和背景不变，只把底层已播色从主题primary换为magenta；如果片段真正优先，片段边缘像素不应变化。修复前暗/亮在1×、1.25×、1.5×共6项失败，2×整数边界原本就通过。这个反馈比只检查中心与完全落在轨外的相邻行更精确。

## 实现

绘制原生轨道前，先在局部canvas scope中排除所有可见片段的水平区间，使该处没有已播/缓存底层像素；原生绘制后恢复scope，再按原轨道几何填充分类色。片段分类色边缘只与视频/界面背景合成，不再与另一种轨道色混合。

clip仅包围原生track paint，滑块由框架随后单独绘制，视频、轨道命中、悬停、缩略图及拖动不受影响。隐藏高亮时segments为空，原生绘制完全原样；颜色自定义和处理过片段逻辑未变。

## 证据

- 暗色：[Before](segment-edge-dark-before.png) / [After](segment-edge-dark-after.png)
- 亮色：[Before](segment-edge-light-before.png) / [After](segment-edge-light-after.png)

同fixture、1000×320、同主题；Before临时恢复本次修改前的绘制后取证，随后finally逐字恢复生产文件并捕获After，未覆写此前历史图。

新增16个暗/亮 × LTR/RTL × 1/1.25/1.5/2倍光栅比对边缘全部受影响行，另覆盖缓存进入片段前后的像素不变。旧的隐藏整图native一致、用户RGB、区间外buffer/thumb、上下轨外无残条、RTL/边界/hover/拖动断言均保留。

Lead独立相关6文件150项通过；独立只读审查timeline60项通过，无具体发现。运行测试shape为MeasuredTrack（继承RoundedRectSliderTrackShape）；Gapped/第三方只完成静态契约核查，不声称已有runtime像素覆盖。未声称真外部影视解码验证。
