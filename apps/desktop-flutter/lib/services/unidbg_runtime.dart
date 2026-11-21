/// unidbg 0.9.9 运行时按需获取（下载 / 校验 / 安装 / 卸载 / 状态查询）。
///
/// 加固壳解包要跑 unidbg 0.9.9 + ASM 等 18 个 Maven 包（约 39MB）。运行时
/// **不随仓库与安装包分发**：首次 [UnidbgRuntime.install] 时才按需下载，落盘后
/// 逐个校验 SHA-256；文件名、字节数、摘要全部 pin 在本文件里（信任锚）。
///
/// 目录：<应用数据根>/runtime/unidbg-0.9.9/，与既有 runtime/python/... 同级
/// （同一个 AppPaths.resolve 数据根，Windows 上即 %LOCALAPPDATA%/webhtv-pc），
/// 但目录、下载与校验逻辑与 Python 运行时完全解耦，不共享任何状态。
library;

import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import 'app_paths.dart';
import 'log_service.dart';

/// 运行时目录状态。
class UnidbgRuntimeStatus {
  const UnidbgRuntimeStatus({
    required this.installed,
    required this.dir,
    required this.bytes,
    required this.missing,
  });

  /// 18 个 jar 全部到位（存在且字节数与 pin 一致）。
  final bool installed;

  /// 运行时目录绝对路径。
  final String dir;

  /// 已到位的 jar 占用字节数。
  final int bytes;

  /// 缺失或字节数不符的文件名（不含目录）。
  final List<String> missing;
}

/// 安装进度（[UnidbgRuntime.install] 的 onProgress 入参）。
class UnidbgRuntimeProgress {
  const UnidbgRuntimeProgress({
    required this.fileIndex,
    required this.fileCount,
    required this.file,
    required this.bytesDone,
    required this.bytesTotal,
  });

  /// 当前文件序号，**从 1 开始**。
  final int fileIndex;

  /// 本次需要下载的文件数（幂等安装时小于 18）。
  final int fileCount;

  /// 当前文件名。
  final String file;

  /// 已下载并校验通过的字节数。
  final int bytesDone;

  /// 本次需要下载的总字节数。
  final int bytesTotal;
}

/// 安装结果。[error] 非空即失败（[UnidbgRuntime.install] 永不抛异常）。
class UnidbgRuntimeInstall {
  const UnidbgRuntimeInstall({
    required this.installed,
    required this.dir,
    required this.bytes,
    this.error,
  });

  final bool installed;
  final String dir;
  final int bytes;
  final String? error;
}

/// 单个 jar 的信任锚：Maven 相对路径 + 文件名 + 字节数 + SHA-256。
class UnidbgJarPin {
  const UnidbgJarPin({
    required this.path,
    required this.fileName,
    required this.bytes,
    required this.sha256,
  });

  /// Maven 相对路径（group/artifact/version/file），只用来拼镜像 URL。
  final String path;

  /// 落盘短名 artifact-version.jar。
  final String fileName;

  /// 期望字节数。
  final int bytes;

  /// 小写十六进制 SHA-256。
  final String sha256;
}

/// 默认应用数据根（生产环境）；测试通过 dirProvider 覆盖。
Directory _defaultRootDir() => Directory(AppPaths.resolve().dataDir);

/// 镜像顺序：阿里云 -> 华为云 -> 腾讯云 -> repo1，逐文件回退。
const List<String> _mirrorBases = <String>[
  'https://maven.aliyun.com/repository/public/',
  'https://mirrors.huaweicloud.com/repository/maven/',
  'https://mirrors.cloud.tencent.com/nexus/repository/maven-public/',
  'https://repo1.maven.org/maven2/',
];

