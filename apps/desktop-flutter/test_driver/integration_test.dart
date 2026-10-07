/// `flutter drive` 的标准 integration_test 驱动。
///
/// 用途：`flutter test` 没有 `--release` 开关，Windows 桌面端要做
/// **AOT（Release）** 集成验证只能走 `flutter drive`：
///
/// ```powershell
/// flutter drive `
///   --driver=test_driver/integration_test.dart `
///   --target=integration_test/tmdb_detail_flow_test.dart `
///   -d windows --release
/// ```
///
/// 该驱动只负责把设备端 `integration_test` 的结果回传，不包含任何断言逻辑。
library;

import 'package:integration_test/integration_test_driver.dart';

Future<void> main() => integrationDriver();
