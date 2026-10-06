package webhtv.spider;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.atomic.AtomicBoolean;

/**
 * 桌面 JVM Spider ABI（`tvbox-java-v1`，设计文档 §9.2、§9.3）。
 *
 * <p>与 Android `Spider` 基类的**关键差别**：这里没有 {@code android.content.Context}、
 * 没有 {@code DexClassLoader}、没有 Android 工具类。桌面站源只承诺
 * {@code init(String)} 或 {@code init()} 形态（§9.9），因此可以直接被 JVM 加载。
 *
 * <p>实现类约定：
 * <ul>
 *   <li>继承本类（{@code extends webhtv.spider.Spider}）或提供 {@code createSpider(manifest)}；
 *       入口类名由站点配置的 {@code api} 给出（如 {@code csp_PianDan} → 类名
 *       {@code csp_PianDan}，或配置显式给出全限定名）。</li>
 *   <li>实现 {@code home/category/detail/search/play} 中需要的能力，并在
 *       {@link #capabilities()} 里声明；未声明的方法返回 {@code SPIDER_UNSUPPORTED}（§9.7）。</li>
 *   <li>耗时操作必须周期性调用 {@link CallContext#checkCancelled()}，让取消/超时生效。</li>
 *   <li>只返回协议结构（{@code class/filters/list/vod_* /url/header}），不要碰 stdout。</li>
 * </ul>
 *
 * <p>为兼容参考实现（`CatVodSpider-PC` 风格的 Java 站源）与 TVBox 常用命名，本类同时
 * 提供 TVBox 风格的方法名（{@code homeContent/categoryContent/detailContent/}
 * {@code searchContent/playerContent}）。子类实现任一套即可，另一套会自动桥接。
 */
public abstract class Spider {

    /** 站点 key；由宿主在实例化后写入，供多站点共享同一实现时区分（对齐 TVBox `siteKey`）。 */
    public String siteKey = "";

    /** manifest 原文（只读约定）；子类可读取 {@code config} 等自定义段。 */
    protected Map<String, Object> manifest = new LinkedHashMap<>();

    // ------------------------------------------------------------ 生命周期

    /**
     * 初始化（§9.9：PC 原生运行时只承诺 {@code init(String)} 或 {@code init()}）。
     *
     * @param extend 站点 {@code ext}（对象按稳定 JSON 文本传递，§7.4.5）
     */
    public void init(String extend) {
        // 默认无操作：允许站源只实现 init()。
    }

    /** 无参数初始化；默认桥接到 {@link #init(String)}。 */
    public void init() {
        init("");
    }

    /** 释放线程、连接、文件与端口（§9.3 `destroy` 必需）。默认无操作。 */
    public void close() {
        // 默认无操作。
    }

    /**
     * 声明能力。默认从已重写的方法推断，子类可覆盖。
     *
     * <p>manifest 声明优先于本方法（§9.7：站源自报能力不得超出 manifest）。
     */
    public List<String> capabilities() {
        List<String> declared = new ArrayList<>();
        for (String method : List.of("home", "category", "detail", "search", "play")) {
            if (overrides(method) || overrides(tvboxName(method))) {
                declared.add(method);
            }
        }
        for (String method : List.of("homeVod", "live", "proxy", "action")) {
            if (overrides(method) || overrides(tvboxName(method))) {
                declared.add(method);
            }
        }
        return declared;
    }

    private boolean overrides(String method) {
        try {
            return getClass().getMethod(method, Map.class, CallContext.class)
                    .getDeclaringClass() != Spider.class;
        } catch (NoSuchMethodException error) {
            return false;
        }
    }

    private static String tvboxName(String method) {
        return switch (method) {
            case "home" -> "homeContent";
            case "homeVod" -> "homeVideoContent";
            case "category" -> "categoryContent";
            case "detail" -> "detailContent";
            case "search" -> "searchContent";
            case "play" -> "playerContent";
            case "live" -> "liveContent";
            case "action" -> "action";
            case "proxy" -> "proxy";
            default -> method;
        };
    }

    // ---------------------------------------------------------------- 方法

    /** 首页：分类、筛选与推荐列表（§9.3 必需）。 */
    public Map<String, Object> home(Map<String, Object> params, CallContext context) {
        Map<String, Object> raw = homeContent(params.get("filter") != null
                && Boolean.parseBoolean(String.valueOf(params.get("filter"))), context);
        return Result.normalizeHome(raw);
    }

