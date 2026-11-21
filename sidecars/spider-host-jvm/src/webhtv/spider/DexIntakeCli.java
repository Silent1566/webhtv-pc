package webhtv.spider;

import java.io.File;
import java.io.FileDescriptor;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.OutputStream;
import java.io.PrintStream;
import java.net.URL;
import java.net.URLClassLoader;
import java.nio.charset.StandardCharsets;
import java.nio.file.DirectoryStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.ArrayList;
import java.util.Enumeration;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.concurrent.TimeUnit;
import java.util.zip.ZipEntry;
import java.util.zip.ZipFile;

/**
 * dex 预转译命令行入口，供宿主在**导入期**调用一次。
 *
 * <pre>
 * java -cp "host.jar;lib/*" webhtv.spider.DexIntakeCli --site &lt;站点目录&gt; [--archive &lt;jar 路径&gt;] [--selfcheck]
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
 *       {@code {"ok":true,"bundle":..,"classCount":..,"cached":..,"sourceSha256":..,"archive":..,
 *       "repairedClasses":..,"stubbedMethods":..,"retargetedCalls":..,"retypedInstantiations":..,
 *       "records":[..],"selfcheck":{..}}}，失败
 *       {@code {"ok":false,"stage":..,"message":..}}；
 *   <li>{@code repairedClasses} / {@code stubbedMethods} / {@code retargetedCalls} /
 *       {@code retypedInstantiations} 是 {@link DexRepair} 的修复量，
 *       {@code records} 是逐条修复/跳过原因：宿主据此如实上报「转译了但没修到」，不必靠猜；
 *   <li>{@code --selfcheck}（默认关闭）追加一个 {@code selfcheck} 对象：
 *       {@code {"classes":N,"failed":M,"counts":{..},"failures":[{"class":..,"error":..,"message":..}..]}}，
 *       由**独立一次性 JVM** 对产物逐类 {@code Class.forName(name, false, loader)} 得出——只加载类，
 *       不初始化、不实例化、不调用站源方法、不联网。它是「这份 payload 还剩多少这类坑」的量化基线：
 *       宿主据此判断产物是否可信，而不是等运行期撞上 {@code IncompatibleClassChangeError}。
 *       自检本身跑不成时 {@code failed} 为 {@code -1} 并带 {@code error} 字段（不伪装成「0 失败」）；
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
    /**
     * 自检子 JVM 的超时：只做 {@code Class.forName}，1193 个类实测数秒，60 s 是给慢机器与类加载
     * 抖动的余量。超时按「自检没跑成」上报，绝不悄悄当作 0 失败。
     */
    private static final int SELF_CHECK_TIMEOUT_SECONDS = 60;

    /** {@code failures} 最多留多少条：它是排查入口，不是数据通道；总数看 {@code failed}。 */
    private static final int SELF_CHECK_FAILURE_LIMIT = 20;

    private static final String USAGE =
            "java -cp \"host.jar;lib/*\" webhtv.spider.DexIntakeCli --site <站点目录> [--archive <jar 路径>]"
                    + " [--selfcheck]";

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
        boolean selfCheck = false;
        for (int i = 0; i < args.length; i++) {
            String arg = args[i];
            String value;
            if (arg.equals("--selfcheck")) {
                selfCheck = true;
                continue;
            }
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

        Ipc.log("dex 预转译开始 site=" + siteDir + " archive=" + archive
                + " repairVersion=" + DexRepair.VERSION);
        long startedAt = System.nanoTime();
        try {
            DexIntake.Result result = DexIntake.translate(archive, siteDir);
            long elapsedMs = (System.nanoTime() - startedAt) / 1_000_000L;
            Ipc.log("dex 预转译完成 cached=" + result.cached() + " classes=" + result.classCount()
                    + " repairedClasses=" + result.repairedClasses()
                    + " stubbedMethods=" + result.stubbedMethods()
                    + " retypedInstantiations=" + result.retypedInstantiations()
                    + " elapsedMs=" + elapsedMs + " bundle=" + result.bundle());
            return ok(result, archive, selfCheck ? runSelfCheck(result.bundle(), result.classCount()) : null);
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

    private static int ok(DexIntake.Result result, Path archive, String selfCheckJson) {
        StringBuilder json = new StringBuilder(256);
        json.append("{\"ok\":true,\"bundle\":")
                .append(quote(result.bundle().toAbsolutePath().normalize().toString()))
                .append(",\"classCount\":")
                .append(result.classCount())
                .append(",\"cached\":")
                .append(result.cached())
                .append(",\"repairedClasses\":")
                .append(result.repairedClasses())
                .append(",\"stubbedMethods\":")
                .append(result.stubbedMethods())
                .append(",\"retargetedCalls\":")
                .append(result.retargetedCalls())
                .append(",\"retypedInstantiations\":")
                .append(result.retypedInstantiations())
                .append(",\"sourceSha256\":")
                .append(quote(result.sourceSha256()))
                .append(",\"archive\":")
                .append(quote(archive.toAbsolutePath().normalize().toString()))
                .append(",\"records\":[");
        // 逐条记录是同一条 JSON 里的数组：宿主能直接读到「为什么没修」，不用去翻 stderr 日志。
        java.util.List<String> records = result.records();
        for (int i = 0; i < records.size(); i++) {
            if (i > 0) {
                json.append(',');
            }
            json.append(quote(records.get(i)));
        }
        json.append(']');
        if (selfCheckJson != null) {
            // 自检结果是现成的 JSON 对象（本类自己序列化，串内已按同一规则转义），直接内联；
            // 必须在关根对象之前，否则它会落在这一行 JSON 之外，宿主解析直接失败。
            json.append(",\"selfcheck\":").append(selfCheckJson);
        }
        json.append('}');
        return emit(json.toString(), 0);
    }


    // ---------------------------------------------------------------- 导入期自检

    /**
     * 在**独立一次性 JVM** 里对产物做「逐类加载」自检，返回现成的 JSON 对象文本。
     *
     * <p>为什么必须是独立进程：站源的类一旦被加载就只有「加载」这一次机会，加载失败的类在本进程
     * 里既污染不了也修不回；而且自检要和真实运行同一个口径（同一 {@code host.jar}+{@code lib/*}、
     * 同样 {@code -noverify}），用子进程才不必在宿主进程里塞一个第二类加载器去试探。
     *
     * <p>自检失败（起不来、超时、没产出）**不影响** {@code ok}：转译本身是成功的，这里只是把
     * 「还剩多少坑」量化出来，所以失败信息进 {@code selfcheck.error}，{@code failed} 记 {@code -1}——
     * 宁可显式「没测成」，也不能让读数看起来像「一个坑都没有」。
     */
    private static String runSelfCheck(Path bundle, int classCount) {
        Path resultFile = null;
        Process process = null;
        try {
            resultFile = Files.createTempFile("webhtv-selfcheck-", ".json");
            List<String> command = new ArrayList<>();
            command.add(Path.of(System.getProperty("java.home"), "bin", "java").toString());
            // 与手工复现 payload 同一口径：-noverify 关掉校验器，看到的才是 dex2jar 的**语义**误译
            // （InstantiationError / IncompatibleClassChangeError / NoClassDefFoundError），
            // 而不是「帧还没修完」这类校验器噪声。
            command.add("-noverify");
            command.add("-cp");
            command.add(selfCheckClasspath(bundle));
            command.add(SelfCheck.class.getName());
            command.add(bundle.toAbsolutePath().normalize().toString());
            command.add(resultFile.toString());
            Ipc.log("dex 自检开始（独立 JVM，超时 " + SELF_CHECK_TIMEOUT_SECONDS
                    + " s；只加载类，不初始化、不实例化、不调站源方法）");
            process = new ProcessBuilder(command)
                    // stdout 丢弃、stderr 继承：子进程的日志进本进程的人类日志通道（fd 2），
                    // 协议通道（fd 1）与结果文件都不受影响，也就不存在管道写满卡死。
                    .redirectOutput(ProcessBuilder.Redirect.DISCARD)
                    .redirectError(ProcessBuilder.Redirect.INHERIT)
                    .start();
            process.getOutputStream().close();
            if (!process.waitFor(SELF_CHECK_TIMEOUT_SECONDS, TimeUnit.SECONDS)) {
                return selfCheckError(classCount, "自检超时（" + SELF_CHECK_TIMEOUT_SECONDS + " s）");
            }
            int code = process.exitValue();
            if (!Files.isRegularFile(resultFile) || Files.size(resultFile) == 0) {
                return selfCheckError(classCount, "自检子 JVM 没有产出结果（退出码 " + code + "）");
            }
            String json = Files.readString(resultFile, StandardCharsets.UTF_8).strip();
            if (!json.startsWith("{") || !json.endsWith("}")) {
                return selfCheckError(classCount, "自检结果不是 JSON 对象：" + json);
            }
            return json;
        } catch (IOException error) {
            return selfCheckError(classCount, "自检子 JVM 启动失败：" + error);
        } catch (InterruptedException error) {
            Thread.currentThread().interrupt();
            return selfCheckError(classCount, "自检被中断");
        } finally {
            if (process != null && process.isAlive()) {
                process.destroyForcibly();
            }
            deleteQuietly(resultFile);
        }
    }

    /** 自检没跑成时的读数：{@code failed=-1} 显式区别于「跑成了、0 个失败」。 */
    private static String selfCheckError(int classCount, String message) {
        Ipc.log("dex 自检未完成：" + message);
        return "{\"classes\":" + classCount + ",\"failed\":-1,\"failures\":[],\"error\":" + quote(message) + "}";
    }

    /**
     * 子进程的类路径：本进程类路径（{@code host.jar} 的 MANIFEST {@code Class-Path} 已把
     * {@code lib/*} 与 android 垫片带进来）＋产物 jar。
     *
     * <p>{@code lib/*} 这种通配符由 JVM 自己展开，这里换成本机绝对路径，子进程的工作目录就
     * 不再是解析前提（父进程的 cwd 与站点目录无关）。
     */
    private static String selfCheckClasspath(Path bundle) {
        String separator = File.pathSeparator;
        List<String> entries = new ArrayList<>();
        for (String entry : System.getProperty("java.class.path", "").split(java.util.regex.Pattern.quote(separator))) {
            if (entry.isBlank()) {
                continue;
            }
            entries.add(Path.of(entry).toAbsolutePath().normalize().toString());
        }
        entries.add(bundle.toAbsolutePath().normalize().toString());
        return String.join(separator, entries);
    }

    private static void deleteQuietly(Path path) {
        if (path == null) {
            return;
        }
        try {
            Files.deleteIfExists(path);
        } catch (IOException ignored) {
            // 临时文件删不掉不影响任何结论。
        }
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


    /**
     * 自检子 JVM 的入口：把产物里的每个类**只加载**一次（{@code Class.forName(name, false, loader)}）。
     *
     * <p>三不做，刻意留着：不初始化类（{@code initialize=false}，静态块一行不跑）、不实例化、
     * 不调用任何站源方法——自检是「还剩多少坑」的量化探针，不是冒烟测试，一旦开始执行业务代码
     * 就会引入网络与外部状态，读数也就不再可复现。{@code -noverify} 由父进程给。
     *
     * <p>结果写进父进程给的临时文件，stdout 一律不用：那一行 JSON 是父进程的协议通道。
     */
    public static final class SelfCheck {
        private SelfCheck() {}

        public static void main(String[] args) {
            String json;
            try {
                json = scan(Path.of(args[0]));
            } catch (Throwable error) {
                json = "{\"classes\":0,\"failed\":-1,\"failures\":[],\"error\":" + quote(describe(error)) + "}";
            }
            try {
                Files.writeString(Path.of(args[1]), json, StandardCharsets.UTF_8);
            } catch (IOException error) {
                Ipc.log("dex 自检结果写盘失败：" + error);
            }
        }

        private static String scan(Path bundle) throws IOException {
            List<String> names = classNames(bundle);
            Map<String, Integer> counts = new LinkedHashMap<>();
            for (String kind : new String[] {
                "VerifyError", "IncompatibleClassChangeError", "NoClassDefFoundError",
                "UnsupportedClassVersionError", "other"
            }) {
                counts.put(kind, 0);
            }
            List<String> failures = new ArrayList<>();
            int failed = 0;
            // 父加载器是自检进程自己的类路径（host.jar + lib/*）：站源的父类/接口（android 垫片、
            // com.github.catvod.crawler.*、okhttp）都从那里解析，与真实 sidecar 加载产物时一致。
            URLClassLoader loader = new URLClassLoader(
                    new URL[] {bundle.toUri().toURL()}, SelfCheck.class.getClassLoader());
            try {
                for (String name : names) {
                    try {
                        Class.forName(name, false, loader);
                    } catch (Throwable error) {
                        failed++;
                        String kind = error.getClass().getSimpleName();
                        counts.merge(counts.containsKey(kind) ? kind : "other", 1, Integer::sum);
                        if (failures.size() < SELF_CHECK_FAILURE_LIMIT) {
                            failures.add("{\"class\":" + quote(name)
                                    + ",\"error\":" + quote(kind)
                                    + ",\"message\":" + quote(brief(error.getMessage())) + "}");
                        }
                    }
                }
            } finally {
                loader.close();
            }
            StringBuilder json = new StringBuilder(512);
            json.append("{\"classes\":").append(names.size())
                    .append(",\"failed\":").append(failed)
                    .append(",\"counts\":{");
            boolean first = true;
            for (Map.Entry<String, Integer> count : counts.entrySet()) {
                if (!first) {
                    json.append(',');
                }
                first = false;
                json.append(quote(count.getKey())).append(':').append(count.getValue());
            }
            json.append("},\"failures\":[").append(String.join(",", failures)).append("]}");
            Ipc.log("dex 自检完成 classes=" + names.size() + " failed=" + failed + " counts=" + counts);
            return json.toString();
        }

        /** 产物里的类名（二进制名，已排序：zip 条目顺序不是稳定口径，排序后两次自检可逐条对比）。 */
        private static List<String> classNames(Path bundle) throws IOException {
            List<String> names = new ArrayList<>();
            try (ZipFile zip = new ZipFile(bundle.toFile())) {
                Enumeration<? extends ZipEntry> entries = zip.entries();
                while (entries.hasMoreElements()) {
                    ZipEntry entry = entries.nextElement();
                    String entryName = entry.getName();
                    if (entry.isDirectory() || !entryName.endsWith(".class")
                            || entryName.startsWith("META-INF/")) {
                        continue;
                    }
                    names.add(entryName.substring(0, entryName.length() - ".class".length())
                            .replace('/', '.'));
                }
            }
            names.sort(null);
            return names;
        }

        /** 单条失败只留一行、限长：清单是给人扫的，超长消息会把整行 JSON 淹掉。 */
        private static String brief(String message) {
            if (message == null) {
                return "";
            }
            String text = message.replace('\r', ' ').replace('\n', ' ');
            return text.length() <= 240 ? text : text.substring(0, 240) + "…";
        }
    }

    private static String describe(Throwable error) {
        String message = error.getMessage();
        String type = error.getClass().getName();
        return (message == null || message.isEmpty()) ? type : type + ": " + message;
    }
}
