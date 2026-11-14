package webhtv.spider;

import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

/**
 * CatVod 风格站源（{@code extends com.github.catvod.crawler.Spider}，返回 **JSON 字符串**）
 * 到 {@link Spider}（宿主 Map 语义）的适配器（ADR-0002 §2）。
 *
 * <p>为什么需要适配：Android 站源的公开方法返回 {@code String}（TVBox 约定），而宿主 ABI 的
 * {@code home/category/detail/search/play} 返回 {@code Map<String,Object>}。适配层只做
 * **方法名与取值形态**的翻译，不做业务解释：反射调用 CatVod 实例 → 用 {@link Json} 解析
 * JSON 文本 → 交给 {@link Result} 整形。
 *
 * <p>初始化**不在构造器里做**：{@code SidecarServer} 收到 {@code initialize} 帧后按 ABI 调
 * {@link #init(String)}，ext 走宿主既有通道（帧参数 {@code extend}，缺省取 manifest 的
 * {@code extend}）。构造器里 init 会让 ext 与握手时序错位。
 *
 * <p>异常语义（诊断契约）：站源抛出的 {@code UnsupportedOperationException} /
 * {@code IllegalArgumentException} 原样上抛；{@code NoClassDefFoundError} 一类链接错误包成
 * {@code UnsupportedOperationException} 并**点名缺失的类**——这类站源依赖不在 P1-2 垫片清单内
 * 的 Android 类（多为 UI），用户需要看到「缺哪个类」，而不是笼统的初始化失败。
 */
public final class CatVodSpiderAdapter extends Spider {

    /** CatVod 基类全限定名；用常量字符串经 {@code Class.forName} 在**同一个 loader** 里取。 */
    private static final String CATVOD_SPIDER_CLASS = "com.github.catvod.crawler.Spider";

    private final Object target;
    private final android.content.Context context;
    private final String targetClassName;
    private boolean inited;
    private boolean closed;

    public CatVodSpiderAdapter(Object catVodSpider, android.content.Context context) {
        if (catVodSpider == null) {
            throw new IllegalArgumentException("CatVod 站源实例为空");
        }
        this.target = catVodSpider;
        this.context = context;
        this.targetClassName = catVodSpider.getClass().getName();
    }

    // ------------------------------------------------------------ 生命周期

    /**
     * 调 CatVod 侧的 {@code init}。
     *
     * <p>**优先双参 {@code init(Context, String)}**：AList 等站点只调单参会去请求错误的默认
     * 地址（实测报 {@code Expected URL scheme 'http' or 'https' but no colon was found}）。
     * 单参形态只在类里确实没有双参重载时使用。
     */
    @Override
    public void init(String extend) {
        if (inited) {
            return;
        }
        String text = extend == null ? "" : extend;
        try {
            Method twoArg = findOptional("init", android.content.Context.class, String.class);
            if (twoArg != null) {
                twoArg.invoke(target, context, text);
            } else {
                target.getClass()
                        .getMethod("init", android.content.Context.class)
                        .invoke(target, context);
            }
            inited = true;
        } catch (InvocationTargetException error) {
            // 必须走 mapFailure 而不是自己取最内层 cause：init 阶段碰 UI 的站源
            // （如 Live）抛的是 ClassNotFoundException: android.app.Activity，
            // 只看最内层就会把它当成普通异常，用户拿不到「缺哪个 Android 类」这条信息。
            RuntimeException mapped = mapFailure("CatVod init", error.getTargetException());
            if (mapped instanceof UnsupportedOperationException unsupported) {
                throw unsupported;
            }
            throw new IllegalStateException(
                    "CatVod init 失败：" + targetClassName + "：" + mapped.getMessage(),
                    mapped);
        } catch (ReflectiveOperationException error) {
            throw new IllegalStateException(
                    "CatVod init 失败：" + targetClassName + "：找不到可用的 init(Context[, String])",
                    error);
        }
    }

    @Override
    public void close() {
        if (closed) {
            return;
        }
        closed = true;
        try {
            Method destroy = findOptional("destroy");
            if (destroy == null) {
                return;
            }
            destroy.invoke(target);
        } catch (InvocationTargetException error) {
            Ipc.log("CatVod destroy 失败：" + targetClassName + "：" + innermost(error.getTargetException()));
        } catch (ReflectiveOperationException | RuntimeException error) {
            Ipc.log("CatVod destroy 失败：" + targetClassName + "：" + error);
        }
    }

    // ---------------------------------------------------------------- 方法

    @Override
    public Map<String, Object> home(Map<String, Object> params, CallContext context) {
        context.checkCancelled();
        boolean filter = flag(params, "filter");
        Object raw = call("homeContent", new Class<?>[]{boolean.class}, filter);
        return Result.normalizeHome(asJsonObject("homeContent", raw));
    }

    @Override
    public Map<String, Object> homeVod(Map<String, Object> params, CallContext context) {
        context.checkCancelled();
        Object raw = call("homeVideoContent", new Class<?>[0]);
        return Result.normalizeList(asJsonObject("homeVideoContent", raw));
    }