/// 18 个 jar 的信任锚（2026-11 由 Get-FileHash -Algorithm SHA256 实盘算得）。
const List<UnidbgJarPin> _pinnedJars = <UnidbgJarPin>[
  UnidbgJarPin(
    path: 'com/github/zhkl0228/unidbg-android/0.9.9/unidbg-android-0.9.9.jar',
    fileName: 'unidbg-android-0.9.9.jar',
    bytes: 6128061,
    sha256: 'ce52ddda7772ac79adb4606dbaf0a65c53c41af96e73299a98eadec608f270fc',
  ),
  UnidbgJarPin(
    path: 'com/github/zhkl0228/unidbg-api/0.9.9/unidbg-api-0.9.9.jar',
    fileName: 'unidbg-api-0.9.9.jar',
    bytes: 418830,
    sha256: '422a2d93c4f22de8436867415fc34bdacbdc62de351b828a0672651344c46efe',
  ),
  UnidbgJarPin(
    path: 'com/github/zhkl0228/unidbg-unicorn2/0.9.9/unidbg-unicorn2-0.9.9.jar',
    fileName: 'unidbg-unicorn2-0.9.9.jar',
    bytes: 6150256,
    sha256: '6c258e54e99da8a4e3ba4a705c5f78bcb658638ef16682ad1d3bc25953908ffb',
  ),
  UnidbgJarPin(
    path: 'com/github/zhkl0228/unidbg-dynarmic/0.9.9/unidbg-dynarmic-0.9.9.jar',
    fileName: 'unidbg-dynarmic-0.9.9.jar',
    bytes: 8217374,
    sha256: 'd1decada24040ae543c7cd1182c87433b4a8e9700162e7129f18937b4f3edbb9',
  ),
  UnidbgJarPin(
    path: 'com/github/zhkl0228/unicorn/1.0.15/unicorn-1.0.15.jar',
    fileName: 'unicorn-1.0.15.jar',
    bytes: 6193524,
    sha256: '7fbce2a0decf475b75b355cf33301349bf7c88f31cd93c7922e9dbbed3debf23',
  ),
  UnidbgJarPin(
    path: 'com/github/zhkl0228/capstone/3.1.8/capstone-3.1.8.jar',
    fileName: 'capstone-3.1.8.jar',
    bytes: 3159591,
    sha256: '920e5fd1d514f146891a82cfbbfb33ef20cfca746ddcd1a6e2b54fff2a2e53dc',
  ),
  UnidbgJarPin(
    path: 'com/github/zhkl0228/keystone/0.9.7/keystone-0.9.7.jar',
    fileName: 'keystone-0.9.7.jar',
    bytes: 4731494,
    sha256: '3db2ee22fa5b3a70800bc5dfb515acf6bcb62888be0da43c311ff8304411558b',
  ),
  UnidbgJarPin(
    path: 'com/github/zhkl0228/demumble/1.0.4/demumble-1.0.4.jar',
    fileName: 'demumble-1.0.4.jar',
    bytes: 968653,
    sha256: '2351bff06a0a494734924f4fa2e7084c0699d7e959a0be6e85e7d9ee17ae6eb6',
  ),
  UnidbgJarPin(
    path: 'commons-codec/commons-codec/1.21.0/commons-codec-1.21.0.jar',
    fileName: 'commons-codec-1.21.0.jar',
    bytes: 402494,
    sha256: '4da851cb6abfb98bfe9eb77c5e5fc47f5414fa28b94e21b7fd9a646705dc167f',
  ),
  UnidbgJarPin(
    path: 'org/apache/commons/commons-collections4/4.5.0/commons-collections4-4.5.0.jar',
    fileName: 'commons-collections4-4.5.0.jar',
    bytes: 898652,
    sha256: '00f93263c267be201b8ae521b44a7137271b16688435340bf629db1bac0a5845',
  ),
  UnidbgJarPin(
    path: 'commons-io/commons-io/2.21.0/commons-io-2.21.0.jar',
    fileName: 'commons-io-2.21.0.jar',
    bytes: 585274,
    sha256: '7d643a2afea8b058b762aa6fb90e5b256f6c729739f8b3784c3370ddc609e88d',
  ),
  UnidbgJarPin(
    path: 'com/alibaba/fastjson/1.2.83/fastjson-1.2.83.jar',
    fileName: 'fastjson-1.2.83.jar',
    bytes: 671701,
    sha256: '641a4d65ab32fbfdccd9c718e3f83ebc4caabdb5e4fe5b3d51527c5fe692631d',
  ),
  UnidbgJarPin(
    path: 'net/dongliu/apk-parser/2.6.10/apk-parser-2.6.10.jar',
    fileName: 'apk-parser-2.6.10.jar',
    bytes: 213647,
    sha256: '4e07ef65005c0d7e7149f6e903828fdaa031f542ad3956f0d827197a5ccac640',
  ),
  UnidbgJarPin(
    path: 'net/java/dev/jna/jna/5.10.0/jna-5.10.0.jar',
    fileName: 'jna-5.10.0.jar',
    bytes: 1756400,
    sha256: 'e335c10679f743207d822c5f7948e930319835492575a9dba6b94f8a3b96fcc8',
  ),
  UnidbgJarPin(
    path: 'org/scijava/native-lib-loader/2.3.5/native-lib-loader-2.3.5.jar',
    fileName: 'native-lib-loader-2.3.5.jar',
    bytes: 20352,
    sha256: '7db19cf3e9cfe993e725e82cd9593a8f3e2d340ed3047c98d5c54370571c759d',
  ),
  UnidbgJarPin(
    path: 'org/slf4j/slf4j-api/2.0.16/slf4j-api-2.0.16.jar',
    fileName: 'slf4j-api-2.0.16.jar',
    bytes: 69435,
    sha256: 'a12578dde1ba00bd9b816d388a0b879928d00bab3c83c240f7013bf4196c579a',
  ),
  UnidbgJarPin(
    path: 'org/slf4j/slf4j-simple/2.0.16/slf4j-simple-2.0.16.jar',
    fileName: 'slf4j-simple-2.0.16.jar',
    bytes: 15704,
    sha256: 'effc32018658bea09d1e08c7d1060ccad46c086960f583d07dd7ffe9c1172a47',
  ),
  UnidbgJarPin(
    path: 'org/ow2/asm/asm/9.7/asm-9.7.jar',
    fileName: 'asm-9.7.jar',
    bytes: 125428,
    sha256: 'adf46d5e34940bdf148ecdd26a9ee8eea94496a72034ff7141066b3eea5c4e9d',
  ),
];

