package com.github.catvod.spider;

import java.io.File;
import java.io.IOException;
import java.lang.reflect.Constructor;
import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;
import java.lang.reflect.Modifier;
import java.net.MalformedURLException;
import java.net.URL;
import java.net.URLClassLoader;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.Enumeration;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import java.util.zip.ZipEntry;
import java.util.zip.ZipFile;

import webhtv.spider.DexIntake;

/**
 * 加固壳桥接的纯 Java 影子实现：壳里同名类只有三个 native 方法
 * （getLoader(Object) / getSpider(Object,String) / proxyInvoke(Object,Object)），
 * 真机靠 System.loadLibrary 里的实现把调用转给解包出来的 payload。
 *
 * <p>桌面 JVM 上没有那份 native 库，所以把同包同名的这个类编进 host.jar：站源的
 * URLClassLoader 以宿主 loader 为父（EntryLoader 是 parent-first），壳里的
 * com.github.catvod.spider.DexNative 于是被本类整个覆盖——连壳的 static {}（加载 native 库）
 * 都不会再执行。这是「壳 jar 当站点入口 + payload.jar 同目录」能跑通的前提。
 *
 * <p>为什么这个类放在 src-android-shim：它必须与壳同包同名才盖得住，而垫片目录是唯一
 * 跟着 host.jar 按原包名编译进来的地方。它并不模拟 Android API，是宿主实现，因此可以
 * 直接用 DexIntake（两者由 build.ps1 一起编进 host.jar）。
 *
 * <p>错误口径：一律抛带名字的异常，绝不返回 null。壳的调用点会把 NPE 吞成「首页 0 条目」，
 * 用户看到的只是站点空着，排查成本远高于一条指名道姓的异常。
 */
public class DexNative {

    /** 显式指定 payload 的位置（文件或目录）；宿主启动侧车时可以传，明确、无歧义。 */
    private static final String PAYLOAD_PROPERTY = "webhtv.shellPayload";

    /** 装配约定：壳 jar 是 index.jar，解包产物是同目录下的这个文件名。 */
    private static final String PAYLOAD_FILE = "payload.jar";

    /** 壳与 payload 里的站源类都在这个包下（壳的 native 实现也只认这个包）。 */
    private static final String PAYLOAD_PACKAGE = "com.github.catvod.spider";

    private static final String SPIDER_BASE = "com.github.catvod.crawler.Spider";
    private static final String GUARD_SUFFIX = "Guard";

    /**
     * payload 的 dex 转译产物目录（相对 payload.jar 所在目录）。
     *
     * <p>不能复用站点目录的 dexBundles/：那是壳的转译产物（EntryLoader 对 index.jar 做的），
     * 两者都会写同名 classes.jar，共用就会互相顶掉。
     */
    private static final String PAYLOAD_DEX_DIR = "payload-dex";

    /** 已打开过的 payload（key = payload.jar 的绝对路径）。一个 sidecar 只服务一个站点，无需淘汰。 */
    private static final Map<String, Payload> PAYLOADS = new ConcurrentHashMap<>();

    /** 当前 sidecar 已解析的 payload 站点类；用于绑定同一 payload 的代理路由。 */
    private static volatile Class<?> currentSpiderClass;
    private static final Map<Class<?>, Method> PROXY_METHODS = new ConcurrentHashMap<>();

    /** 最近一次由壳传进来的宿主 Context（getLoader 的入参）。 */
    private static volatile Object LAST_CONTEXT;

    /**
     * 宿主（{@code EntryLoader}）在建站源之前注入站点 Context。
     *
     * <p>为什么宿主来给：壳构造时就可能进 payload 的初始化，而壳自己那条
     * {@code Init.init(Context)} 在桌面上跑不了（它要调 native 库），所以上下文只能由
     * 宿主在构造之前塞进来。
     */
    public static void setHostContext(Object context) {
        LAST_CONTEXT = context;
    }

    /** 已经注入过 Context 的 payload 类加载器（同一个进程里只做一次，避免每次调用都反射）。 */
    private static final java.util.Set<ClassLoader> CONTEXT_INSTALLED =
            java.util.Collections.newSetFromMap(new java.util.concurrent.ConcurrentHashMap<>());