    @Override
    public Map<String, Object> category(Map<String, Object> params, CallContext context) {
        context.checkCancelled();
        String typeId = text(params, "id", text(params, "t", ""));
        String page = text(params, "page", "1");
        boolean filter = flag(params, "filter");
        // 第 4 参**必须**是 java.util.HashMap：CatVod 基类/转译产物按该精确签名解析方法，
        // 传 LinkedHashMap 或 Map 都会让 getMethod 找不到方法。
        HashMap<String, String> extend = new HashMap<>();
        Object rawExtend = params.get("extend");
        if (rawExtend instanceof Map<?, ?> map) {
            for (Map.Entry<?, ?> entry : map.entrySet()) {
                extend.put(String.valueOf(entry.getKey()), String.valueOf(entry.getValue()));
            }
        }
        Object raw = call(
                "categoryContent",
                new Class<?>[]{String.class, String.class, boolean.class, HashMap.class},
                typeId, page, filter, extend);
        return Result.normalizeCategory(asJsonObject("categoryContent", raw), page);
    }

    @Override
    public Map<String, Object> detail(Map<String, Object> params, CallContext context) {
        context.checkCancelled();
        List<String> ids = new ArrayList<>();
        Object raw = params.get("ids");
        if (raw instanceof Iterable<?> iterable) {
            for (Object item : iterable) {
                ids.add(String.valueOf(item));
            }
        }
        if (ids.isEmpty()) {
            String single = text(params, "id", "");
            if (!single.isEmpty()) {
                ids.add(single);
            }
        }
        if (ids.isEmpty()) {
            throw new IllegalArgumentException("缺少 id/ids");
        }
        Object result = call("detailContent", new Class<?>[]{List.class}, ids);
        return Result.normalizeList(asJsonObject("detailContent", result));
    }

    @Override
    public Map<String, Object> search(Map<String, Object> params, CallContext context) {
        context.checkCancelled();
        String keyword = text(params, "keyword", text(params, "wd", ""));
        if (keyword.isEmpty()) {
            throw new IllegalArgumentException("缺少 keyword");
        }
        boolean quick = flag(params, "quick");
        Object raw = call("searchContent", new Class<?>[]{String.class, boolean.class}, keyword, quick);
        String page = text(params, "page", "1");
        return Result.normalizeCategory(asJsonObject("searchContent", raw), page);
    }

    @Override
    public Map<String, Object> play(Map<String, Object> params, CallContext context) {
        context.checkCancelled();
        String flag = text(params, "flag", "");
        String id = text(params, "id", "");
        if (id.isEmpty()) {
            throw new IllegalArgumentException("缺少 id");
        }
        List<String> vipFlags = new ArrayList<>();
        Object rawFlags = params.get("vipFlags");
        if (rawFlags instanceof Iterable<?> iterable) {
            for (Object item : iterable) {
                vipFlags.add(String.valueOf(item));
            }
        }
        Object raw = call(
                "playerContent",
                new Class<?>[]{String.class, String.class, List.class},
                flag, id, vipFlags);
        return Result.normalizePlay(asJsonObject("playerContent", raw), flag);
    }

    /**
     * 声明 CatVod 实例**实际实现**的能力：某个 TVBox 钩子的声明类不是基类（即站点自己写了）
     * 才算有该能力，基类的空实现不算（§9.7 能力必须真实）。
     *
     * <p>{@code live} 也按此探测：注意宿主 ABI 的 {@link Spider} 目前没有 live 钩子，
     * 该能力只在握手/列表里可见（见 P1-2 报告「已知风险」）。
     */
    @Override
    public List<String> capabilities() {
        List<String> declared = new ArrayList<>();
        if (implementsOn("homeContent", boolean.class)) {
            declared.add("home");
        }
        if (implementsOn("homeVideoContent")) {
            declared.add("homeVod");
        }
        if (implementsOn("categoryContent", String.class, String.class, boolean.class, HashMap.class)) {
            declared.add("category");
        }
        if (implementsOn("detailContent", List.class)) {
            declared.add("detail");
        }
        if (implementsOn("searchContent", String.class, boolean.class)) {
            declared.add("search");
        }
        if (implementsOn("playerContent", String.class, String.class, List.class)) {
            declared.add("play");
        }
        if (implementsOn("liveContent", String.class)) {
            declared.add("live");
        }
        return declared;
    }

    // ---------------------------------------------------------------- 反射

    private boolean implementsOn(String name, Class<?>... types) {
        Method method;
        try {
            method = target.getClass().getMethod(name, types);
        } catch (NoSuchMethodException missing) {
            return false;
        } catch (LinkageError error) {
            // 方法在、但签名里的类解析不了：按「有该能力」声明，让请求真正走到 call()，
            // 由那里给出点名缺失类名的可诊断错误，而不是在握手时静默少报能力。
            return true;
        }
        return !CATVOD_SPIDER_CLASS.equals(method.getDeclaringClass().getName());
    }

