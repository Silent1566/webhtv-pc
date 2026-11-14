package webhtv.spider;

import java.io.FileDescriptor;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.OutputStream;
import java.io.PrintStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.DirectoryStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.ArrayList;
import java.util.List;
import java.util.Locale;

/**
 * dex 预转译命令行入口，供宿主在**导入期**调用一次。
 *
 * <pre>
 * java -cp "host.jar;lib/*" webhtv.spider.DexIntakeCli --site &lt;站点目录&gt; [--archive &lt;jar 路径&gt;]
 * </pre>
 *
 * <p>为什么要独立入口：{@link DexIntake#translate} 首次转译实测约 9 s，而 sidecar 里它跑在
 * {@code initialize} 握手之前，宿主给握手只有 15 s。导入期先把产物落盘，之后 sidecar 加载同一站点
 * 时 {@code translate} 命中缓存（实测约 50 ms），握手才不会被转译耗时挤爆。
 *
 * <p>契约（宿主照此解析，不要改）：
 *
 * <ul>
 *   <li>stdout **只有一行** UTF-8 JSON：成功
 *       {@code {"ok":true,"bundle":..,"classCount":..,"cached":..,"sourceSha256":..,"archive":..}}，
 *       失败 {@code {"ok":false,"stage":..,"message":..}}；
 *   <li>stderr 是人类日志（{@link Ipc#log}），可多行；
 *   <li>退出码：成功 {@code 0}，失败 {@code 1}，不返回其它值。
 * </ul>
 *
 * <p>stdout 只有一行是硬约束，因此本类做三件事：fd 2 与 fd 1 各固定一种编码（fd 2 上的日志统一
 * UTF-8，宿主按 UTF-8 解）；{@link System#setOut} 把任何第三方（dex2jar / asm）的 stdout 输出
 * 改道到 fd 2；结果 JSON 直接写 {@link FileDescriptor#out}，不经过 {@code System.out}。
 */
public final class DexIntakeCli {
    private static final String STAGE_READ = "dex-读取";
    private static final String STAGE_TRANSLATE = "dex-转译";
    private static final String INDEX_JAR = "index.jar";
    private static final String USAGE =
            "java -cp \"host.jar;lib/*\" webhtv.spider.DexIntakeCli --site <站点目录> [--archive <jar 路径>]";

    private DexIntakeCli() {}

    public static void main(String[] args) {
        // fd 2 上必须只用一种编码：本机默认 stderr 编码是 GBK（native.encoding=GBK），而宿主按 UTF-8 解日志，
        // 中文会变成「锟诫」这类乱码，所以先把 System.err 固定成 UTF-8。
        System.setErr(new PrintStream(new FileOutputStream(FileDescriptor.err), true, StandardCharsets.UTF_8));
        // 转译链路上的第三方代码可能往 stdout 打日志；stdout 已被宿主当机器可读通道占用，
        // 一律改道 fd 2——既然是同一个流，就必须与上面同为 UTF-8，否则 fd 2 上混两种编码、两种解码都读不对。
        System.setOut(new PrintStream(new FileOutputStream(FileDescriptor.err), true, StandardCharsets.UTF_8));
        int code;
        try {
            code = run(args);
        } catch (Throwable error) {
            Ipc.log("dex 预转译入口异常：" + describe(error));
            error.printStackTrace(System.err);
            code = fail(STAGE_TRANSLATE, describe(error));
        }
        System.err.flush();
        System.exit(code);
    }

