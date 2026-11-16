/// LUT 选择面板：播放中打开，选完即回传（docs/phase9/design/01 §6）。
///
/// 内容全部来自 LutPresetBrowser；本文件只负责「底部面板 + 回传结果」。
/// 为什么播放中还需要面板而不是直接用设置页：面板**不换路由**，
/// 视频一直在背后播，选完立刻能看到效果；设置页要 push 一层。
library;

import 'package:flutter/material.dart';

import '../core/lut.dart';
import '../services/lut_store.dart';
import 'lut_preset_browser.dart';

/// 面板返回给播放页的结果。
class LutPickerResult {
  const LutPickerResult.select(this.preset) : cleared = false;

  const LutPickerResult.clear() : preset = null, cleared = true;

  final LutPreset? preset;

  /// true 表示用户点了「清除 LUT」。
  final bool cleared;
}

/// 选择面板。
class LutPickerSheet extends StatelessWidget {
  const LutPickerSheet({
    super.key,
    required this.store,
    required this.currentPath,
    required this.currentPresetId,
    this.pickFile,
  });

  final LutStore store;
  final String currentPath;
  final String currentPresetId;
  final Future<String?> Function()? pickFile;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 560),
        child: SingleChildScrollView(
          child: LutPresetBrowser(
            store: store,
            currentPath: currentPath,
            currentPresetId: currentPresetId,
            pickFile: pickFile,
            onSelect: (preset) =>
                Navigator.of(context).pop(LutPickerResult.select(preset)),
            onCleared: () =>
                Navigator.of(context).pop(const LutPickerResult.clear()),
          ),
        ),
      ),
    );
  }
}
