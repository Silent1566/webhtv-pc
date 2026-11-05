package webhtv.spider;

import java.io.IOException;
import java.net.URL;
import java.net.URLClassLoader;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.stream.Stream;

/**
 * 站源入口加载（`tvbox-java-v1`，§9.7、§9.9）。
 *
 * <p>支持五种入口形态，覆盖「桌面 jar」与「源码直跑」两类使用方式：
 * <ol>
 *   <li>{@code *.jar}：已编译的桌面 jar（对齐 `CatVodSpider-PC` 风格产物）；</li>
 *   <li>目录（含 {@code .class}）：已编译的类目录；</li>
 *   <li>单个 {@code .java}：用 JDK 自带编译器在内存/临时目录编译后加载；</li>
 *   <li>目录（含 {@code .java}）：递归编译目录内全部源码后加载；</li>
 *   <li>含 {@code classes.dex} 的 jar（Android 站源）：先经 {@link DexIntake} 转译成
 *       class jar，再用转译产物加载（ADR-0002 §2）。</li>
 * </ol>
 *
 * <p>常规入口（前四种）不含 Android jar；第五种入口是 Android 站源 jar，它的
 * {@code classes.dex} 会先被转译成普通 class jar 再进类路径，{@code android.*} 与
 * {@code com.github.catvod.crawler.*} 由随 host.jar 分发的垫片解析。**只支持不碰 Android UI
 * 的站源**：依赖未在垫片清单内的 Android 类（如 {@code android.widget.TextView}）会在调用
 * 时抛 {@code NoClassDefFoundError}，由 {@link CatVodSpiderAdapter} 点名缺失的类。
 *
 * <p>安全边界（§9.8）：入口必须落在 manifest 目录内（由宿主侧 `SpiderManifestRegistry`
 * 校验）；编译只在临时目录产出，站源无法写回 Spider 目录；stdout 仍由协议独占。
 */
public final class EntryLoader {
    private EntryLoader() {}

    /** CatVod 基类全限定名（垫片随 host.jar 分发，见 build.ps1）。 */
    private static final String CATVOD_SPIDER_CLASS = "com.github.catvod.crawler.Spider";

    /**
     * Android 站源类所在的包。
     *
     * <p>实测转译产物（1227 个类）里，10 个目标站源类**全部**在这个包下；而宿主只从站点
     * key 得到裸类名，因此需要按此前缀回退查找。
     */
    private static final String CATVOD_SPIDER_PACKAGE = "com.github.catvod.spider";

    /** 已加载的站源实例与其来源描述。 */
    public static final class Loaded {
        public final Spider spider;
        public final String className;
        public final String origin;

        Loaded(Spider spider, String className, String origin) {
            this.spider = spider;
            this.className = className;
            this.origin = origin;
        }
    }