    // ------------------------------------------------------------------ 壳的 ABI

    /** 壳调用的入口：返回承载 payload 站点类的加载器。 */
    public static Object getLoader(Object context) {
        Payload payload = payloadFor(locatePayload(context));
        // 壳的 `InitOrigin.context()` 在桌面端必须是非 null，否则载荷里的
        // `context().getSharedPreferences(...)` 会 NPE（实测 wex 系在 playerContent 里这么用，
        // 表现为「首页能出、播放必失败」）。这里把宿主注入的 Context 塞进它的单例字段。
        installContext(payload, context);
        return payload.loader;
    }

    /**
     * 壳调用的入口：在 payload 里解析站点实现并实例化。
     *
     * <p>实测 BaseSpiderGuard 的构造器就把自己的全限定类名传进来
     * （Init.getSpider(this.getClass().getName())），此时 Init.loader() 还是 null
     * （Init.init(Context) 从未被调用），所以 loader 只能当提示用，真正的定位靠调用方
     * 类的来源与 payload.jar 的装配约定。
     */
    public static Object getSpider(Object loader, String name) {
        String requested = name == null ? "" : name.trim();
        if (requested.isEmpty()) {
            throw new IllegalStateException(
                    "DexNative.getSpider 收到空类名：壳没有把站点类名传下来，无法定位 payload 里的实现");
        }
        Payload payload = payloadForLoader(loader instanceof ClassLoader hint ? hint : null);
        // 有些壳先调 getSpider 再补 getLoader：用最近一次的宿主 Context 补注入。
        installContext(payload, LAST_CONTEXT);
        List<String> misses = new ArrayList<>();
        Class<?> type = resolveSpiderClass(payload, requested, misses);
        Object instance = instantiate(type, requested);
        currentSpiderClass = type;
        log("DexNative 已解析站点实现：壳类名=" + requested + " → payload 类=" + type.getName());
        return instance;
    }

    /**
     * 壳调用的入口：把本地代理请求转给 payload 的 public static Object[] proxy(Map)。
     *
     * <p>壳只传两样东西：target（通常是 loader）与参数 Map；返回形态固定是 Object[]
     * （CatVod 的 proxy 约定），所以不是 Map 的参数、不是 Object[] 的返回值都要当场说清。
     */
    public static Object[] proxyInvoke(Object target, Object args) {
        if (!(args instanceof Map<?, ?> arguments)) {
            throw new IllegalArgumentException("代理参数必须是 Map");
        }
        Class<?> fallback = target instanceof Class<?> type ? type
                : target instanceof ClassLoader ? currentSpiderClass
                : target == null ? currentSpiderClass : target.getClass();
        if (fallback == null) throw new IllegalStateException("代理站源尚未加载");
        return invokeProxy(fallback, arguments);
    }

    private static Class<?> proxyTarget(Class<?> fallback) {
        Class<?> current = currentSpiderClass;
        if (current != null) {
            for (Payload payload : PAYLOADS.values()) {
                if (payload.loader == current.getClassLoader()) return current;
            }
        }
        return fallback;
    }

    public static Method proxyMethod(Class<?> fallback) {
        return proxyMethod(fallback, null);
    }

    public static boolean supportsSpiderProxy(Object spider) {
        return proxyMethod(spider.getClass(), spider) != null;
    }

    private static Method proxyMethod(Class<?> fallback, Object receiver) {
        Class<?> target = proxyTarget(fallback);
        Method method = PROXY_METHODS.computeIfAbsent(target, DexNative::findProxyMethod);
        if (method != null && !Modifier.isStatic(method.getModifiers()) && !target.isInstance(receiver)) {
            throw new IllegalStateException("实例代理处理器需要匹配的站源实例");
        }
        return method;
    }