    /** 找不到返回 null（用于「可能没有」的方法）；其余反射错误照常抛出。 */
    private Method findOptional(String name, Class<?>... types) {
        try {
            return target.getClass().getMethod(name, types);
        } catch (NoSuchMethodException missing) {
            return null;
        }
    }

    private Object call(String method, Class<?>[] types, Object... arguments) {
        Method resolved;
        try {
            resolved = target.getClass().getMethod(method, types);
        } catch (NoSuchMethodException missing) {
            throw new UnsupportedOperationException(
                    "该站源未实现 " + method + "（" + targetClassName + "）");
        } catch (LinkageError error) {
            throw new UnsupportedOperationException(unsupportedAndroidMessage(error), error);
        }
        try {
            return resolved.invoke(target, arguments);
        } catch (InvocationTargetException error) {
            throw mapFailure(method, error.getTargetException());
        } catch (IllegalAccessException error) {
            throw new IllegalStateException(method + " 调用失败：" + error, error);
        }
    }

    /** 把站源抛出的异常映射成宿主可诊断的形态（§9.3.1）。 */
    private RuntimeException mapFailure(String method, Throwable thrown) {
        if (thrown == null) {
            return new IllegalStateException(method + " 调用失败：站源抛出空异常");
        }
        Throwable root = innermost(thrown);
        if (root instanceof UnsupportedOperationException unsupported) {
            return unsupported;
        }
        if (root instanceof IllegalArgumentException illegal) {
            return illegal;
        }
        // 链接错误必须查**整条 cause 链**：NoClassDefFoundError 的 cause 是 ClassNotFoundException，
        // 若只看「最内层 cause」就会落到普通异常分支，丢掉「缺哪个 Android 类」这条唯一有用的信息。
        LinkageError linkage = findLinkageError(thrown);
        if (linkage != null) {
            return new UnsupportedOperationException(unsupportedAndroidMessage(linkage), linkage);
        }
        if (root instanceof Error error) {
            if (root instanceof VirtualMachineError) {
                // OOM/StackOverflow 不是「缺 Android 类」：照实说是站点自身/资源的错。
                return new IllegalStateException(method + " 调用失败：" + root, root);
            }
            return new UnsupportedOperationException(unsupportedAndroidMessage(error), error);
        }
        return new IllegalStateException(method + " 调用失败：" + root, root);
    }

    private static LinkageError findLinkageError(Throwable error) {
        Throwable current = error;
        while (current != null) {
            if (current instanceof LinkageError linkage) {
                return linkage;
            }
            Throwable next = current.getCause();
            current = next == current ? null : next;
        }
        return null;
    }

    /**
     * 把「缺 Android 类」的链接错误翻译成用户能自查的一句话。
     * 加载阶段（{@link EntryLoader}）与调用阶段（本类）共用同一措辞。
     */
    static String unsupportedAndroidMessage(Throwable error) {
        return "该站源依赖不支持的 Android 类：" + missingClass(error)
                + "（P1-2 只支持不碰 UI 的站源）";
    }

    private static Throwable innermost(Throwable error) {
        Throwable current = error;
        while (current.getCause() != null && current.getCause() != current) {
            current = current.getCause();
        }
        return current;
    }

    /** 从链接错误的消息里取出缺失的类名（{@code NoClassDefFoundError} 的消息就是内部名）。 */
    private static String missingClass(Throwable error) {
        String message = error.getMessage();
        if (message == null || message.isBlank()) {
            return error.getClass().getName();
        }
        String text = message.trim();
        int space = text.indexOf(' ');
        String token = space > 0 ? text.substring(0, space) : text;
        return token.replace('/', '.');
    }

    // ---------------------------------------------------------------- JSON

    /** JSON 文本 → Map；{@code null}/空串按「站源没有内容」返回 null（不抛异常）。 */
    private Map<String, Object> asJsonObject(String method, Object raw) {
        if (raw == null) {
            return null;
        }
        String text = String.valueOf(raw);
        if (text.isBlank()) {
            return null;
        }
        Object parsed;
        try {
            parsed = Json.parse(text);
        } catch (RuntimeException error) {
            throw new IllegalArgumentException(
                    method + " 返回的内容不是合法 JSON：" + preview(text), error);
        }
        if (parsed instanceof Map<?, ?> map) {
            @SuppressWarnings("unchecked")
            Map<String, Object> result = (Map<String, Object>) map;
            return result;
        }
        throw new IllegalArgumentException(method + " 返回的不是 JSON 对象：" + preview(text));
    }

    private static String preview(String text) {
        return text.length() <= 200 ? text : text.substring(0, 200) + "…";
    }

    // ---------------------------------------------------------------- 工具

    private static boolean flag(Map<String, Object> params, String name) {
        Object value = params == null ? null : params.get(name);
        return value != null && Boolean.parseBoolean(String.valueOf(value));
    }

    private static String text(Map<String, Object> params, String name, String fallback) {
        Object value = params == null ? null : params.get(name);
        if (value == null) {
            return fallback;
        }
        String text = String.valueOf(value);
        return text.isEmpty() ? fallback : text;
    }
}
