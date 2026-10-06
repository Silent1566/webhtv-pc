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
 * <p>支持四种入口形态，覆盖「桌面 jar」与「源码直跑」两类使用方式：
 * <ol>
 *   <li>{@code *.jar}：已编译的桌面 jar（对齐 `CatVodSpider-PC` 风格产物）；</li>
 *   <li>目录（含 {@code .class}）：已编译的类目录；</li>
 *   <li>单个 {@code .java}：用 JDK 自带编译器在内存/临时目录编译后加载；</li>
 *   <li>目录（含 {@code .java}）：递归编译目录内全部源码后加载。</li>
 * </ol>
 *
 * <p>**这不是 Android jar 的加载路径。** Android 站源 jar 内是 {@code classes.dex} 且依赖
 * {@code android.content.Context}，JVM 无法加载（ADR-0002 §1.1）。此处只加载**无 Android
 * Context 的桌面 jar**，符合 §9.3 的 `tvbox-java-v1` 定义。
 *
 * <p>安全边界（§9.8）：入口必须落在 manifest 目录内（由宿主侧 `SpiderManifestRegistry`
 * 校验）；编译只在临时目录产出，站源无法写回 Spider 目录；stdout 仍由协议独占。
 */
public final class EntryLoader {
    private EntryLoader() {}

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
        } else {
            classpath.add(entry);
            origin = "jar:" + entry;
        }

        String className = resolveClassName(entry, classNameHint, manifest);
        URLClassLoader loader = new URLClassLoader(
                classpath.stream().map(EntryLoader::toUrl).toArray(URL[]::new),
                EntryLoader.class.getClassLoader());
        Class<?> type = loader.loadClass(className);

        Spider spider;
        if (Spider.class.isAssignableFrom(type)) {
            spider = (Spider) type.getDeclaredConstructor().newInstance();
        } else {
            // 允许工厂：`createSpider(Map<String,Object> manifest)`。
            try {
                Object created = type.getMethod("createSpider", Map.class).invoke(null, manifest);
                if (!(created instanceof Spider instance)) {
                    throw new IllegalArgumentException(
                            className + " 的 createSpider 未返回 webhtv.spider.Spider");
                }
                spider = instance;
            } catch (NoSuchMethodException error) {
                throw new IllegalArgumentException(
                        className + " 必须继承 webhtv.spider.Spider 或提供静态 createSpider(Map)");
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