    private static Method findProxyMethod(Class<?> target) {
        ClassLoader loader = target.getClassLoader();
        try {
            Class<?> router = Class.forName("com.github.catvod.spider.ProxyOrigin", false, loader);
            if (router.getClassLoader() == loader) {
                Method method = router.getMethod("proxy", Map.class);
                if (!Modifier.isStatic(method.getModifiers()) || method.getReturnType() != Object[].class)
                    throw new IllegalStateException("代理路由必须是静态 Object[] 方法");
                return method;
            }
        } catch (ClassNotFoundException | NoSuchMethodException absent) {
            // Only an absent router permits the verified direct-spider fallback.
        }
        try {
            Method method = target.getMethod("proxy", Map.class);
            if (method.getReturnType() != Object[].class)
                throw new IllegalStateException("代理处理器必须返回 Object[]");
            if (target.getName().equals("com.github.catvod.spider.Proxy")) return null;
            return method;
        } catch (NoSuchMethodException absent) {
            return null;
        }
    }

    public static void attachProxy(Class<?> fallback) {
        ClassLoader loader = proxyTarget(fallback).getClassLoader();
        try {
            Class<?> router = Class.forName("com.github.catvod.spider.ProxyOrigin", false, loader);
            if (router.getClassLoader() == loader) router.getMethod("init").invoke(null);
        } catch (ClassNotFoundException | NoSuchMethodException absent) {
            // Ordinary direct proxy implementations have no discovery initializer.
        } catch (InvocationTargetException error) {
            throw new IllegalStateException("代理入口初始化失败", error.getTargetException());
        } catch (IllegalAccessException error) {
            throw new IllegalStateException("代理入口不可访问", error);
        }
    }

    public static Object[] invokeProxy(Class<?> fallback, Map<?, ?> arguments) {
        return invokeProxy(fallback, null, arguments);
    }

    public static Object[] invokeSpiderProxy(Object spider, Map<?, ?> arguments) {
        return invokeProxy(spider.getClass(), spider, arguments);
    }

    private static Object[] invokeProxy(Class<?> fallback, Object receiver, Map<?, ?> arguments) {
        Method method = proxyMethod(fallback, receiver);
        if (method == null) throw new UnsupportedOperationException("站源没有代理路由");
        try {
            Object result = method.invoke(Modifier.isStatic(method.getModifiers()) ? null : receiver, arguments);
            if (result instanceof Object[] array) return array;
            throw new IllegalStateException("代理路由未返回 Object[]");
        } catch (InvocationTargetException error) {
            throw new IllegalStateException("站源代理执行失败", error.getTargetException());
        } catch (IllegalAccessException error) {
            throw new IllegalStateException("站源代理不可访问", error);
        }
    }

    // -------------------------------------------------------------- 类名解析