    /** 首页推荐列表（§9.3 可选）。 */
    public Map<String, Object> homeVod(Map<String, Object> params, CallContext context) {
        Map<String, Object> raw = homeVideoContent(context);
        return Result.normalizeList(raw);
    }

    /** 分类分页（§9.3 必需）。 */
    public Map<String, Object> category(Map<String, Object> params, CallContext context) {
        String typeId = str(params.get("id"), str(params.get("t"), ""));
        String page = str(params.get("page"), "1");
        boolean filter = params.get("filter") != null
                && Boolean.parseBoolean(String.valueOf(params.get("filter")));
        Map<String, Object> extend = asMap(params.get("extend"));
        Map<String, Object> raw = categoryContent(typeId, page, filter, extend, context);
        return Result.normalizeCategory(raw, page);
    }

    /** 详情：多线路与多集（§9.3 必需）。 */
    public Map<String, Object> detail(Map<String, Object> params, CallContext context) {
        List<String> ids = new ArrayList<>();
        Object raw = params.get("ids");
        if (raw instanceof Iterable<?> iterable) {
            for (Object item : iterable) {
                ids.add(String.valueOf(item));
            }
        }
        if (ids.isEmpty()) {
            String single = str(params.get("id"), "");
            if (!single.isEmpty()) {
                ids.add(single);
            }
        }
        if (ids.isEmpty()) {
            throw new IllegalArgumentException("缺少 id/ids");
        }
        Map<String, Object> result = detailContent(ids, context);
        return Result.normalizeList(result);
    }

    /** 搜索：支持 quick/page 候选参数（§9.3 必需）。 */
    public Map<String, Object> search(Map<String, Object> params, CallContext context) {
        String keyword = str(params.get("keyword"), str(params.get("wd"), ""));
        if (keyword.isEmpty()) {
            throw new IllegalArgumentException("缺少 keyword");
        }
        boolean quick = params.get("quick") != null
                && Boolean.parseBoolean(String.valueOf(params.get("quick")));
        String page = str(params.get("page"), null);
        Map<String, Object> raw = searchContent(keyword, quick, page, context);
        return Result.normalizeCategory(raw, page == null ? "1" : page);
    }

    /** 播放：返回播放 URL、Header 与 parse/jx 语义（§9.3 必需）。 */
    public Map<String, Object> play(Map<String, Object> params, CallContext context) {
        String flag = str(params.get("flag"), "");
        String id = str(params.get("id"), "");
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
        Map<String, Object> raw = playerContent(flag, id, vipFlags, context);
        return Result.normalizePlay(raw, flag);
    }

    // ------------------------------------------- TVBox 风格钩子（子类覆盖）

    /** TVBox 风格：{@code homeContent(filter)}。 */
    protected Map<String, Object> homeContent(boolean filter, CallContext context) {
        throw new UnsupportedOperationException("未实现 homeContent");
    }

    /** TVBox 风格：{@code homeVideoContent()}。 */
    protected Map<String, Object> homeVideoContent(CallContext context) {
        throw new UnsupportedOperationException("未实现 homeVideoContent");
    }

    /** TVBox 风格：{@code categoryContent(tid, pg, filter, extend)}。 */
    protected Map<String, Object> categoryContent(
            String tid, String page, boolean filter, Map<String, Object> extend, CallContext context) {
        throw new UnsupportedOperationException("未实现 categoryContent");
    }

    /** TVBox 风格：{@code detailContent(ids)}。 */
    protected Map<String, Object> detailContent(List<String> ids, CallContext context) {
        throw new UnsupportedOperationException("未实现 detailContent");
    }

    /** TVBox 风格：{@code searchContent(key, quick, page)}。 */
    protected Map<String, Object> searchContent(
            String keyword, boolean quick, String page, CallContext context) {
        throw new UnsupportedOperationException("未实现 searchContent");
    }

    /** TVBox 风格：{@code playerContent(flag, id, vipFlags)}。 */
    protected Map<String, Object> playerContent(
            String flag, String id, List<String> vipFlags, CallContext context) {
        throw new UnsupportedOperationException("未实现 playerContent");
    }

    // ---------------------------------------------------------------- 工具

    protected static String str(Object value, String fallback) {
        if (value == null) {
            return fallback;
        }
        String text = String.valueOf(value);
        return text.isEmpty() ? fallback : text;
    }

    @SuppressWarnings("unchecked")
    protected static Map<String, Object> asMap(Object value) {
        if (value instanceof Map<?, ?> map) {
            return (Map<String, Object>) map;
        }
        return new LinkedHashMap<>();
    }
}
