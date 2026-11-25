/// Android 执行绑定存储：版本 1 JSON、每个原配置源一个选中环境、串行化的原子提交。
library;

import 'dart:convert';
import 'dart:io';

import '../core/android_config_execution.dart';
import '../core/app_error.dart';
import 'log_service.dart';

/// 文件格式版本。未来版本按「没有记录」处理，不猜新语义。
const int androidConfigExecutionStoreVersion = 1;

class AndroidConfigExecutionStore {
  AndroidConfigExecutionStore({required this.path, required this.log});

  /// 由调用方按 AppPaths 拼好；存储层不猜目录。
  final String path;
  final LogService log;

  List<AndroidConfigExecutionBinding> _bindings = const [];
  Map<String, String> _selections = const {};

  /// 磁盘上的全部绑定（顺序稳定，重复 key 已去重）。
  List<AndroidConfigExecutionBinding> get bindings => _bindings;

  AndroidConfigExecutionBinding? forSourceProfile(
    String sourceKey,
    String profileConnectionKey,
  ) {
    for (final binding in _bindings) {
      if (binding.sourceKey == sourceKey &&
          binding.profileConnectionKey == profileConnectionKey) {
        return binding;
      }
    }
    return null;
  }

  /// 该原配置源当前选中的可执行绑定；未选择、pending 或记录缺失都为 null。
  AndroidConfigExecutionBinding? enabledFor(String sourceKey) {
    final profileConnectionKey = _selections[sourceKey];
    if (profileConnectionKey == null) return null;
    final binding = forSourceProfile(sourceKey, profileConnectionKey);
    if (binding == null || !binding.isReady) return null;
    return binding;
  }

  /// 该 Android 环境已占用的 guest 端口；同一环境跨原配置源必须一致。
  int? guestPortForProfile(String profileConnectionKey) {
    for (final binding in _bindings) {
      if (binding.profileConnectionKey == profileConnectionKey) {
        return binding.guestPort;
      }
    }
    return null;
  }

  /// 读取磁盘状态；缺失、损坏、版本不认识、单条坏记录都不抛进启动流程。
  Future<void> load() async {
    try {
      final file = File(path);
      if (!file.existsSync()) {
        _bindings = const [];
        _selections = const {};
        return;
      }
      final decoded = jsonDecode(file.readAsStringSync());
      if (decoded is! Map ||
          decoded['version'] != androidConfigExecutionStoreVersion) {
        log.warning('Android 执行绑定版本不认识（按没有记录处理）', scope: 'android');
        _bindings = const [];
        _selections = const {};
        return;
      }

      final kept = <AndroidConfigExecutionBinding>[];
      final byKey = <String, AndroidConfigExecutionBinding>{};
      var dropped = 0;
      final rawBindings = decoded['bindings'];
      if (rawBindings is List) {
        for (final item in rawBindings) {
          final binding = AndroidConfigExecutionBinding.fromJson(item);
          if (binding == null) {
            dropped++;
            continue;
          }
          final conflict = kept.any(
            (existing) =>
                existing.profileConnectionKey == binding.profileConnectionKey &&
                existing.guestPort != binding.guestPort,
          );
          if (conflict) {
            dropped++;
            continue;
          }
          final previous = byKey[binding.bindingKey];
          if (previous != null) {
            kept.removeWhere((item) => item.bindingKey == binding.bindingKey);
          }
          byKey[binding.bindingKey] = binding;
          kept.add(binding);
        }
      } else if (rawBindings != null) {
        dropped++;
      }

      final selections = <String, String>{};
      final rawSelections = decoded['selections'];
      if (rawSelections is Map) {
        for (final entry in rawSelections.entries) {
          final sourceKey = entry.key;
          final profileConnectionKey = entry.value;
          if (sourceKey is! String || profileConnectionKey is! String) {
            dropped++;
            continue;
          }
          AndroidConfigExecutionBinding? binding;
          for (final candidate in kept) {
            if (candidate.sourceKey == sourceKey &&
                candidate.profileConnectionKey == profileConnectionKey) {
              binding = candidate;
              break;
            }
          }
          if (binding == null || !binding.isReady) {
            dropped++;
            continue;
          }
          selections[sourceKey] = profileConnectionKey;
        }
      } else if (rawSelections != null) {
        dropped++;
      }

      _bindings = List.unmodifiable(kept);
      _selections = Map.unmodifiable(selections);
      if (dropped > 0) {
        log.warning(
          'Android 执行绑定有 $dropped 条无法识别（已丢弃，其余照常读取）',
          scope: 'android',
        );
      }
    } catch (_) {
      log.warning('读取 Android 执行绑定失败（按没有记录处理）', scope: 'android');
      _bindings = const [];
      _selections = const {};
    }
  }