    /** 按「名字能不能对上」的顺序解析站点实现类；全都不中才用兜底，且绝不猜。 */
    /**
     * 把宿主 Context 注入载荷的上下文持有者。
     *
     * <p>为什么是反射、而不是直接调 {@code InitOrigin.init(Context)}：那个方法的字节码会调
     * {@code com.wexfnw.libso.LoadNiMa.init()}（壳自己的 native 库）。桌面端没有那个 .so，
     * 调用直接 UnsatisfiedLinkError；我们只需要它顺手写下的那个 Application 字段，
     * 所以只拷字段，不执行它的 native 初始化。
     */
    private static void installContext(Payload payload, Object context) {
        if (context == null) return;
        LAST_CONTEXT = context;
        ClassLoader loader = payload.loader;
        if (!CONTEXT_INSTALLED.add(loader)) return;
        try {
            Object app = context instanceof android.app.Application
                    ? context
                    : new android.app.Application((android.content.Context) context);
            int installed = 0;
            for (String className : new String[]{
                    "com.github.catvod.spider.InitOrigin",
                    "com.github.catvod.spider.Init",
                    "com.github.catvod.spider.AwInit"}) {
                Class<?> holder;
                try {
                    holder = Class.forName(className, false, loader);
                } catch (ClassNotFoundException absent) {
                    continue;
                }
                Object instance = null;
                try {
                    instance = holder.getMethod("get").invoke(null);
                } catch (Throwable ignored) {
                    // 没有 get() 就只处理静态字段。
                }
                // 按**字段名**取，不要枚举：`getDeclaredFields()` 会把所有字段的签名都解析
                // 一遍，壳的 InitOrigin 里有 `android.app.Activity d` 这种我们**刻意不垫**
                // 的 UI 类型，一解析就 NoClassDefFoundError（实测）。
                installed += assignField(holder, instance, app, "c");
                installed += assignField(holder, instance, app, "context");
                installed += assignField(holder, instance, app, "app");
                installed += assignField(holder, instance, app, "application");
            }
            if (installed == 0) {
                CONTEXT_INSTALLED.remove(loader);
                log("[shell-shim] 未找到可注入的上下文字段（InitOrigin/Init/AwInit）——"
                        + "载荷若在播放阶段读 context() 会 NPE");
            } else {
                log("[shell-shim] 已把宿主 Context 注入壳的上下文持有者：字段数=" + installed);
            }
        } catch (Throwable error) {
            CONTEXT_INSTALLED.remove(loader);
            log("[shell-shim] 注入宿主 Context 失败：" + error);
        }
    }
    /** 把一个 Application 值写进持有者的指定字段（字段不存在/类型不符/不可写都返回 0）。 */
    private static int assignField(Class<?> holder, Object instance, Object app, String name) {
        try {
            java.lang.reflect.Field field = holder.getDeclaredField(name);
            if (!field.getType().isInstance(app)) return 0;
            if (java.lang.reflect.Modifier.isFinal(field.getModifiers())) return 0;
            boolean isStatic = java.lang.reflect.Modifier.isStatic(field.getModifiers());
            if (!isStatic && instance == null) return 0;
            field.setAccessible(true);
            field.set(isStatic ? null : instance, app);
            return 1;
        } catch (NoSuchFieldException absent) {
            return 0;
        } catch (Throwable ignored) {
            return 0;
        }
    }
    private static Class<?> resolveSpiderClass(Payload payload, String requested, List<String> misses) {
        for (String candidate : candidates(requested)) {
            Class<?> type = payload.spiderClass(candidate, misses);
            if (type != null) {
                return type;
            }
        }

        // 兜底一：壳类名与 payload 类名不是简单对应。实测 WexHanXiaoQuanGuard 的真实现是
        // WexAiHanXiaoQuan——中间插了一段 Ai，所以「连续子串包含」对它无解，改用
        // 「字符按下标顺序出现」的子序列匹配（大小写不敏感）。只认实现了 Spider 的顶层类。
        String base = stripGuard(simpleName(requested));
        List<String> matched = new ArrayList<>();
        for (String fqn : payload.topLevelClasses()) {
            if (!isSubsequence(base, simpleName(fqn))) {
                continue;
            }
            if (payload.spiderClass(fqn, new ArrayList<>()) != null) {
                matched.add(fqn);
            }
        }
        if (matched.size() == 1) {
            log("DexNative 子序列兜底命中：壳类名=" + requested + " → payload 类=" + matched.get(0));
            return payload.spiderClass(matched.get(0), misses);
        }
        if (matched.size() > 1) {
            throw new IllegalStateException(
                    "payload 里按类名无法唯一确定站点实现（壳类名=" + requested + "）：候选=" + matched
                            + "；为避免猜错，请人工确认后为该站点指定入口类名");
        }

        // 兜底二：payload 里恰好只有一个 Spider 实现时，它就是唯一的答案。
        List<String> implementations = payload.spiderImplementations();
        if (implementations.size() == 1) {
            log("DexNative 唯一实现兜底：壳类名=" + requested + " → payload 类=" + implementations.get(0)
                    + "（payload 里只有这一个 Spider 实现）");
            return payload.spiderClass(implementations.get(0), misses);
        }
        throw new IllegalStateException(
                "payload 里找不到站点实现：壳类名=" + requested
                        + "；已尝试=" + candidates(requested)
                        + "；子序列匹配=0 个"
                        + "；payload 里的 Spider 实现=" + summarize(implementations)
                        + (misses.isEmpty() ? "" : "；加载失败：" + summarize(misses)));
    }

    /** 候选类名：原样 → 去 Guard → 追加 Guard（去重，保持顺序）。 */
    private static List<String> candidates(String requested) {
        LinkedHashSet<String> names = new LinkedHashSet<>();
        names.add(qualify(requested));
        String simple = simpleName(requested);
        String base = stripGuard(simple);
        names.add(qualify(base));
        if (!simple.endsWith(GUARD_SUFFIX)) {
            names.add(qualify(simple + GUARD_SUFFIX));
        }
        return new ArrayList<>(names);
    }

