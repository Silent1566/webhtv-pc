package webhtv.spider;

import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.AtomicMoveNotSupportedException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.time.Instant;
import java.util.ArrayList;
import java.util.Enumeration;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.zip.ZipEntry;
import java.util.zip.ZipFile;
import java.util.zip.ZipOutputStream;

import org.objectweb.asm.ClassReader;
import org.objectweb.asm.ClassVisitor;
import org.objectweb.asm.ClassWriter;
import org.objectweb.asm.MethodVisitor;
import org.objectweb.asm.Opcodes;

/**
 * Android 站源 jar（内含 {@code classes.dex}）的转译入口（ADR-0002 §2）。
 *
 * <p>Android {@code csp_*.jar} 里只有 {@code classes.dex}，JVM 无法直接加载。这里把
 * {@code classes.dex} 用 dex2jar 转成 class、重算栈帧，落到**站点目录下的独立子目录**
 * {@code dexBundles/classes.jar}，供 {@link EntryLoader} 以普通 jar 加载。产物与源 jar
 * 分开放，绝不覆盖源文件。
 *
 * <p>转译很慢（本机约 10 s），因此把源 jar 的 SHA-256 记进 {@code dexBundles/intake-dex.json}：
 * 源没变且产物还在时直接返回缓存，不重新转译。
 *
 * <p>依赖：dex2jar 2.4.28 闭包与 asm 9.x，随发行包入库在 {@code sidecars/spider-host-jvm/lib/}，
 * 由 {@code host.jar} 的 MANIFEST {@code Class-Path} 带入类路径（见 build.ps1）。
 *
 * <p>线程/进程边界：本类不碰 stdout（协议独占），日志一律走 {@link Ipc#log}。
 */
public final class DexIntake {
    private DexIntake() {}

    /** 转译产物：{@code bundle} 为 class jar；{@code cached}=true 表示复用了已有产物，未重新转译。 */
    public record Result(Path bundle, boolean cached, int classCount, String sourceSha256) {}

    /**
     * 失败阶段固定为以下四种之一，异常消息形如 {@code "<阶段>: <细节>"}。
     *
     * <p>调用方据此决定处置：{@code dex-读取} 说明源 jar 本身不可用；{@code dex-转译} 说明
     * dex 内容或 dex2jar 依赖有问题；{@code dex-帧修复} 说明字节码重写阶段失败；
     * {@code dex-落盘} 说明站点目录不可写。绝不抛笼统的「初始化失败」。
     */
    public static final class DexIntakeException extends Exception {
        private final String stage;

        public DexIntakeException(String stage, String detail) {
            super(stage + ": " + detail);
            this.stage = stage;
        }

        public DexIntakeException(String stage, String detail, Throwable cause) {
            super(stage + ": " + detail, cause);
            this.stage = stage;
        }

        public String stage() {
            return stage;
        }
    }

    private static final String STAGE_READ = "dex-读取";
    private static final String STAGE_TRANSLATE = "dex-转译";
    private static final String STAGE_FRAMES = "dex-帧修复";
    private static final String STAGE_WRITE = "dex-落盘";

    private static final String DEX_ENTRY = "classes.dex";
    private static final String DEX2JAR_MAIN = "com.googlecode.dex2jar.tools.Dex2jarCmd";
    private static final String DEX2JAR_MAIN_RESOURCE = "com/googlecode/dex2jar/tools/Dex2jarCmd.class";

    private static final String BUNDLE_DIR = "dexBundles";
    private static final String BUNDLE_FILE = "classes.jar";
    private static final String RECORD_FILE = "intake-dex.json";

    /** ASM 版本与 lib/asm*.jar（9.x）一致；写死可避免从 Spi 读取时受宿主环境影响。 */
    private static final int ASM_API = Opcodes.ASM9;

    /**
     * 是否为「含 {@code classes.dex} 的 jar」。
     *
     * <p>按 zip 条目名**精确匹配**，不做裸字节搜索：裸搜索会把「dex 数据恰好出现在别的
     * 条目里」的普通 jar 误判成 Android jar，进而白跑一次 10 s 的转译。
     */
    public static boolean hasDexArchive(Path archive) {
        if (archive == null || !Files.isRegularFile(archive)) {
            return false;
        }
        try (ZipFile zip = new ZipFile(archive.toFile())) {
            return zip.getEntry(DEX_ENTRY) != null;
        } catch (IOException error) {
            // 不是 zip / 已损坏：当作「不含 dex」，由调用方走普通入口路径去报错。
            return false;
        }
    }