  /// 写入串行化：提交顺序等于内存顺序，一次失败不会进入后续调用者的结果。
  Future<void> _writeTail = Future<void>.value();

  Future<void> _mutate(Future<void> Function() action) {
    final result = _writeTail.then((_) => action());
    // 链上只记录「已结束」，不记录失败：上一个调用者的错误不污染下一个。
    _writeTail = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  /// 写入或更新一条绑定；同一 (sourceKey, profileConnectionKey) 覆盖。
  ///
  /// [enable] 只对同一原配置源生效：新选中会替换旧选中，但**不会删除**旧绑定。
  Future<void> putBinding(
    AndroidConfigExecutionBinding binding, {
    bool enable = false,
  }) => _mutate(() async {
    _requireValidBinding(binding);
    final existingPort = guestPortForProfile(binding.profileConnectionKey);
    if (existingPort != null && existingPort != binding.guestPort) {
      throw AppError(
        AppErrorKind.storage,
        '同一 Android 环境不能使用两个转发端口',
        detail: 'profile=${binding.profileConnectionKey}',
      );
    }
    if (enable && !binding.isReady) {
      throw AppError(
        AppErrorKind.storage,
        'Android 执行绑定尚未就绪，不能启用',
        detail: 'source=${binding.sourceKey}',
      );
    }

    final next = List<AndroidConfigExecutionBinding>.of(_bindings);
    final index = next.indexWhere(
      (item) => item.bindingKey == binding.bindingKey,
    );
    if (index >= 0) {
      next[index] = binding;
    } else {
      next.add(binding);
    }
    final nextSelections = Map<String, String>.of(_selections);
    if (enable) {
      nextSelections[binding.sourceKey] = binding.profileConnectionKey;
    }
    await _commit(next, nextSelections);
    _bindings = List.unmodifiable(next);
    _selections = Map.unmodifiable(nextSelections);
  });

  /// 关闭原配置源的 Android 执行；绑定、token 与端口保留给下次复用。
  Future<void> disable(String sourceKey) => _mutate(() async {
    if (!_selections.containsKey(sourceKey)) return;
    final nextSelections = Map<String, String>.of(_selections)
      ..remove(sourceKey);
    await _commit(_bindings, nextSelections);
    _selections = Map.unmodifiable(nextSelections);
  });

  /// 删除一条绑定；如果它正被选中，同时清除选择。
  Future<void> forget(String sourceKey, String profileConnectionKey) =>
      _mutate(() async {
        final next = [
          for (final binding in _bindings)
            if (!(binding.sourceKey == sourceKey &&
                binding.profileConnectionKey == profileConnectionKey))
              binding,
        ];
        if (next.length == _bindings.length) return;
        final nextSelections = Map<String, String>.of(_selections);
        if (nextSelections[sourceKey] == profileConnectionKey) {
          nextSelections.remove(sourceKey);
        }
        await _commit(next, nextSelections);
        _bindings = List.unmodifiable(next);
        _selections = Map.unmodifiable(nextSelections);
      });

  Future<void> _commit(
    List<AndroidConfigExecutionBinding> bindings,
    Map<String, String> selections,
  ) async {
    final temp = File('$path.tmp');
    try {
      File(path).parent.createSync(recursive: true);
      temp.writeAsStringSync(
        jsonEncode({
          'version': androidConfigExecutionStoreVersion,
          'bindings': [for (final binding in bindings) binding.toJson()],
          'selections': selections,
        }),
        flush: true,
      );
      // 同一目录内一次 rename：覆盖旧文件，绝不先删旧文件。
      temp.renameSync(path);
    } catch (error) {
      log.warning('写入 Android 执行绑定失败（旧文件与内存保持不变）', scope: 'android');
      try {
        if (temp.existsSync()) temp.deleteSync();
      } catch (_) {}
      throw AppError(
        AppErrorKind.storage,
        '保存 Android 执行绑定失败',
        detail: '版本 1 绑定未提交',
        cause: error,
      );
    }
  }

  void _requireValidBinding(AndroidConfigExecutionBinding binding) {
    if (binding.sourceKey.trim().isEmpty ||
        binding.profileConnectionKey.trim().isEmpty ||
        binding.deviceUuid.trim().isEmpty ||
        !isValidAndroidConfigHash(binding.configHash) ||
        !isValidAndroidSnapshotToken(binding.snapshotToken) ||
        binding.guestPort < 1 ||
        binding.guestPort > 65535) {
      throw AppError(
        AppErrorKind.storage,
        'Android 执行绑定字段不合法',
        detail: 'source=${binding.sourceKey}',
      );
    }
  }
}
