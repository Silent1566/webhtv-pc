/// 字幕源适配（`docs/phase9/design/02` §1、`docs/superpowers/plans/2026-11-15-subtitle-online-search.md`）。
///
/// 目录结构：
/// - `subtitle_providers/provider.dart`：抽象契约（search + resolve）；
/// - `local_provider.dart` / `http_provider.dart`：Phase 9 已有的两个源；
/// - `assrt_provider.dart` / `xunlei_provider.dart` / `shooter_provider.dart`：内置源；
/// - `registry.dart`：按设置装配、并行搜索、失败脱敏。
///
/// 本文件是 barrel：外部（含既有测试）继续 `import 'services/subtitle_providers.dart'`。
library;

export 'subtitle_providers/assrt_provider.dart';
export 'subtitle_providers/http_provider.dart';
export 'subtitle_providers/local_provider.dart';
export 'subtitle_providers/provider.dart';
export 'subtitle_providers/registry.dart';
export 'subtitle_providers/shooter_provider.dart';
export 'subtitle_providers/xunlei_provider.dart';
