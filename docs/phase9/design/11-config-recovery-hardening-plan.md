# Configuration recovery hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development. Read the named task brief and spec first.

**Goal:** 防止测试污染真实数据，失效本地来源明确提示并保留缓存。
**Architecture:** Fan-out A路径/写闸、B来源状态+AppState、C界面提示。文件不重叠；B冻结service/getter/dismiss接口，C据此实现，A/B集成在最终编译回归检查。
**Tech Stack:** Existing Flutter/Dart/filesystem/SQLite, no dependencies.
**Spec:** docs/phase9/design/11-config-recovery-hardening.md

## Global Constraints
只改dev3；保留观影报告；不提交推送；不写正式profile；零网络来源健康探测；不删缓存历史、不自动换配置；所有测试独立HOME/XDG。

## Tasks
- [ ] A (run 0/3): 原roaming/local POSIX回落 red -> 同构修复 green；FLUTTER_TEST不隔离时ensureDirectories第一IO fail-closed，测试零真实目录写入。boundary app_paths + two path tests。
- [ ] B (run 0/3): 缓存恢复失效本地file red -> service与AppState固定接口green；异步来源隔离与关闭/切换/刷新清警告。
- [ ] C (run 0/3): Before截图 -> 失效来源列表+startup警告+动作UI red -> newviews green -> 同scenario After/窄屏视觉证据。
- [ ] Lead independent acceptance: 读difffs、复跑隔离test、查看Before/After、检查真实profile指纹未变化、analyze、记录风险和交付显式worktree构建命令。

## Contract preflight
|Pair|Producer vs consumer|Verdict|
|---|---|---|
|A↔B|B bootstrap原await ensureDirectories，A失败闭锁必须传播并终止任何profile IO|无接口改动|
|B↔C|inspectConfigSource、ConfigSourceStatus字段、restored getter/dismiss完全固定|兼容，C不stub B|
|A↔C|C测试完整显式override与外层fakeHOME/XDG|符合安全约束|
|A|四目录默认生产行为不变，guard仅第一次test IO|自洽|
|B|保留cache/历史，晚结果不跨配置|自洽|
|C|异步提示不禁用缓存切换，no redesign|自洽|
