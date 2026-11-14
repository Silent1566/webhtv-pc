/// 实时字幕模型目录：逐条从 Android 源 `RealtimeSubtitleModelCatalog.java` 复制，
/// revision/size/sha256 与源完全一致，不做任何推断。
library;

enum RealtimeSpeechEngine {
  onlineTransducer,
  offlineWenetCtc,
  offlineMoonshine,
}

class RealtimeModelFile {
  const RealtimeModelFile({
    required this.relativePath,
    required this.url,
    required this.size,
    required this.sha256,
  });

  final String relativePath;
  final String url;
  final int size;
  final String sha256;

  Map<String, Object?> toJson() => {
    'path': relativePath,
    'url': url,
    'size': size,
    'sha256': sha256,
  };
}

class RealtimeModelSpec {
  const RealtimeModelSpec({
    required this.id,
    required this.name,
    required this.directory,
    required this.engine,
    required this.minRamMb,
    required this.needsVad,
    required this.files,
  });

  final String id;
  final String name;
  final String directory;
  final RealtimeSpeechEngine engine;
  final int minRamMb;
  final bool needsVad;
  final List<RealtimeModelFile> files;

  /// 与源 `downloads(model)` 同一顺序：需要 VAD 时 VAD 排在首位。
  List<RealtimeModelFile> get downloads =>
      needsVad ? [RealtimeModelCatalog.vad, ...files] : files;
}

class RealtimeModelCatalog {
  const RealtimeModelCatalog._();

  static const RealtimeModelFile vad = RealtimeModelFile(
    relativePath: 'silero_vad.onnx',
    url: 'https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.onnx',
    size: 643854,
    sha256: '9e2449e1087496d8d4caba907f23e0bd3f78d91fa552479bb9c23ac09cbb1fd6',
  );