    private static String qualify(String name) {
        String trimmed = name == null ? "" : name.trim();
        if (trimmed.isEmpty() || trimmed.indexOf('.') >= 0) {
            return trimmed;
        }
        return PAYLOAD_PACKAGE + "." + trimmed;
    }

    private static String simpleName(String fqn) {
        String text = fqn == null ? "" : fqn.trim();
        int dot = text.lastIndexOf('.');
        return dot < 0 ? text : text.substring(dot + 1);
    }

    private static String stripGuard(String simple) {
        if (simple.endsWith(GUARD_SUFFIX) && simple.length() > GUARD_SUFFIX.length()) {
            return simple.substring(0, simple.length() - GUARD_SUFFIX.length());
        }
        return simple;
    }

    /** base 的字符是否按下标顺序出现在 text 里（大小写不敏感）。 */
    private static boolean isSubsequence(String base, String text) {
        String needle = base == null ? "" : base.toLowerCase(Locale.ROOT);
        if (needle.isEmpty()) {
            return false;
        }
        String haystack = text == null ? "" : text.toLowerCase(Locale.ROOT);
        int at = 0;
        for (int i = 0; i < haystack.length() && at < needle.length(); i++) {
            if (haystack.charAt(i) == needle.charAt(at)) {
                at++;
            }
        }
        return at == needle.length();
    }

    private static Object instantiate(Class<?> type, String requested) {
        try {
            Constructor<?> constructor = type.getDeclaredConstructor();
            if (!constructor.canAccess(null)) {
                constructor.setAccessible(true);
            }
            return constructor.newInstance();
        } catch (InvocationTargetException error) {
            Throwable cause = error.getTargetException() == null ? error : error.getTargetException();
            throw new IllegalStateException(
                    "payload 里的站点类实例化失败：" + type.getName()
                            + "（壳类名=" + requested + "）：" + cause, cause);
        } catch (ReflectiveOperationException | RuntimeException error) {
            throw new IllegalStateException(
                    "payload 里的站点类没有可用的无参构造器：" + type.getName()
                            + "（壳类名=" + requested + "）：" + error, error);
        }
    }

    // -------------------------------------------------------------- payload 定位

    /**
     * 定位 payload.jar（优先级：系统属性 → 站点目录 → user.dir）。
     *
     * <p>找不到就抛：静默返回 null 会让壳那边的空指针被吞成「首页 0 条目」，
     * 用户看到的是站点空着，而不是「payload 没装配」。
     */
    private static File locatePayload(Object context) {
        String explicit = System.getProperty(PAYLOAD_PROPERTY, "").trim();
        if (!explicit.isEmpty()) {
            File file = asPayloadFile(Path.of(explicit));
            if (file != null) {
                return file;
            }
            // 显式指定了却找不到：不回退到别的目录，否则用户以为属性生效了，实际在用另一份 payload。
            throw new IllegalStateException(
                    "未找到解包产物 payload.jar：系统属性 " + PAYLOAD_PROPERTY + "=" + explicit
                            + " 指向的 " + PAYLOAD_FILE + " 不存在或为空");
        }

        List<Path> directories = new ArrayList<>();
        addDirectory(directories, siteDirOf(context));
        Path callerSiteDir = siteDirOfCaller();
        addDirectory(directories, callerSiteDir);
        // 调用方类也可能来自 <站点目录>/payload-dex/dexBundles/，它的上一级才是站点目录。
        if (callerSiteDir != null) {
            addDirectory(directories, callerSiteDir.getParent());
        }
        addDirectory(directories, Path.of(System.getProperty("user.dir", ".")));

        List<String> tried = new ArrayList<>();
        for (Path directory : directories) {
            File file = directory.resolve(PAYLOAD_FILE).toFile();
            if (file.isFile() && file.length() > 0) {
                return file;
            }
            tried.add(file.getPath());
        }
        throw new IllegalStateException(
                "未找到解包产物 payload.jar：" + String.join("、", tried)
                        + "；壳站点需要把 payload 放在壳 jar 同目录，"
                        + "或用 -D" + PAYLOAD_PROPERTY + "=<路径> 显式指定");
    }

