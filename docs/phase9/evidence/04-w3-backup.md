# 04 · W3 / P2-7 备份、恢复与数据重置

- 日期：2026-10-21
- 上游：`Updater.java`、`AutoBackupPolicy.java`（本轮只做本地备份/恢复/重置）
- 状态：**手动备份/恢复/重置完成；自动备份与应用更新未做**

## 1. 备份格式

单个 zip，固定三个条目：

```text
webhtv-backup-20261021-231500.zip
├─ manifest.json          # 格式/版本/时间/库版本/文件清单/SHA-256/统计
├─ settings.json          # UI/TMDB/AI/播放参数等偏好
└─ webhtv-pc.sqlite3      # VACUUM INTO 一致性快照
```

清单示例字段：`format=webhtv-pc-backup`、`version=1`、`databaseSchema=5`、
`entries[{path,size,sha256}]`、`stats{configs,history,favorites}`。

## 2. 安全与失败边界

- **校验在关闭数据库之前**：坏备份不会让当前会话先失去本地存储。
- 逐文件比对大小与 SHA-256；缺文件、重复条目、清单重复路径都拒绝。
- 路径白名单 + 安全路径判定（拒绝绝对路径、盘符、`..`、反斜杠）。
- 备份声明的库版本高于当前 `AppDatabase.schemaVersion` 时拒绝。
- 恢复写盘失败会用读到的旧设置/旧库回滚，然后重新 bootstrap。
- 重置前二次确认，删除设置与数据库（不含缓存/日志），回到未导入配置。
- 备份不含缓存和日志，避免把可再生成的体积与可能含敏感 URL 的日志带出去。

## 3. 变更清单

| 模块 | 文件 | 内容 |
| --- | --- | --- |
| 清单/校验 | `lib/core/backup_manifest.dart`（新） | 清单模型、严格 JSON 解析、路径安全、SHA-256、库版本门禁、默认文件名 |
| zip 服务 | `lib/services/backup_service.dart`（新） | 生成（`VACUUM INTO` 快照）、检查、取出待恢复内容；原子写；重复条目拒绝 |
| 数据库 | `lib/services/storage.dart` | `AppDatabase.backupTo`（`VACUUM INTO`） |
| 状态编排 | `lib/state/app_state.dart` | `createBackup/inspectBackup/restoreBackup/resetAllData`；数据交换前清理旧库/旧配置引用，恢复后重新 bootstrap 并重建广告规则/直连站源 |
| 入口 | `lib/ui/backup_page.dart`（新）、`lib/ui/advanced_settings_page.dart` | 路径输入、立即备份、检查、恢复、重置；高级设置入口 `settings-backup-open` |
| 依赖 | `pubspec.yaml` | `archive: ^4.3.0`（此前已由测试链传递，现显式声明） |

## 4. 测试

`test/phase9_backup_test.dart`：9 用例全部通过。

- 路径安全（绝对/盘符/`..`/反斜杠）；
- 清单往返、脏 JSON、重复路径、不安全路径；
- 校验通过/篡改/缺文件/未来库版本；
- 真实 SQLite：备份 → 检查 → 改坏当前数据（换配置 + 删历史）→ 恢复，
  配置名与历史条数回到备份时；
- 坏备份（篡改数据库字节）恢复失败且**当前数据不变**；
- 重置后 `config == null`、历史为空、可重新导入配置；
- 备份页渲染四个入口，默认路径含时间戳。

回归：

```text
phase8_settings_entries_test  → 9 用例通过（新增 settings-backup-open 断言）
dart analyze                  → No issues found
phase9_* 全量                 → 197 用例通过（本轮新增 9）
```

## 5. 未做（明确披露）

- **自动备份**：需要后台调度、保留份数、失败重试与磁盘配额策略；
  没有这些就只是一个「每次启动都写一份」的隐性能耗，未做。
- **应用更新**：需要签名通道与下载校验（ADR），未做。
- 备份不含缓存/日志；恢复后需要重建的运行时资源（猫源 sidecar、直连站源）
  已在 `_afterDataSwap()` 中按新配置重建。

## 6. 顺带修复：P1-9 出站代理丢掉测试注入客户端

跑 `phase2_startup_home_test` 时发现两条既有用例失败（冷启动/幂等）。
根因不是备份，而是 P1-9：`bootstrap()` 里的 `_applyOutboundProxy()` 无条件
`close()` 并重建 `_httpClient`，把构造时注入的捕获客户端换成了真实
`HttpClient`；widget 测试里框架把它固定返回 400，于是首页永远失败。

修复：保存 `_injectedHttpClient`；出站代理**未生效**时保留注入客户端
（且不 `close()`），只有代理生效时才按代理设置重建。两条既有用例恢复全绿。
这条修复不改变生产路径（生产不注入客户端）。