  static const List<RealtimeModelSpec> models = [
    RealtimeModelSpec(
      id: 'zh',
      name: '中文 · Zipformer 14M（流式）',
      directory: 'sherpa-onnx-streaming-zipformer-zh-14M-2023-02-23',
      engine: RealtimeSpeechEngine.onlineTransducer,
      minRamMb: 768,
      needsVad: false,
      files: [
        RealtimeModelFile(
          relativePath: 'encoder-epoch-99-avg-1.int8.onnx',
          url: 'https://huggingface.co/csukuangfj/sherpa-onnx-streaming-zipformer-zh-14M-2023-02-23/resolve/204ad334e2e683fd295359930cc16fc0432a23ac/encoder-epoch-99-avg-1.int8.onnx',
          size: 21621684,
          sha256: '1c556ea57cec304e55ec4b72e52c1cc098bb01476ed7d90f3de939fe126487b1',
        ),
        RealtimeModelFile(
          relativePath: 'decoder-epoch-99-avg-1.onnx',
          url: 'https://huggingface.co/csukuangfj/sherpa-onnx-streaming-zipformer-zh-14M-2023-02-23/resolve/204ad334e2e683fd295359930cc16fc0432a23ac/decoder-epoch-99-avg-1.onnx',
          size: 7509745,
          sha256: '5ee0f03a2768ff1d5c83ef3a493243c7935d316cd41280037b14783a3467cc78',
        ),
        RealtimeModelFile(
          relativePath: 'joiner-epoch-99-avg-1.int8.onnx',
          url: 'https://huggingface.co/csukuangfj/sherpa-onnx-streaming-zipformer-zh-14M-2023-02-23/resolve/204ad334e2e683fd295359930cc16fc0432a23ac/joiner-epoch-99-avg-1.int8.onnx',
          size: 1795562,
          sha256: 'a7cf9d82757bdcf786059454495a9ca95e4bd7347f72473fc08d794475c36169',
        ),
        RealtimeModelFile(
          relativePath: 'tokens.txt',
          url: 'https://huggingface.co/csukuangfj/sherpa-onnx-streaming-zipformer-zh-14M-2023-02-23/resolve/204ad334e2e683fd295359930cc16fc0432a23ac/tokens.txt',
          size: 48697,
          sha256: '8b294db9045d6e5f94647f4c1eec1af4da143a75053c399611444b378ff966ac',
        ),
      ],
    ),
    RealtimeModelSpec(
      id: 'yue',
      name: '粤语 · WeNet u2pp Conformer CTC',
      directory: 'sherpa-onnx-wenetspeech-yue-u2pp-conformer-ctc-zh-en-cantonese-int8-2025-09-10',
      engine: RealtimeSpeechEngine.offlineWenetCtc,
      minRamMb: 1280,
      needsVad: true,
      files: [
        RealtimeModelFile(
          relativePath: 'model.int8.onnx',
          url: 'https://huggingface.co/csukuangfj/sherpa-onnx-wenetspeech-yue-u2pp-conformer-ctc-zh-en-cantonese-int8-2025-09-10/resolve/c911764e8227cf372ee60adc75f7f407e5b8c905/model.int8.onnx',
          size: 134698500,
          sha256: '201bfd9e12ec4ac9ee3b23c5e071d9fa2381a8b21df317e2e08a170d6f1f55d3',
        ),
        RealtimeModelFile(
          relativePath: 'tokens.txt',
          url: 'https://huggingface.co/csukuangfj/sherpa-onnx-wenetspeech-yue-u2pp-conformer-ctc-zh-en-cantonese-int8-2025-09-10/resolve/c911764e8227cf372ee60adc75f7f407e5b8c905/tokens.txt',
          size: 85361,
          sha256: 'c7750677a1183606d2fd6f16d792e06e70d9843dba8a0c6e23a9dec78e06977a',
        ),
      ],
    ),
    RealtimeModelSpec(
      id: 'en',
      name: 'English · Zipformer 20M（流式）',
      directory: 'sherpa-onnx-streaming-zipformer-en-20M-2023-02-17',
      engine: RealtimeSpeechEngine.onlineTransducer,
      minRamMb: 768,
      needsVad: false,
      files: [
        RealtimeModelFile(
          relativePath: 'encoder-epoch-99-avg-1.int8.onnx',
          url: 'https://huggingface.co/csukuangfj/sherpa-onnx-streaming-zipformer-en-20M-2023-02-17/resolve/d42f2d9f7ca24806fb667456a18a9f1b60f70d16/encoder-epoch-99-avg-1.int8.onnx',
          size: 42845182,
          sha256: '3810755ce7c3ab26b42a8bcf39d191308fa27fb0f53358823ba46141d03b7eb3',
        ),
        RealtimeModelFile(
          relativePath: 'decoder-epoch-99-avg-1.onnx',
          url: 'https://huggingface.co/csukuangfj/sherpa-onnx-streaming-zipformer-en-20M-2023-02-17/resolve/d42f2d9f7ca24806fb667456a18a9f1b60f70d16/decoder-epoch-99-avg-1.onnx',
          size: 2092272,
          sha256: '45a7f940ecfb53d89fa270ad11b88b961e53a317203eb24b1c8e95ed208b0f30',
        ),
        RealtimeModelFile(
          relativePath: 'joiner-epoch-99-avg-1.int8.onnx',
          url: 'https://huggingface.co/csukuangfj/sherpa-onnx-streaming-zipformer-en-20M-2023-02-17/resolve/d42f2d9f7ca24806fb667456a18a9f1b60f70d16/joiner-epoch-99-avg-1.int8.onnx',
          size: 259572,
          sha256: 'e085d73b593cf9b0707f370dbd656d58327d3fe36d80d849202ef81df02cb01e',
        ),
        RealtimeModelFile(
          relativePath: 'tokens.txt',
          url: 'https://huggingface.co/csukuangfj/sherpa-onnx-streaming-zipformer-en-20M-2023-02-17/resolve/d42f2d9f7ca24806fb667456a18a9f1b60f70d16/tokens.txt',
          size: 5048,
          sha256: '49e3c2646595fd907228b3c6787069658f67b17377c60aeb8619c4551b2316fb',
        ),
      ],
    ),
    RealtimeModelSpec(
      id: 'de',
      name: 'Deutsch · Zipformer Kroko（流式）',
      directory: 'sherpa-onnx-streaming-zipformer-de-kroko-2025-08-06',
      engine: RealtimeSpeechEngine.onlineTransducer,
      minRamMb: 1024,
      needsVad: false,
      files: [
        RealtimeModelFile(
          relativePath: 'encoder.onnx',
          url: 'https://huggingface.co/csukuangfj/sherpa-onnx-streaming-zipformer-de-kroko-2025-08-06/resolve/887db3d083240198c2d2b99fb66cfcfe6948ced8/encoder.onnx',
          size: 70091557,
          sha256: '6e83993d6967ec7a3498b055b7e85ace85b5d64d1b1e8773cb29a43a11f5edb5',
        ),
        RealtimeModelFile(
          relativePath: 'decoder.onnx',
          url: 'https://huggingface.co/csukuangfj/sherpa-onnx-streaming-zipformer-de-kroko-2025-08-06/resolve/887db3d083240198c2d2b99fb66cfcfe6948ced8/decoder.onnx',
          size: 617489,
          sha256: '94a29592b403c53fa2231b478637da1ab4abcef7f5e46e432098416a4a3ed562',
        ),
        RealtimeModelFile(
          relativePath: 'joiner.onnx',
          url: 'https://huggingface.co/csukuangfj/sherpa-onnx-streaming-zipformer-de-kroko-2025-08-06/resolve/887db3d083240198c2d2b99fb66cfcfe6948ced8/joiner.onnx',
          size: 336817,
          sha256: '28356bff070aea51ab1d725a3278e81d19f9300f860d3248a7014292264df15a',
        ),
        RealtimeModelFile(
          relativePath: 'tokens.txt',
          url: 'https://huggingface.co/csukuangfj/sherpa-onnx-streaming-zipformer-de-kroko-2025-08-06/resolve/887db3d083240198c2d2b99fb66cfcfe6948ced8/tokens.txt',
          size: 5606,
          sha256: '86e8370994ff2c01149ba8c4f8709aa93cdc18914b27a717e291e96faf39a6eb',
        ),
      ],
    ),
    RealtimeModelSpec(
      id: 'fr',
      name: 'Français · Zipformer Kroko（流式）',
      directory: 'sherpa-onnx-streaming-zipformer-fr-kroko-2025-08-06',
      engine: RealtimeSpeechEngine.onlineTransducer,
      minRamMb: 1024,
      needsVad: false,
      files: [
        RealtimeModelFile(
          relativePath: 'encoder.onnx',
          url: 'https://huggingface.co/csukuangfj/sherpa-onnx-streaming-zipformer-fr-kroko-2025-08-06/resolve/08b84b7b7cf519be9817e9c16919d96a7a8bad91/encoder.onnx',
          size: 70092599,
          sha256: 'e02facae1daf6f1f13da67ea3ace7c722516d0868d1768d78c0580bc22cc0c5b',
        ),
        RealtimeModelFile(
          relativePath: 'decoder.onnx',
          url: 'https://huggingface.co/csukuangfj/sherpa-onnx-streaming-zipformer-fr-kroko-2025-08-06/resolve/08b84b7b7cf519be9817e9c16919d96a7a8bad91/decoder.onnx',
          size: 617488,
          sha256: '6aed547570e3ab5afc05429a017cedd3a056c16df3baa5703f02461cefa25bac',
        ),
        RealtimeModelFile(
          relativePath: 'joiner.onnx',
          url: 'https://huggingface.co/csukuangfj/sherpa-onnx-streaming-zipformer-fr-kroko-2025-08-06/resolve/08b84b7b7cf519be9817e9c16919d96a7a8bad91/joiner.onnx',
          size: 336817,
          sha256: 'a51eec759bcdcaae2614686fa2a8b57417b2d420dd55a5a5558b388d35a9b2b6',
        ),
        RealtimeModelFile(
          relativePath: 'tokens.txt',
          url: 'https://huggingface.co/csukuangfj/sherpa-onnx-streaming-zipformer-fr-kroko-2025-08-06/resolve/08b84b7b7cf519be9817e9c16919d96a7a8bad91/tokens.txt',
          size: 5415,
          sha256: 'fedfb9c844bfb2bf14171f8184863e3d617b815a8667bdd9fc9a3149fde73298',
        ),
      ],
    ),
    RealtimeModelSpec(
      id: 'es',
      name: 'Español · Zipformer Kroko（流式）',
      directory: 'sherpa-onnx-streaming-zipformer-es-kroko-2025-08-06',
      engine: RealtimeSpeechEngine.onlineTransducer,
      minRamMb: 1280,
      needsVad: false,
      files: [
        RealtimeModelFile(
          relativePath: 'encoder.onnx',
          url: 'https://huggingface.co/csukuangfj/sherpa-onnx-streaming-zipformer-es-kroko-2025-08-06/resolve/20cf7a4921613397841d31168796cade5b866585/encoder.onnx',
          size: 154878102,
          sha256: '2d9f5ef87d1a5257f8a6687e21501c56f3aa2fcbfcfab9364dcc4ce4e06ae81b',
        ),
        RealtimeModelFile(
          relativePath: 'decoder.onnx',
          url: 'https://huggingface.co/csukuangfj/sherpa-onnx-streaming-zipformer-es-kroko-2025-08-06/resolve/20cf7a4921613397841d31168796cade5b866585/decoder.onnx',
          size: 617488,
          sha256: 'd4ce176b94b25f7acc88717bc3f704fcf5d6e131aaac2e0cabab3885541181ee',
        ),
        RealtimeModelFile(
          relativePath: 'joiner.onnx',
          url: 'https://huggingface.co/csukuangfj/sherpa-onnx-streaming-zipformer-es-kroko-2025-08-06/resolve/20cf7a4921613397841d31168796cade5b866585/joiner.onnx',
          size: 336817,
          sha256: 'dae35df88d676e320fcdb99217328e66dcf722bf11b0f2459e14ddb5b982ded5',
        ),
        RealtimeModelFile(
          relativePath: 'tokens.txt',
          url: 'https://huggingface.co/csukuangfj/sherpa-onnx-streaming-zipformer-es-kroko-2025-08-06/resolve/20cf7a4921613397841d31168796cade5b866585/tokens.txt',
          size: 6385,
          sha256: '1be5e0a58e05d06d327df4c6b7b5e4f8aba01da6981eb016fcaceafc6a56680f',
        ),
      ],
    ),
    RealtimeModelSpec(
      id: 'ja',
      name: '日本語 · Moonshine tiny（离线）',
      directory: 'sherpa-onnx-moonshine-tiny-ja-quantized-2026-02-27',
      engine: RealtimeSpeechEngine.offlineMoonshine,
      minRamMb: 1280,
      needsVad: true,
      files: [
        RealtimeModelFile(
          relativePath: 'encoder_model.ort',
          url: 'https://huggingface.co/csukuangfj2/sherpa-onnx-moonshine-tiny-ja-quantized-2026-02-27/resolve/550e2eb0a8b33092f3b394f64649ee1b3d9eb506/encoder_model.ort',
          size: 13238184,
          sha256: '86ece73812604b9b5f1274b4d1e6eec0d783b96088ff46d49e30a53f881cad73',
        ),
        RealtimeModelFile(
          relativePath: 'decoder_model_merged.ort',
          url: 'https://huggingface.co/csukuangfj2/sherpa-onnx-moonshine-tiny-ja-quantized-2026-02-27/resolve/550e2eb0a8b33092f3b394f64649ee1b3d9eb506/decoder_model_merged.ort',
          size: 58327272,
          sha256: '9fcd9b71323a496b307e20dd305c4e9a1b533c7bedd6e4f660e974967dd60bb6',
        ),
        RealtimeModelFile(
          relativePath: 'tokens.txt',
          url: 'https://huggingface.co/csukuangfj2/sherpa-onnx-moonshine-tiny-ja-quantized-2026-02-27/resolve/550e2eb0a8b33092f3b394f64649ee1b3d9eb506/tokens.txt',
          size: 549350,
          sha256: '2870d843e14c1e187bf1913a521562a63b53933814bd7f2145120468f494a049',
        ),
      ],
    ),
    RealtimeModelSpec(
      id: 'zh-en',
      name: '中英双语 · Zipformer（流式）',
      directory: 'sherpa-onnx-streaming-zipformer-bilingual-zh-en-2023-02-20',
      engine: RealtimeSpeechEngine.onlineTransducer,
      minRamMb: 1280,
      needsVad: false,
      files: [
        RealtimeModelFile(
          relativePath: 'encoder-epoch-99-avg-1.int8.onnx',
          url: 'https://huggingface.co/csukuangfj/sherpa-onnx-streaming-zipformer-bilingual-zh-en-2023-02-20/resolve/98590b7ed6443e77b714204da2757d75e1a642f4/encoder-epoch-99-avg-1.int8.onnx',
          size: 181895032,
          sha256: '8fa764187a261844f859d7143ebaa563af5d10adfece4c18a8f414c88cba2a9b',
        ),
        RealtimeModelFile(
          relativePath: 'decoder-epoch-99-avg-1.onnx',
          url: 'https://huggingface.co/csukuangfj/sherpa-onnx-streaming-zipformer-bilingual-zh-en-2023-02-20/resolve/98590b7ed6443e77b714204da2757d75e1a642f4/decoder-epoch-99-avg-1.onnx',
          size: 13876452,
          sha256: '2e3b5ec371f8899ee6acd829fd753ba45772df57a91bdf37cde3136354e7db7d',
        ),
        RealtimeModelFile(
          relativePath: 'joiner-epoch-99-avg-1.int8.onnx',
          url: 'https://huggingface.co/csukuangfj/sherpa-onnx-streaming-zipformer-bilingual-zh-en-2023-02-20/resolve/98590b7ed6443e77b714204da2757d75e1a642f4/joiner-epoch-99-avg-1.int8.onnx',
          size: 3228404,
          sha256: '1ed689c5ed19dbaa725d9d191bb4822b5f4855a39e1ffd28cbc1f340d25b2ee0',
        ),
        RealtimeModelFile(
          relativePath: 'tokens.txt',
          url: 'https://huggingface.co/csukuangfj/sherpa-onnx-streaming-zipformer-bilingual-zh-en-2023-02-20/resolve/98590b7ed6443e77b714204da2757d75e1a642f4/tokens.txt',
          size: 56317,
          sha256: 'a8e0e4ec53810e433789b54a5c0134a7eaa2ffca595a6334d54c00da858841d3',
        ),
      ],
    ),
  ];

  /// 与源 `find(id)` 同语义：未知 id 回落到第一个（中文）模型。
  static RealtimeModelSpec find(String id) {
    for (final model in models) {
      if (model.id == id) return model;
    }
    return models.first;
  }

  static RealtimeModelSpec? byId(String id) {
    for (final model in models) {
      if (model.id == id) return model;
    }
    return null;
  }
}