    public static Loaded load(Path entry, String classNameHint, Map<String, Object> manifest)
            throws Exception {
        if (!Files.exists(entry)) {
            throw new IllegalArgumentException("站源入口不存在：" + entry);
        }

        Path siteDir = Files.isDirectory(entry) ? entry : entry.toAbsolutePath().getParent();

        List<Path> classpath = new ArrayList<>();
        String origin;
        if (Files.isDirectory(entry)) {
            Path sourcesRoot = entry;
            List<Path> sources = collectSources(entry);
            if (!sources.isEmpty()) {
                Path compiled = compile(sources, sourcesRoot, manifest);
                classpath.add(compiled);
                origin = "sources:" + entry;
            } else {
                classpath.add(entry);
                origin = "classes:" + entry;
            }
        } else if (entry.getFileName().toString().toLowerCase().endsWith(".java")) {
            Path compiled = compile(List.of(entry), entry.getParent(), manifest);
            classpath.add(compiled);
            origin = "source:" + entry;
        } else if (DexIntake.hasDexArchive(entry)) {
            // Android 站源：进类路径的必须是**转译产物**，不是原 jar（原 jar 里只有 dex）。
            // DexIntakeException 原样上抛：它的消息已含固定阶段名（dex-读取 / dex-转译 /
            // dex-帧修复 / dex-落盘），包成笼统的「初始化失败」会丢掉用户唯一能自查的信息。
            DexIntake.Result translated = DexIntake.translate(entry, siteDir);
            classpath.add(translated.bundle());
            origin = "dex:" + entry + "(" + translated.classCount() + " ci)";
            Ipc.log("dex 转译产物 classes=" + translated.classCount()
                    + " cached=" + translated.cached()
                    + " sha256=" + translated.sourceSha256()
                    + " bundle=" + translated.bundle());
        } else {
            classpath.add(entry);
            origin = "jar:" + entry;
        }

        String className = resolveClassName(entry, classNameHint, manifest);
        URLClassLoader loader = new URLClassLoader(
                classpath.stream().map(EntryLoader::toUrl).toArray(URL[]::new),
                EntryLoader.class.getClassLoader());
        Class<?> type;
        try {
            type = loader.loadClass(className);
        } catch (ClassNotFoundException error) {
            // 裸类名回退：宿主只知道站点 key（`csp_Emby` → `Emby`），而 Android 站源的类
            // 在随包 dex 里一律位于 CATVOD_SPIDER_PACKAGE 下。不做这层回退时，用户看到的
            // 是 `ClassNotFoundException: Emby`，而真正的类是 `com.github.catvod.spider.Emby`。
            String fallback = qualifyWithCatVodPackage(className, loader);
            if (fallback == null) {
                throw error;
            }
            Ipc.log("类名回退：" + className + " → " + fallback);
            className = fallback;
            type = loader.loadClass(fallback);
        }

        Spider spider;
        if (Spider.class.isAssignableFrom(type)) {
            spider = (Spider) type.getDeclaredConstructor().newInstance();
        } else if (isCatVodSpider(type, loader)) {
            // 第二分支：CatVod 风格类（继承 com.github.catvod.crawler.Spider）。
            // **必须先判类型再试工厂**：isAssignableFrom 只解析类型层次，不枚举方法签名；
            // 而 tryFactory 里的 getMethod 会触发 getDeclaredMethods0、解析该类的**全部**声明
            // 签名——对依赖 Android UI 的站源（Media 的 android.app.Activity），那一步会在还没
            // 进本分支时就抛 NoClassDefFoundError，把缺失类名换成一句笼统的链接错误。
            try {
                // 主动枚举一次声明方法：让「签名引用垫片未提供的 Android 类」在**加载阶段**失败。
                // 否则它会在 SidecarServer 构造（capabilities()）时以 Error 穿透 main，
                // 进程退出码变成 1，违反「初始化失败必须 3」的契约。
                type.getDeclaredMethods();
                Object instance = type.getDeclaredConstructor().newInstance();
                spider = new CatVodSpiderAdapter(instance, newHostContext(siteDir));
            } catch (NoClassDefFoundError error) {
                throw new IllegalArgumentException(
                        CatVodSpiderAdapter.unsupportedAndroidMessage(error), error);
            }
        } else {
            // 第三分支：桌面工厂 `createSpider(Map<String,Object> manifest)`。
            Spider fromFactory = tryFactory(type, className, manifest);
            if (fromFactory != null) {
                spider = fromFactory;
            } else {
                throw new IllegalArgumentException(
                        className + " 必须继承 webhtv.spider.Spider 或提供静态 createSpider(Map)；"
                                + "若这是 Android 站源，需要先经 dex 转译且不能依赖 Android UI");
            }
        }
        spider.manifest = manifest == null ? new LinkedHashMap<>() : manifest;
        return new Loaded(spider, className, origin);
    }

    private static URL toUrl(Path path) {
        try {
            return path.toUri().toURL();
        } catch (java.net.MalformedURLException error) {
            throw new IllegalArgumentException("无法解析类路径：" + path, error);
        }
    }

    /**
     * 尝试桌面工厂 {@code createSpider(Map)}；类里没有该方法时返回 {@code null}，
     * 让调用方继续走 CatVod 壳分支。
     */
    private static Spider tryFactory(Class<?> type, String className, Map<String, Object> manifest) {
        java.lang.reflect.Method factory;
        try {
            factory = type.getMethod("createSpider", Map.class);
        } catch (NoSuchMethodException missing) {
            return null;
        }
        try {
            Object created = factory.invoke(null, manifest);
            if (!(created instanceof Spider instance)) {
                throw new IllegalArgumentException(
                        className + " 的 createSpider 未返回 webhtv.spider.Spider");
            }
            return instance;
        } catch (ReflectiveOperationException error) {
            Throwable cause = error instanceof java.lang.reflect.InvocationTargetException target
                            && target.getTargetException() != null
                    ? target.getTargetException()
                    : error;
            throw new IllegalStateException(className + " 的 createSpider 调用失败：" + cause, cause);
        }
    }

    /**
     * 是否为 CatVod 风格类。
     *
     * <p>基类类名写常量字符串、经 {@code Class.forName} 在**站源的同一个 loader** 里取：
     * 只有同一个 loader（父委派能看到 host.jar 垫片）解析出的基类才能用于
     * {@code isAssignableFrom}，用别的 loader 取会得到两个不相关的 {@code Class} 对象。
     */
    private static boolean isCatVodSpider(Class<?> type, ClassLoader loader) {
        try {
            return Class.forName(CATVOD_SPIDER_CLASS, false, loader).isAssignableFrom(type);
        } catch (ClassNotFoundException absent) {
            return false;
        }
    }