/// unidbg 0.9.9 运行时的按需获取入口。
///
/// 约束：
/// - [install] **永不抛异常**：失败用 [UnidbgRuntimeInstall.error] 返回；
/// - 同一时刻只允许一次 [install]：重复调用返回**同一个**进行中的 Future
///   （进度回调只对首个调用者生效），避免并行写同一批文件；
/// - 先写 .part，校验 SHA-256 通过后才 rename 成正式文件名，坏文件不落库。
class UnidbgRuntime {
  /// [dirProvider] 返回**应用数据根目录**（如 %LOCALAPPDATA%/webhtv-pc），
  /// 运行时目录解析为 `<root>/runtime/unidbg-0.9.9`；测试可指向临时目录。
  /// [pins] 仅供测试注入替身锚表，生产一律用内置的 18 条 pin。
  UnidbgRuntime({
    http.Client? client,
    Directory Function()? dirProvider,
    LogService? log,
    List<UnidbgJarPin>? pins,
  }) : _client = client ?? http.Client(),
       _dirProvider = dirProvider ?? _defaultRootDir,
       _log = log ?? LogService(scope: 'spider'),
       _pins = pins ?? _pinnedJars;

  static const String version = '0.9.9';
  static const String dirName = 'unidbg-0.9.9';

  /// 单文件下载超时。
  static const Duration _perFileTimeout = Duration(seconds: 300);

  /// 一次安装的下载总量上限 200MB（实际约 39MB，留足回退重试余量）。
  static const int _installCapBytes = 200 * 1024 * 1024;

  final http.Client _client;
  final Directory Function() _dirProvider;
  final LogService _log;
  final List<UnidbgJarPin> _pins;

  Future<UnidbgRuntimeInstall>? _inflight;
  UnidbgRuntimeStatus? _cached;

  /// `<应用数据根>/runtime/unidbg-0.9.9`（Windows 上即
  /// `%LOCALAPPDATA%/webhtv-pc/runtime/unidbg-0.9.9`）。
  String get dir {
    final base = _dirProvider().path;
    return p.join(base, 'runtime', dirName);
  }

  /// classpath 通配项 `<dir>/*`；Windows 下由调用方再拼 ';'。
  String get classpathWildcard => '$dir/*';