    /** 显式值既可以是目录（取其中的 payload.jar），也可以直接是文件。 */
    private static File asPayloadFile(Path path) {
        File file = path.toFile();
        if (file.isDirectory()) {
            file = path.resolve(PAYLOAD_FILE).toFile();
        }
        return file.isFile() && file.length() > 0 ? file : null;
    }

    private static void addDirectory(List<Path> directories, Path directory) {
        if (directory == null) {
            return;
        }
        Path normalized = directory.toAbsolutePath().normalize();
        if (!directories.contains(normalized)) {
            directories.add(normalized);
        }
    }

    /**
     * 从宿主给的 Context 反推站点目录。
     *
     * <p>宿主的 WebhtvContext.root() 是 <站点目录>/.webhtv-context；
     * 退化路径用 getFilesDir()（<root>/files）往上两级。
     */
    private static Path siteDirOf(Object context) {
        if (context == null) {
            return null;
        }
        try {
            Object root = context.getClass().getMethod("root").invoke(context);
            if (root instanceof File file && file.getParentFile() != null) {
                return file.getParentFile().toPath();
            }
        } catch (ReflectiveOperationException | RuntimeException ignored) {
            // 不是宿主 Context（真机 Application 没有 root()）：交给下一条路径。
        }
        try {
            Object files = context.getClass().getMethod("getFilesDir").invoke(context);
            if (files instanceof File file) {
                File root = file.getParentFile();
                if (root != null && root.getParentFile() != null) {
                    return root.getParentFile().toPath();
                }
            }
        } catch (ReflectiveOperationException | RuntimeException ignored) {
            // 同上：拿不到就当这条路径不成立。
        }
        return null;
    }

    /**
     * 从调用方类的来源反推站点目录。
     *
     * <p>Init 与各个 XxxGuard 都在站源加载器里（<站点目录>/index.jar 或它的转译产物
     * <站点目录>/dexBundles/classes.jar），所以它们的 CodeSource 就是站点目录的可靠证据
     * ——这也是 Init.loader() 还是 null 时唯一不靠猜的线索。
     */
    private static Path siteDirOfCaller() {
        List<StackWalker.StackFrame> frames =
                StackWalker.getInstance(StackWalker.Option.RETAIN_CLASS_REFERENCE)
                        .walk(stream -> stream
                                .filter(frame -> !DexNative.class.getName().equals(frame.getClassName()))
                                .limit(1)
                                .toList());
        if (frames.isEmpty()) {
            return null;
        }
        Class<?> caller = frames.get(0).getDeclaringClass();
        java.security.ProtectionDomain domain = caller.getProtectionDomain();
        java.security.CodeSource source = domain == null ? null : domain.getCodeSource();
        if (source == null || source.getLocation() == null) {
            return null;
        }
        Path located;
        try {
            located = Path.of(source.getLocation().toURI());
        } catch (java.net.URISyntaxException | RuntimeException error) {
            return null;
        }
        return siteDirOfLoadPath(located);
    }

    /** <站点目录>/dexBundles/classes.jar 与 <站点目录>/index.jar 都要回到站点目录。 */
    private static Path siteDirOfLoadPath(Path loadPath) {
        Path parent = loadPath.getParent();
        if (parent == null) {
            return loadPath;
        }
        Path name = parent.getFileName();
        boolean bundle = name != null
                && ("dexBundles".equals(name.toString()) || name.toString().startsWith("payload-dex"));
        return bundle && parent.getParent() != null ? parent.getParent() : parent;
    }

    // -------------------------------------------------------------- payload 加载

    private static Payload payloadForLoader(ClassLoader hint) {
        if (hint != null) {
            for (Payload payload : PAYLOADS.values()) {
                if (payload.loader == hint) {
                    return payload;
                }
            }
        }
        return payloadFor(locatePayload(null));
    }

    private static Payload payloadFor(File jarFile) {
        Path jar = jarFile.toPath().toAbsolutePath().normalize();
        String key = jar.toString();
        Payload cached = PAYLOADS.get(key);
        if (cached != null) {
            return cached;
        }
        synchronized (DexNative.class) {
            cached = PAYLOADS.get(key);
            if (cached != null) {
                return cached;
            }
            Payload opened = open(jar);
            PAYLOADS.put(key, opened);
            return opened;
        }
    }