    private static int run(String[] args) {
        Path site = null;
        String archiveValue = null;
        for (int i = 0; i < args.length; i++) {
            String arg = args[i];
            String value;
            if (arg.equals("--site")) {
                if (i + 1 >= args.length) {
                    return fail(STAGE_READ, "--site 缺少取值；用法：" + USAGE);
                }
                value = args[++i];
            } else if (arg.startsWith("--site=")) {
                value = arg.substring("--site=".length());
            } else if (arg.equals("--archive")) {
                if (i + 1 >= args.length) {
                    return fail(STAGE_READ, "--archive 缺少取值；用法：" + USAGE);
                }
                value = args[++i];
                if (value.isEmpty()) {
                    return fail(STAGE_READ, "参数 --archive 的取值为空；用法：" + USAGE);
                }
                archiveValue = value;
                continue;
            } else if (arg.startsWith("--archive=")) {
                value = arg.substring("--archive=".length());
                if (value.isEmpty()) {
                    return fail(STAGE_READ, "参数 --archive 的取值为空；用法：" + USAGE);
                }
                archiveValue = value;
                continue;
            } else {
                return fail(STAGE_READ, "未知参数：" + arg + "；用法：" + USAGE);
            }
            if (value.isEmpty()) {
                return fail(STAGE_READ, "参数 --site 的取值为空；用法：" + USAGE);
            }
            site = Paths.get(value).toAbsolutePath().normalize();
        }
        if (site == null) {
            return fail(STAGE_READ, "缺少必填参数 --site；用法：" + USAGE);
        }

        Path siteDir = site.toAbsolutePath().normalize();
        if (!Files.isDirectory(siteDir)) {
            return fail(STAGE_READ, "站点目录不存在或不是目录：" + siteDir);
        }

        Path archive;
        if (archiveValue != null) {
            archive = Paths.get(archiveValue).toAbsolutePath().normalize();
        } else {
            try {
                archive = resolveArchive(siteDir);
            } catch (IllegalStateException ambiguous) {
                return fail(STAGE_READ, ambiguous.getMessage());
            } catch (IOException error) {
                return fail(STAGE_READ, "读取站点目录失败 " + siteDir + "：" + error);
            }
            if (archive == null) {
                return fail(
                        STAGE_READ,
                        "站点目录内既没有 " + INDEX_JAR + "，也没有唯一的 .jar：" + siteDir + "；请用 --archive 指定要转译的 jar");
            }
        }
        if (!Files.isRegularFile(archive)) {
            return fail(STAGE_READ, "源 jar 不存在或不是普通文件：" + archive);
        }
        if (!DexIntake.hasDexArchive(archive)) {
            return fail(STAGE_READ, "jar 内没有 classes.dex 条目（不含 dex 的普通 jar 不需要预转译）：" + archive);
        }

        Ipc.log("dex 预转译开始 site=" + siteDir + " archive=" + archive);
        long startedAt = System.nanoTime();
        try {
            DexIntake.Result result = DexIntake.translate(archive, siteDir);
            long elapsedMs = (System.nanoTime() - startedAt) / 1_000_000L;
            Ipc.log("dex 预转译完成 cached=" + result.cached() + " classes=" + result.classCount()
                    + " elapsedMs=" + elapsedMs + " bundle=" + result.bundle());
            return ok(result, archive);
        } catch (DexIntake.DexIntakeException error) {
            // 消息本身已形如「<阶段>: <细节>」，不再重复拼接阶段名。
            Ipc.log("dex 预转译失败 stage=" + error.stage() + " message=" + error.getMessage());
            return fail(error.stage(), error.getMessage());
        } catch (Throwable error) {
            // 含 NoClassDefFoundError（lib/ 缺 jar 时）：也必须是可解析的失败 JSON，不能把栈打到 stdout。
            Ipc.log("dex 预转译异常：" + describe(error));
            error.printStackTrace(System.err);
            return fail(STAGE_TRANSLATE, describe(error));
        }
    }