    /**
     * 把 {@code archive} 里的 {@code classes.dex} 转译成 {@code siteDir/dexBundles/classes.jar}。
     *
     * <p>幂等：源 SHA-256 与产物记录一致且产物仍在时返回 {@code cached=true}。
     */
    public static Result translate(Path archive, Path siteDir) throws DexIntakeException {
        if (archive == null || !Files.isRegularFile(archive)) {
            throw new DexIntakeException(STAGE_READ, "源 jar 不存在或不是普通文件：" + archive);
        }
        if (siteDir == null) {
            throw new DexIntakeException(STAGE_WRITE, "站点目录为空");
        }
        Path bundleDir = siteDir.resolve(BUNDLE_DIR);
        Path bundle = bundleDir.resolve(BUNDLE_FILE);
        Path record = bundleDir.resolve(RECORD_FILE);
        if (sameFile(archive, bundle)) {
            // 站点目录就是源 jar 所在目录时可能算到同一条路径；宁可报错也不覆盖源 jar。
            throw new DexIntakeException(STAGE_WRITE, "产物路径与源 jar 相同，拒绝覆盖：" + bundle);
        }

        String sourceSha = sha256(archive, STAGE_READ);
        byte[] dex;
        long dexSize;
        try (ZipFile zip = new ZipFile(archive.toFile())) {
            ZipEntry entry = zip.getEntry(DEX_ENTRY);
            if (entry == null) {
                throw new DexIntakeException(STAGE_READ, "jar 内没有 " + DEX_ENTRY + " 条目：" + archive);
            }
            dexSize = entry.getSize();
            dex = readEntry(zip, entry);
        } catch (IOException error) {
            throw new DexIntakeException(STAGE_READ, "读取 " + archive + " 失败：" + error, error);
        }

        Cached cached = readRecord(record);
        if (cached != null
                && cached.sourceSha256.equals(sourceSha)
                && Files.isRegularFile(bundle)
                && cached.bundleSha256.equals(sha256(bundle, STAGE_READ))) {
            Ipc.log("dex 产物缓存命中 bundle=" + bundle + " classes=" + cached.classCount);
            return new Result(bundle, true, cached.classCount, sourceSha);
        }

        try {
            Files.createDirectories(bundleDir);
        } catch (IOException error) {
            throw new DexIntakeException(STAGE_WRITE, "创建产物目录失败 " + bundleDir + "：" + error, error);
        }

        Path work = null;
        try {
            // 中间产物放在目标同目录的临时目录里：后续 move 才可能真正原子（同卷）。
            work = Files.createTempDirectory(bundleDir, ".dex-intake-");
            Path raw = work.resolve("raw.jar");
            Path fixed = work.resolve("fixed.jar");
            translateDex(dex, archive, raw);
            int classCount = fixFrames(raw, fixed);
            moveAtomically(fixed, bundle);
            String bundleSha = sha256(bundle, STAGE_WRITE);
            writeRecord(record, sourceSha, bundleSha, classCount, dexSize);
            Ipc.log("dex 转译完成 bundle=" + bundle + " classes=" + classCount + " dexEntrySize=" + dexSize);
            return new Result(bundle, false, classCount, sourceSha);
        } catch (IOException error) {
            throw new DexIntakeException(STAGE_WRITE, "写入产物失败：" + error, error);
        } finally {
            deleteQuietly(work);
        }
    }

    // ---------------------------------------------------------------- 转译

    /**
     * 优先进程内转译：dex2jar 已在 sidecar 类路径上（host.jar 的 MANIFEST Class-Path 指向
     * lib/），进程内调用省掉一次 JVM 启动。
     *
     * <p>只有「类路径上根本没有 dex2jar」才回落到子进程——dex 内容本身有问题时进程内就能
     * 给出更准确的原始异常，不该丢给子进程的退出码。子进程的 java 由 {@code java.home}
     * 推导，绝不使用 PATH 上的 java（本机 PATH 上的 java 是 Java 8）。
     */
    private static void translateDex(byte[] dex, Path archive, Path out) throws DexIntakeException {
        try {
            Files.deleteIfExists(out);
        } catch (IOException error) {
            throw new DexIntakeException(STAGE_TRANSLATE, "清理中间产物失败 " + out + "：" + error, error);
        }
        try {
            translateInProcess(dex, out);
            return;
        } catch (LinkageError | ClassNotFoundException missing) {
            Ipc.log(STAGE_TRANSLATE + ": 进程内 dex2jar 不可用（" + missing + "），改用子进程");
        } catch (DexIntakeException error) {
            throw error;
        } catch (Throwable error) {
            throw new DexIntakeException(STAGE_TRANSLATE, "dex2jar 转译失败：" + error, error);
        }
        try {
            Files.deleteIfExists(out);
        } catch (IOException error) {
            throw new DexIntakeException(STAGE_TRANSLATE, "清理中间产物失败 " + out + "：" + error, error);
        }
        translateInSubprocess(archive, out);
    }