  /// 同步判断 18 个 jar 是否齐全（只看存在与字节数，不重算 SHA-256）。
  bool get isInstalledSync {
    final root = dir;
    for (final pin in _pins) {
      final file = File(p.join(root, pin.fileName));
      try {
        if (!file.existsSync() || file.lengthSync() != pin.bytes) return false;
      } on FileSystemException {
        return false;
      }
    }
    return true;
  }

  /// 目录状态。[refresh] 为 false 时返回上次扫描结果（安装/卸载会刷新缓存）。
  ///
  /// 只比对字节数不重算摘要：39MB 每次都算一遍会让状态查询变成秒级操作，
  /// 摘要校验只发生在下载落盘那一刻。
  Future<UnidbgRuntimeStatus> status({bool refresh = false}) async {
    final cached = _cached;
    if (!refresh && cached != null) return cached;
    final root = dir;
    final missing = <String>[];
    var bytes = 0;
    for (final pin in _pins) {
      final file = File(p.join(root, pin.fileName));
      var size = -1;
      try {
        if (await file.exists()) size = await file.length();
      } catch (_) {
        size = -1;
      }
      if (size == pin.bytes) {
        bytes += pin.bytes;
      } else {
        missing.add(pin.fileName);
      }
    }
    final result = UnidbgRuntimeStatus(
      installed: missing.isEmpty,
      dir: root,
      bytes: bytes,
      missing: List<String>.unmodifiable(missing),
    );
    _cached = result;
    return result;
  }

  /// 幂等安装：已有且校验通过的文件不动，只补缺失/损坏的。
  ///
  /// 并发：进行中再次调用直接返回同一个 Future（不排队、不重入）。
  Future<UnidbgRuntimeInstall> install({
    void Function(UnidbgRuntimeProgress)? onProgress,
  }) {
    final running = _inflight;
    if (running != null) return running;
    late final Future<UnidbgRuntimeInstall> future;
    future = _install(onProgress).whenComplete(() {
      if (identical(_inflight, future)) _inflight = null;
    });
    _inflight = future;
    return future;
  }

  /// 卸载：删除整个运行时目录（下载进行中则先等它结束）。失败只记日志。
  Future<void> remove() async {
    final running = _inflight;
    if (running != null) await running;
    final root = Directory(dir);
    try {
      final path = root.path;
      if (await root.exists()) await root.delete(recursive: true);
      _log.info('已卸载 unidbg $version 运行时（$path）');
    } catch (error) {
      _log.error('卸载 unidbg $version 运行时失败：$error');
    }
    _cached = null;
  }

  Future<UnidbgRuntimeInstall> _install(
    void Function(UnidbgRuntimeProgress)? onProgress,
  ) async {
    final root = dir;
    try {
      await Directory(root).create(recursive: true);

      final pending = <UnidbgJarPin>[];
      for (final pin in _pins) {
        final file = File(p.join(root, pin.fileName));
        if (await _verified(file, pin)) continue;
        await _deleteQuietly(file);
        pending.add(pin);
      }

      if (pending.isEmpty) {
        final bytes = await _bytesOnDisk(root);
        _log.info('unidbg $version 运行时已就位（$bytes 字节，$root）');
        return UnidbgRuntimeInstall(
          installed: true,
          dir: root,
          bytes: bytes,
          error: null,
        );
      }

      final need = pending.length;
      final total = _pins.length;
      _log.info('unidbg $version 运行时缺 $need/$total 个 jar，开始按需下载');
      final bytesTotal = pending.fold<int>(0, (sum, pin) => sum + pin.bytes);
      var bytesDone = 0;
      for (var index = 0; index < pending.length; index++) {
        final pin = pending[index];
        onProgress?.call(
          UnidbgRuntimeProgress(
            fileIndex: index + 1,
            fileCount: need,
            file: pin.fileName,
            bytesDone: bytesDone,
            bytesTotal: bytesTotal,
          ),
        );
        final fetched = await _download(pin, root, downloadedSoFar: bytesDone);
        final error = fetched.error;
        if (error != null) {
          _log.error('unidbg $version 运行时安装失败：$error');
          return UnidbgRuntimeInstall(
            installed: false,
            dir: root,
            bytes: await _bytesOnDisk(root),
            error: error,
          );
        }
        bytesDone += fetched.bytesWritten;
      }
      onProgress?.call(
        UnidbgRuntimeProgress(
          fileIndex: need,
          fileCount: need,
          file: pending.last.fileName,
          bytesDone: bytesDone,
          bytesTotal: bytesTotal,
        ),
      );

      final result = await status(refresh: true);
      if (!result.installed) {
        final count = result.missing.length;
        final names = result.missing.join('、');
        final error = '安装后仍缺 $count 个 jar：$names';
        _log.error('unidbg $version 运行时安装失败：$error');
        return UnidbgRuntimeInstall(
          installed: false,
          dir: root,
          bytes: result.bytes,
          error: error,
        );
      }
      final bytes = result.bytes;
      _log.info('unidbg $version 运行时安装完成（$bytes 字节，$root）');
      return UnidbgRuntimeInstall(
        installed: true,
        dir: root,
        bytes: bytes,
        error: null,
      );
    } catch (error) {
      final message = '运行时安装异常：$error';
      _log.error('unidbg $version 运行时安装失败：$message');
      return UnidbgRuntimeInstall(
        installed: false,
        dir: root,
        bytes: 0,
        error: message,
      );
    }
  }