    /**
     * 缺省 archive 的定位顺序与 Dart 侧 {@code JarIntake._entryIn} 一致：先 {@code index.jar}，
     * 再目录内唯一的 {@code .jar}；有多个 jar 时拒绝猜测。
     */
    private static Path resolveArchive(Path siteDir) throws IOException {
        Path index = siteDir.resolve(INDEX_JAR);
        if (Files.isRegularFile(index)) {
            return index;
        }
        List<Path> jars = new ArrayList<>();
        try (DirectoryStream<Path> entries = Files.newDirectoryStream(siteDir)) {
            for (Path entry : entries) {
                if (!Files.isRegularFile(entry)) {
                    continue;
                }
                if (entry.getFileName().toString().toLowerCase(Locale.ROOT).endsWith(".jar")) {
                    jars.add(entry);
                }
            }
        }
        if (jars.size() == 1) {
            return jars.get(0);
        }
        if (jars.size() > 1) {
            jars.sort((left, right) -> left.getFileName().toString().compareTo(right.getFileName().toString()));
            List<String> names = new ArrayList<>();
            for (Path jar : jars) {
                names.add(jar.getFileName().toString());
            }
            throw new IllegalStateException(
                    "站点目录内有 " + jars.size() + " 个 .jar，无法确定要转译哪一个（" + String.join(", ", names)
                            + "）：" + siteDir + "；请用 --archive 指定");
        }
        return null;
    }

    private static int ok(DexIntake.Result result, Path archive) {
        StringBuilder json = new StringBuilder(256);
        json.append("{\"ok\":true,\"bundle\":")
                .append(quote(result.bundle().toAbsolutePath().normalize().toString()))
                .append(",\"classCount\":")
                .append(result.classCount())
                .append(",\"cached\":")
                .append(result.cached())
                .append(",\"sourceSha256\":")
                .append(quote(result.sourceSha256()))
                .append(",\"archive\":")
                .append(quote(archive.toAbsolutePath().normalize().toString()))
                .append('}');
        return emit(json.toString(), 0);
    }

    private static int fail(String stage, String message) {
        String reason = (message == null || message.isEmpty()) ? "未知原因" : message;
        StringBuilder json = new StringBuilder(256);
        json.append("{\"ok\":false,\"stage\":")
                .append(quote(stage))
                .append(",\"message\":")
                .append(quote(reason))
                .append('}');
        return emit(json.toString(), 1);
    }

    /** 一行 JSON + 换行，直接写 fd 1（UTF-8），不经过 {@code System.out}。 */
    private static int emit(String json, int exitCode) {
        try {
            OutputStream out = new FileOutputStream(FileDescriptor.out);
            out.write((json + "\n").getBytes(StandardCharsets.UTF_8));
            out.flush();
        } catch (IOException error) {
            Ipc.log("写入 stdout 失败：" + error);
        }
        return exitCode;
    }

    /**
     * 按 JSON 规则转义（反斜杠成 {@code \\}、引号成 {@code \"}、控制字符走十六进制转义），
     * 手写而不引第三方库：这一行是宿主唯一的解析输入，格式必须可控且**不得含裸换行**。
     */
    private static String quote(String value) {
        StringBuilder out = new StringBuilder(value.length() + 16);
        out.append('"');
        for (int i = 0; i < value.length(); i++) {
            char ch = value.charAt(i);
            switch (ch) {
                case '"':
                    out.append("\\\"");
                    break;
                case '\\':
                    out.append("\\\\");
                    break;
                case '\n':
                    out.append("\\n");
                    break;
                case '\r':
                    out.append("\\r");
                    break;
                case '\t':
                    out.append("\\t");
                    break;
                case '\b':
                    out.append("\\b");
                    break;
                case '\f':
                    out.append("\\f");
                    break;
                default:
                    if (ch < 0x20 || ch == 0x7f) {
                        out.append("\\u").append(String.format(Locale.ROOT, "%04x", (int) ch));
                    } else {
                        out.append(ch);
                    }
            }
        }
        return out.append('"').toString();
    }

    private static String describe(Throwable error) {
        String message = error.getMessage();
        String type = error.getClass().getName();
        return (message == null || message.isEmpty()) ? type : type + ": " + message;
    }
}
