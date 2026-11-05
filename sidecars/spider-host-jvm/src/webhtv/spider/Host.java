package webhtv.spider;

import java.io.BufferedInputStream;
import java.io.BufferedOutputStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.LinkedHashMap;
import java.util.Map;

/**
 * JVM Spider 宿主入口（`tvbox-java-v1` sidecar，设计文档 §9.3、§9.7、§9.8）。
 *
 * <p>用法：
 * <pre>
 * java -jar host.jar --entry &lt;jar|目录|.java&gt; [--manifest &lt;manifest.json&gt;] [--class &lt;全限定类名&gt;]
 * </pre>
 *
 * <p>职责边界与 Python/Node 宿主一致：本类只负责协议帧与生命周期，站源只实现业务语义，
 * 不接触 stdio。stdout 只承载协议帧，一切日志走 stderr（§9.3.1）。
 *
 * <p>退出码：
 * <ul>
 *   <li>{@code 0} 正常退出（stdin 结束或收到 destroy/shutdown）；</li>
 *   <li>{@code 2} 协议错误或入口/manifest 非法——**不得**被误报为正常退出；</li>
 *   <li>{@code 3} 站源初始化失败。</li>
 * </ul>
 */
public final class Host {
    private Host() {}

    public static void main(String[] args) {
        // stderr 编码修复：本机 native.encoding=GBK，System.err.charset() 默认也是 GBK，
        // 而 Dart 宿主用 utf8.decode(..., allowMalformed: true) 严格解码——中文日志到用户侧
        // 就是乱码。实测 -Dfile.encoding=UTF-8 对本机 stderr 无效、-Dstderr.encoding=UTF-8
        // 有效，但依赖启动参数不如进程内自设可靠，因此在这里固定 UTF-8。
        // stdout 不动：协议帧由 Ipc 显式按 UTF-8 编码，且 stdout 被协议独占（§9.3.1）。
        System.setErr(new java.io.PrintStream(
                new java.io.FileOutputStream(java.io.FileDescriptor.err), true,
                java.nio.charset.StandardCharsets.UTF_8));
        int code = run(args);
        System.exit(code);
    }

    static int run(String[] args) {
        Map<String, String> options = parseArguments(args);
        Path manifestPath = options.containsKey("manifest")
                ? Path.of(options.get("manifest"))
                : null;

        Map<String, Object> manifest = new LinkedHashMap<>();
        if (manifestPath != null) {
            if (!Files.isRegularFile(manifestPath)) {
                Ipc.log("manifest 不存在：" + manifestPath);
                return 2;
            }
            try {
                Object parsed = Json.parse(Files.readString(manifestPath, StandardCharsets.UTF_8));
                if (parsed instanceof Map<?, ?> map) {
                    for (Map.Entry<?, ?> entry : map.entrySet()) {
                        manifest.put(String.valueOf(entry.getKey()), entry.getValue());
                    }
                } else {
                    Ipc.log("manifest 不是 JSON 对象：" + manifestPath);
                    return 2;
                }
            } catch (Exception error) {
                Ipc.log("读取 manifest 失败：" + error.getMessage());
                return 2;
            }
        }

        String entryOption = options.get("entry");
        if (entryOption == null || entryOption.isBlank()) {
            Ipc.log("缺少 --entry（站源 jar / 类目录 / .java）");
            return 2;
        }
        Path entry = Path.of(entryOption);
        if (!Files.exists(entry)) {
            Ipc.log("站源入口不存在：" + entry);
            return 2;
        }

        EntryLoader.Loaded loaded;
        try {
            loaded = EntryLoader.load(entry, options.get("class"), manifest);
        } catch (Throwable error) {
            // 必须 catch Throwable：NoClassDefFoundError 一类链接错误是 Error 而不是 Exception，
            // 漏掉它们会让异常穿透 main、进程以退出码 1 结束，违反「初始化失败必须 3」的契约。
            // 先打一行可读摘要（用户/宿主日志），再打完整栈（定位到缺失的类/方法）。
            Ipc.log("站源初始化失败：" + error.getClass().getSimpleName() + ": " + error.getMessage());
            error.printStackTrace();
            return 3;
        }

        SidecarServer server = new SidecarServer(
                loaded.spider,
                manifest,
                new BufferedInputStream(System.in),
                new BufferedOutputStream(System.out));
        Ipc.log("sidecar 就绪 entry=" + entry.getFileName()
                + " origin=" + loaded.origin
                + " class=" + loaded.className
                + " key=" + server.siteKey()
                + " capabilities=" + String.join(",", server.capabilities()));
        return server.serve();
    }

    /** 解析 `--name value` 形式的参数；未知参数记日志但不算失败。 */
    private static Map<String, String> parseArguments(String[] args) {
        Map<String, String> options = new LinkedHashMap<>();
        for (int i = 0; i < args.length; i++) {
            String argument = args[i];
            if (!argument.startsWith("--")) {
                Ipc.log("忽略无法识别的参数：" + argument);
                continue;
            }
            String name = argument.substring(2);
            int equals = name.indexOf('=');
            if (equals >= 0) {
                options.put(name.substring(0, equals), name.substring(equals + 1));
                continue;
            }
            if (i + 1 < args.length && !args[i + 1].startsWith("--")) {
                options.put(name, args[++i]);
            } else {
                options.put(name, "");
            }
        }
        return options;
    }
}