    /**
     * 进程内调用 dex2jar。放在独立方法里，使 {@code com.googlecode.d2j.dex.Dex2jar} 的解析
     * 推迟到本方法首次执行——依赖缺失时抛出的是可捕获的 {@link LinkageError}，
     * 而不是让整个 {@link DexIntake} 类加载失败。
     */
    private static void translateInProcess(byte[] dex, Path out) throws Exception {
        com.googlecode.d2j.dex.Dex2jar.from(dex).to(out);
    }

    private static void translateInSubprocess(Path archive, Path out) throws DexIntakeException {
        String classpath = dex2jarClasspath();
        String java = Path.of(System.getProperty("java.home"), "bin", "java").toString();
        List<String> command = List.of(java, "-cp", classpath, DEX2JAR_MAIN,
                "-f", "-o", out.toString(), archive.toString());
        try {
            Process process = new ProcessBuilder(command).redirectErrorStream(true).start();
            String output = new String(process.getInputStream().readAllBytes(), StandardCharsets.UTF_8);
            int code = process.waitFor();
            if (code != 0) {
                throw new DexIntakeException(STAGE_TRANSLATE,
                        "子进程 dex2jar 退出码 " + code + "：" + output.strip());
            }
            if (!Files.isRegularFile(out)) {
                throw new DexIntakeException(STAGE_TRANSLATE, "子进程 dex2jar 未产出 " + out + "：" + output.strip());
            }
        } catch (IOException error) {
            throw new DexIntakeException(STAGE_TRANSLATE, "启动子进程 dex2jar 失败（" + java + "）：" + error, error);
        } catch (InterruptedException error) {
            Thread.currentThread().interrupt();
            throw new DexIntakeException(STAGE_TRANSLATE, "子进程 dex2jar 被中断", error);
        }
    }

    /**
     * 子进程用的类路径：优先复用当前 JVM 的类路径（MANIFEST Class-Path 已把 lib/*.jar 带进来），
     * 找不到 dex2jar 时才回落到 sidecar 目录下的 {@code lib/}。
     */
    private static String dex2jarClasspath() throws DexIntakeException {
        String current = System.getProperty("java.class.path", "");
        if (containsDex2jar(current)) {
            return current;
        }
        List<String> jars = new ArrayList<>();
        Path start = ownLocation();
        for (Path dir = start; dir != null && jars.isEmpty(); dir = dir.getParent()) {
            Path lib = dir.resolve("lib");
            if (!Files.isDirectory(lib)) {
                continue;
            }
            try (var stream = Files.list(lib)) {
                stream.filter(path -> path.getFileName().toString().endsWith(".jar"))
                        .sorted()
                        .forEach(path -> jars.add(path.toString()));
            } catch (IOException error) {
                throw new DexIntakeException(STAGE_TRANSLATE, "读取依赖目录失败 " + lib + "：" + error, error);
            }
            if (!containsDex2jar(String.join(java.io.File.pathSeparator, jars))) {
                jars.clear();
            }
        }
        if (jars.isEmpty()) {
            throw new DexIntakeException(STAGE_TRANSLATE,
                    "找不到 dex2jar 依赖：类路径与 sidecar 的 lib/ 均不含 " + DEX2JAR_MAIN);
        }
        return String.join(java.io.File.pathSeparator, jars);
    }

    private static boolean containsDex2jar(String classpath) {
        for (String entry : classpath.split(java.util.regex.Pattern.quote(java.io.File.pathSeparator))) {
            if (entry.isBlank()) {
                continue;
            }
            Path path = Path.of(entry);
            if (Files.isDirectory(path)) {
                if (Files.isRegularFile(path.resolve(DEX2JAR_MAIN_RESOURCE))) {
                    return true;
                }
            } else if (Files.isRegularFile(path)) {
                try (ZipFile zip = new ZipFile(path.toFile())) {
                    if (zip.getEntry(DEX2JAR_MAIN_RESOURCE) != null) {
                        return true;
                    }
                } catch (IOException ignored) {
                    // 不是 zip：继续找下一个条目。
                }
            }
        }
        return false;
    }