    /**
     * 打开 payload：dex 形态先转译成 class jar，class jar 直接用。
     *
     * <p>真实 payload 都是 classes.dex（解包产物来自 dex），而 JVM 的类加载器读不了 dex，
     * 所以这一步不是可选项。
     */
    private static Payload open(Path jar) {
        Path classes = jar;
        if (DexIntake.hasDexArchive(jar)) {
            Path siteDir = jar.getParent();
            Path dexSite = (siteDir == null ? jar : siteDir).resolve(PAYLOAD_DEX_DIR);
            try {
                DexIntake.Result translated = DexIntake.translate(jar, dexSite);
                classes = translated.bundle();
                log("DexNative 已转译 payload：" + jar + " → " + classes
                        + "（classes=" + translated.classCount()
                        + " cached=" + translated.cached() + "）");
            } catch (DexIntake.DexIntakeException error) {
                throw new IllegalStateException(
                        "payload.jar 的 dex 转译失败（" + error.getMessage() + "）：" + jar, error);
            }
        }
        URL url;
        try {
            url = classes.toUri().toURL();
        } catch (MalformedURLException error) {
            throw new IllegalStateException("payload 类路径无法解析：" + classes, error);
        }
        URLClassLoader loader = new URLClassLoader(
                new URL[] {url}, DexNative.class.getClassLoader());
        return new Payload(loader, classEntries(classes));
    }

    private static List<String> classEntries(Path archive) {
        List<String> names = new ArrayList<>();
        try (ZipFile zip = new ZipFile(archive.toFile())) {
            Enumeration<? extends ZipEntry> entries = zip.entries();
            while (entries.hasMoreElements()) {
                ZipEntry entry = entries.nextElement();
                String name = entry.getName();
                if (entry.isDirectory() || !name.endsWith(".class") || name.indexOf('$') >= 0) {
                    // 内部类（如 WexAiHanXiaoQuan$Token）不是站点入口，带 $ 的一律跳过。
                    continue;
                }
                names.add(name.substring(0, name.length() - ".class".length()).replace('/', '.'));
            }
        } catch (IOException error) {
            throw new IllegalStateException(
                    "读取 payload 类清单失败：" + archive + "：" + error.getMessage(), error);
        }
        return names;
    }

    private static String summarize(List<String> values) {
        if (values.isEmpty()) {
            return "0 个";
        }
        int limit = Math.min(values.size(), 8);
        String head = String.join("、", values.subList(0, limit));
        return values.size() <= limit ? head : head + " 等 " + values.size() + " 个";
    }

    /** 日志一律走 stderr：stdout 被协议帧独占（§9.3.1）。 */
    private static void log(String message) {
        System.err.println(message);
        System.err.flush();
    }

    // -------------------------------------------------------------- payload 缓存项

    private static final class Payload {

        private final URLClassLoader loader;
        private final List<String> classNames;
        private volatile List<String> spiders;

        private Payload(URLClassLoader loader, List<String> classNames) {
            this.loader = loader;
            this.classNames = classNames;
        }

        List<String> topLevelClasses() {
            return classNames;
        }

        /** 该名字对应的类是否为 Spider 实现（不是、或缺依赖加载不起来 → null，原因记进 misses）。 */
        Class<?> spiderClass(String fqn, List<String> misses) {
            try {
                Class<?> type = Class.forName(fqn, false, loader);
                Class<?> base = Class.forName(SPIDER_BASE, false, loader);
                if (base.isAssignableFrom(type)) {
                    return type;
                }
                misses.add(fqn + " 不是 Spider 实现");
                return null;
            } catch (ClassNotFoundException | LinkageError | RuntimeException error) {
                misses.add(fqn + " 无法加载（" + error.getClass().getSimpleName()
                        + "：" + error.getMessage() + "）");
                return null;
            }
        }

        /** payload 里所有顶层 Spider 实现（懒算：只有名字全对不上时才需要枚举）。 */
        List<String> spiderImplementations() {
            List<String> cached = spiders;
            if (cached != null) {
                return cached;
            }
            List<String> found = new ArrayList<>();
            for (String fqn : classNames) {
                if (spiderClass(fqn, new ArrayList<>()) != null) {
                    found.add(fqn);
                }
            }
            spiders = found;
            return found;
        }
    }
}