    /** 站点目录下的宿主 Context：SharedPreferences 落在这一个站点自己的子目录里。 */
    private static android.content.Context newHostContext(Path siteDir) throws IOException {
        Path dir = (siteDir == null ? Path.of(".") : siteDir).resolve(".webhtv-context");
        Files.createDirectories(dir);
        return new android.content.WebhtvContext(dir.toFile());
    }

    private static List<Path> collectSources(Path root) throws IOException {
        try (Stream<Path> stream = Files.walk(root)) {
            return stream
                    .filter(Files::isRegularFile)
                    .filter(path -> path.getFileName().toString().endsWith(".java"))
                    .sorted()
                    .toList();
        }
    }

    /**
     * 把裸类名限定到 Android 站源的包前缀（{@value #CATVOD_SPIDER_PACKAGE}）。
     *
     * <p>为什么需要：宿主持有的站点信息只有 key（{@code csp_Emby}），而去掉 {@code csp_}
     * 前缀得到的 {@code Emby} 并不是可加载的类名——随包 dex 里的站源类一律在
     * {@code com.github.catvod.spider} 下。没有这层回退，dex 站点会以
     * {@code ClassNotFoundException: Emby} 失败，而用户看到的「可用」判定又是通过静态分级
     * 得出的，两边结论互相矛盾。
     *
     * <p>只在类名**不含包名**（没有点号）且带该前缀的类真实存在时才回退，避免把真正
     * 缺类的错误掩盖成一个「猜出来的类名」。
     */
    private static String qualifyWithCatVodPackage(String className, ClassLoader loader) {
        if (className == null || className.indexOf('.') >= 0) {
            return null;
        }
        String candidate = CATVOD_SPIDER_PACKAGE + "." + className;
        try {
            Class.forName(candidate, false, loader);
            return candidate;
        } catch (ClassNotFoundException | LinkageError error) {
            return null;
        }
    }

    /**
     * 用 JDK 自带编译器编译源码。
     *
     * <p>用 {@code -proc:none} 关闭注解处理（避免站源通过注解处理器逃逸），并用
     * {@code --release 17} 固定字节码版本，使发行包里的 host.jar 能加载站源码。
     */
    private static Path compile(List<Path> sources, Path sourceRoot, Map<String, Object> manifest)
            throws IOException {
        javax.tools.JavaCompiler compiler = javax.tools.ToolProvider.getSystemJavaCompiler();
        if (compiler == null) {
            throw new IllegalStateException(
                    "当前 JVM 不含编译器（需要 JDK 而不是 JRE）；请提供已编译的 jar/class 入口");
        }
        Path output = Files.createTempDirectory("webhtv-jvm-spider");
        output.toFile().deleteOnExit();
        List<String> arguments = new ArrayList<>(List.of(
                "-encoding", "UTF-8",
                "-proc:none",
                "-nowarn",
                "-d", output.toString()));
        // 站源码可能需要 host.jar 里的 Spider/CallContext/Result：把当前类路径传进去。
        String classpath = System.getProperty("java.class.path");
        if (classpath != null && !classpath.isEmpty()) {
            arguments.add("-classpath");
            arguments.add(classpath);
        }
        for (Path source : sources) {
            arguments.add(source.toString());
        }

        java.io.ByteArrayOutputStream errors = new java.io.ByteArrayOutputStream();
        int code = compiler.run(null, null, errors, arguments.toArray(String[]::new));
        if (code != 0) {
            throw new IllegalArgumentException(
                    "站源源码编译失败：\n" + errors.toString(StandardCharsets.UTF_8));
        }
        if (manifest != null) {
            Ipc.log("已编译站源源码 files=" + sources.size() + " root=" + sourceRoot);
        }
        return output;
    }

    /**
     * 解析入口类名：显式 {@code --class} → manifest {@code config.className}
     * → manifest {@code key}（去掉 {@code csp_} 前缀）。
     */
    private static String resolveClassName(
            Path entry, String classNameHint, Map<String, Object> manifest) {
        if (classNameHint != null && !classNameHint.isBlank()) {
            return classNameHint.trim();
        }
        Object config = manifest == null ? null : manifest.get("config");
        if (config instanceof Map<?, ?> map) {
            Object declared = map.get("className");
            if (declared != null && !String.valueOf(declared).isBlank()) {
                return String.valueOf(declared).trim();
            }
        }
        Object key = manifest == null ? null : manifest.get("key");
        if (key != null) {
            String text = String.valueOf(key).trim();
            if (text.startsWith("csp_")) {
                text = text.substring("csp_".length());
            }
            if (!text.isEmpty()) {
                return text;
            }
        }
        throw new IllegalArgumentException(
                "无法确定入口类名：请用 --class 指定，或在 manifest 的 config.className 声明"
                        + "（入口=" + entry + "）");
    }
}