  /// 逐镜像下载单个文件；每个镜像每个文件只试一次。
  Future<({int bytesWritten, String? error})> _download(
    UnidbgJarPin pin,
    String root, {
    required int downloadedSoFar,
  }) async {
    final name = pin.fileName;
    final expected = pin.sha256;
    final targetPath = p.join(root, name);
    final partPath = '$targetPath.part';
    var reason = '无可用镜像';
    for (final base in _mirrorBases) {
      final url = '$base${pin.path}';
      final host = _hostOf(url);
      http.Response response;
      try {
        response = await _client.get(Uri.parse(url)).timeout(_perFileTimeout);
      } on TimeoutException {
        reason = '$host 超时';
        _log.warning('unidbg jar 下载超时：$url');
        continue;
      } catch (error) {
        reason = '$host 请求失败（$error）';
        _log.warning('unidbg jar 下载失败：$url（$error）');
        continue;
      }
      final code = response.statusCode;
      if (code != 200) {
        reason = '$host HTTP $code';
        _log.warning('unidbg jar 下载返回 $code：$url');
        continue;
      }
      final body = response.bodyBytes;
      final length = body.length;
      if (downloadedSoFar + length > _installCapBytes) {
        return (bytesWritten: 0, error: '下载总量超过 200MB 上限（$name）');
      }
      final part = File(partPath);
      try {
        await part.writeAsBytes(body, flush: true);
        final digest = sha256.convert(await part.readAsBytes()).toString();
        if (digest != expected) {
          reason = '$host SHA-256 不符';
          _log.warning('unidbg jar 校验失败（期望 $expected，实际 $digest）：$url');
          await _deleteQuietly(part);
          continue;
        }
        await part.rename(targetPath);
        _log.info('unidbg jar 已就位：$name（$length 字节，$host）');
        return (bytesWritten: length, error: null);
      } catch (error) {
        await _deleteQuietly(part);
        reason = '$host 落盘失败（$error）';
        _log.warning('unidbg jar 落盘失败：$url（$error）');
        continue;
      }
    }
    return (bytesWritten: 0, error: '$name 下载失败：$reason');
  }

  Future<bool> _verified(File file, UnidbgJarPin pin) async {
    try {
      if (!await file.exists()) return false;
      if (await file.length() != pin.bytes) return false;
      final digest = sha256.convert(await file.readAsBytes()).toString();
      return digest == pin.sha256;
    } catch (_) {
      return false;
    }
  }

  Future<int> _bytesOnDisk(String root) async {
    var bytes = 0;
    for (final pin in _pins) {
      final file = File(p.join(root, pin.fileName));
      try {
        if (await file.exists() && await file.length() == pin.bytes) {
          bytes += pin.bytes;
        }
      } catch (_) {
        continue;
      }
    }
    return bytes;
  }

  Future<void> _deleteQuietly(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {
      return;
    }
  }

  String _hostOf(String url) {
    try {
      return Uri.parse(url).host;
    } catch (_) {
      return url;
    }
  }
}