    /** 本类所在的位置（host.jar 或 class 目录），用于回落定位 {@code lib/}。 */
    private static Path ownLocation() {
        try {
            var source = DexIntake.class.getProtectionDomain().getCodeSource();
            if (source == null || source.getLocation() == null) {
                return null;
            }
            return Path.of(source.getLocation().toURI());
        } catch (Exception | LinkageError error) {
            return null;
        }
    }

    // ---------------------------------------------------------------- 帧修复

    /**
     * dex2jar 2.4.28 产出的 StackMapTable 与真实字节码不一致，JVM 校验器会以 VerifyError
     * 拒绝加载。这里丢弃原帧并用 ASM 重算（{@link ClassWriter#COMPUTE_FRAMES}），
     * {@code getCommonSuperClass} 保守返回 {@code java/lang/Object}：精确求公共父类需要
     * 加载站源类，而这些类在 sidecar 里不一定可见。
     *
     * <p>单类重写失败**不中断**：该条目原样写出并计数（由调用方按 failed 数判断产物是否可信）。
     * 只有「整个 jar 读不出来/写不下去」这种无法继续的 I/O 失败才抛 {@code dex-帧修复}。
     *
     * @return jar 内的 class 条目数
     */
    private static int fixFrames(Path raw, Path fixed) throws DexIntakeException {
        int rewritten = 0;
        int failed = 0;
        int classes = 0;
        try (ZipFile in = new ZipFile(raw.toFile());
                ZipOutputStream out = new ZipOutputStream(Files.newOutputStream(fixed))) {
            Enumeration<? extends ZipEntry> entries = in.entries();
            while (entries.hasMoreElements()) {
                ZipEntry entry = entries.nextElement();
                if (entry.isDirectory()) {
                    continue;
                }
                byte[] data = readEntry(in, entry);
                if (entry.getName().endsWith(".class")) {
                    classes++;
                    try {
                        data = rewriteClass(data);
                        rewritten++;
                    } catch (Throwable error) {
                        failed++;
                        Ipc.log(STAGE_FRAMES + ": 重写失败 " + entry.getName() + "（" + error + "），原样保留");
                    }
                }
                ZipEntry copy = new ZipEntry(entry.getName());
                if (entry.getTime() >= 0) {
                    copy.setTime(entry.getTime());
                }
                out.putNextEntry(copy);
                out.write(data);
                out.closeEntry();
            }
        } catch (IOException error) {
            throw new DexIntakeException(STAGE_FRAMES, "重写 " + raw + " 失败：" + error, error);
        }
        if (classes > 0 && rewritten == 0) {
            // 全部类都重写失败通常意味着 asm 本身不在类路径上：此时产物一定 VerifyError，
            // 报错比交出一个「看起来成功」的坏 jar 好。
            throw new DexIntakeException(STAGE_FRAMES,
                    "没有任何类重写成功（classes=" + classes + " failed=" + failed + "），asm 是否在类路径上？");
        }
        Ipc.log(STAGE_FRAMES + ": rewritten=" + rewritten + " failed=" + failed + " classes=" + classes);
        return classes;
    }

    private static byte[] rewriteClass(byte[] data) {
        ClassReader reader = new ClassReader(data);
        ClassWriter writer = new ClassWriter(reader, ClassWriter.COMPUTE_FRAMES | ClassWriter.COMPUTE_MAXS) {
            @Override
            protected String getCommonSuperClass(String type1, String type2) {
                return "java/lang/Object";
            }
        };
        reader.accept(new FrameStripper(writer), ClassReader.SKIP_FRAMES);
        return writer.toByteArray();
    }

    /** 吞掉原 StackMapTable，让 COMPUTE_FRAMES 重算。 */
    private static final class FrameStripper extends ClassVisitor {
        FrameStripper(ClassVisitor next) {
            super(ASM_API, next);
        }

        @Override
        public MethodVisitor visitMethod(
                int access, String name, String descriptor, String signature, String[] exceptions) {
            MethodVisitor next = super.visitMethod(access, name, descriptor, signature, exceptions);
            if (next == null) {
                return null;
            }
            return new MethodVisitor(ASM_API, next) {
                @Override
                public void visitFrame(int type, int numLocal, Object[] local, int numStack, Object[] stack) {
                    // 有意不转发：帧由 COMPUTE_FRAMES 重算。
                }
            };
        }
    }

    // ---------------------------------------------------------------- 产物记录与文件

    private record Cached(String sourceSha256, String bundleSha256, int classCount) {}

    /** 记录损坏只说明缓存不可用，不代表源不可转译：按未命中处理，重转一次即可。 */
    private static Cached readRecord(Path record) {
        if (!Files.isRegularFile(record)) {
            return null;
        }
        try {
            Object parsed = Json.parse(Files.readString(record, StandardCharsets.UTF_8));
            if (!(parsed instanceof Map<?, ?> map)) {
                return null;
            }
            Object source = map.get("sourceSha256");
            Object bundle = map.get("bundleSha256");
            Object count = map.get("classCount");
            if (source == null || bundle == null || !(count instanceof Number number)) {
                return null;
            }
            int classCount = number.intValue();
            if (classCount <= 0) {
                return null;
            }
            return new Cached(String.valueOf(source), String.valueOf(bundle), classCount);
        } catch (Exception error) {
            Ipc.log(STAGE_READ + ": 产物记录不可读，按未命中处理 " + record + "（" + error + "）");
            return null;
        }
    }

    private static void writeRecord(
            Path record, String sourceSha, String bundleSha, int classCount, long dexSize)
            throws IOException {
        Map<String, Object> data = new LinkedHashMap<>();
        data.put("sourceSha256", sourceSha);
        data.put("bundleSha256", bundleSha);
        data.put("classCount", classCount);
        data.put("translatedAt", Instant.now().toString());
        data.put("dexEntrySize", dexSize);
        writeAtomically(record, Json.write(data).getBytes(StandardCharsets.UTF_8));
    }

    private static void writeAtomically(Path target, byte[] bytes) throws IOException {
        Path temp = Files.createTempFile(target.getParent(), target.getFileName().toString(), ".tmp");
        try {
            Files.write(temp, bytes);
            moveAtomically(temp, target);
        } finally {
            Files.deleteIfExists(temp);
        }
    }

    /**
     * 临时文件 → 原子 move：转译要 10 s，中途失败/被杀时目标路径上要么是旧产物、要么是新
     * 产物，不会出现半个 jar 被后续加载。
     */
    private static void moveAtomically(Path from, Path to) throws IOException {
        try {
            Files.move(from, to, StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING);
        } catch (AtomicMoveNotSupportedException error) {
            // 文件系统不支持原子移动（跨卷等）：退化为普通替换，总比没有产物好。
            Files.move(from, to, StandardCopyOption.REPLACE_EXISTING);
        }
    }

    private static byte[] readEntry(ZipFile zip, ZipEntry entry) throws IOException {
        try (InputStream in = zip.getInputStream(entry)) {
            return in.readAllBytes();
        }
    }

    private static String sha256(Path file, String stage) throws DexIntakeException {
        MessageDigest digest;
        try {
            digest = MessageDigest.getInstance("SHA-256");
        } catch (NoSuchAlgorithmException error) {
            throw new DexIntakeException(stage, "当前 JVM 不支持 SHA-256：" + error, error);
        }
        try (InputStream in = Files.newInputStream(file)) {
            byte[] buffer = new byte[1 << 16];
            int read;
            while ((read = in.read(buffer)) > 0) {
                digest.update(buffer, 0, read);
            }
        } catch (IOException error) {
            throw new DexIntakeException(stage, "读取 " + file + " 失败：" + error, error);
        }
        StringBuilder hex = new StringBuilder(64);
        for (byte value : digest.digest()) {
            hex.append(Character.forDigit((value >> 4) & 0xf, 16));
            hex.append(Character.forDigit(value & 0xf, 16));
        }
        return hex.toString();
    }

    private static boolean sameFile(Path left, Path right) {
        return left.toAbsolutePath().normalize().equals(right.toAbsolutePath().normalize());
    }

    private static void deleteQuietly(Path path) {
        if (path == null) {
            return;
        }
        try {
            if (Files.isDirectory(path)) {
                try (var stream = Files.list(path)) {
                    for (Path child : stream.toList()) {
                        Files.deleteIfExists(child);
                    }
                }
            }
            Files.deleteIfExists(path);
        } catch (IOException error) {
            Ipc.log(STAGE_WRITE + ": 清理临时目录失败 " + path + "（" + error + "）");
        }
    }
}
