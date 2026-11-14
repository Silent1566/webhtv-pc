package fixture;

import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.net.HttpURLConnection;
import java.net.URI;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import webhtv.spider.CallContext;
import webhtv.spider.Json;
import webhtv.spider.Spider;

/**
 * 正常站源 fixture：通过本地 fixture 服务提供 home/category/detail/search/play。
 *
 * <p>用途与 Python 侧 {@code fixture_spider.py} 一致：作为「JVM sidecar 宿主 + 进程隔离」
 * 验收里的**成功路径**样本，同时充当可重复的桌面 Java 站源样本。
 *
 * <p>它只依赖 JDK 标准库（{@code HttpURLConnection} 与自带 {@code Json}），因此不引入任何
 * 第三方依赖（§20.3）。基地址按「{@code extend} 参数 → manifest {@code config.base} → 默认值」
 * 解析（与 Python/JS fixture 同语义）：测试里 fixture 服务用随机端口，必须经
 * {@code extend} 注入，否则站源会请求默认的 18080。入口类名可由
 * {@code --class fixture.FixtureSpider} 或 manifest {@code config.className} 指定。
 */
public final class FixtureSpider extends Spider {
    private static final String DEFAULT_BASE = "http://127.0.0.1:18080";
    private static final String USER_AGENT = "WebHTV-PC/0.1 (Windows)";

    private String base = DEFAULT_BASE;

    @Override
    public void init(String extend) {
        Object config = manifest.get("config");
        if (config instanceof Map<?, ?> map && map.get("base") != null) {
            base = String.valueOf(map.get("base"));
        }
        // extend 优先于 manifest：站点 `ext` 是用户/配置层可覆盖的值（§7.4.5）。
        // 与 JS fixture 同语义：非 JSON 文本按纯基地址处理。
        String text = extend == null ? "" : extend.trim();
        if (!text.isEmpty()) {
            String fromExtend = baseFromExtend(text);
            if (fromExtend != null && !fromExtend.isEmpty()) {
                base = fromExtend;
            }
        }
    }

    /** 从 extend（JSON 对象或纯字符串）取出 base；解析失败时返回 null（不静默改成默认值）。 */
    private static String baseFromExtend(String text) {
        if (!text.startsWith("{")) {
            return text;
        }
        try {
            Object parsed = Json.parse(text);
            if (parsed instanceof Map<?, ?> map && map.get("base") != null) {
                return String.valueOf(map.get("base"));
            }
        } catch (RuntimeException error) {
            return null;
        }
        return null;
    }

    @Override
    public List<String> capabilities() {
        return List.of("home", "category", "detail", "search", "play");
    }

    @Override
    protected Map<String, Object> homeContent(boolean filter, CallContext context) {
        context.checkCancelled();
        return getJson("/api/type1/");
    }

    @Override
    protected Map<String, Object> categoryContent(
            String tid, String page, boolean filter, Map<String, Object> extend, CallContext context) {
        context.checkCancelled();
        String typeId = tid == null || tid.isEmpty() ? "1" : tid;
        int effectivePage = pageOf(page);
        Map<String, Object> raw = getJson("/api/type1/?t=" + typeId + "&pg=" + effectivePage);
        // 与 Python/JS fixture 同语义：fixture 服务始终返回 page=1，这里回显**请求**的
        // 页码并声明多页，否则分页用例（第 2 页）会被服务端数据覆盖成 1。
        Map<String, Object> result = new LinkedHashMap<>(raw);
        result.put("page", effectivePage);
        result.put("pagecount", 2);
        Object list = raw.get("list");
        result.put("total", list instanceof List<?> items ? items.size() * 2 : 0);
        return result;
    }

    @Override
    protected Map<String, Object> detailContent(List<String> ids, CallContext context) {
        context.checkCancelled();
        String id = ids.isEmpty() ? "" : ids.get(0);
        return getJson("/api/type1/?ac=detail&ids=" + id);
    }

    @Override
    protected Map<String, Object> searchContent(
            String keyword, boolean quick, String page, CallContext context) {
        context.checkCancelled();
        int effectivePage = pageOf(page);
        return getJson("/api/type1/?wd=" + keyword + "&pg=" + effectivePage);
    }

    @Override
    protected Map<String, Object> playerContent(
            String flag, String id, List<String> vipFlags, CallContext context) {
        context.checkCancelled();
        String url = id;
        String effectiveFlag = flag == null || flag.isEmpty() ? "sidecar" : flag;
        int comma = id.indexOf(',');
        if (comma >= 0) {
            url = id.substring(0, comma);
            String tail = id.substring(comma + 1);
            if (!tail.isEmpty()) {
                effectiveFlag = tail;
            }
        }
        if (url.isEmpty()) {
            throw new IllegalArgumentException("缺少 id");
        }
        Map<String, Object> result = new LinkedHashMap<>();
        result.put("url", url);
        result.put("flag", effectiveFlag);
        result.put("format", "application/vnd.apple.mpegurl");
        result.put("header", new LinkedHashMap<String, Object>());
        return result;
    }

    // ---------------------------------------------------------------- HTTP

    @SuppressWarnings("unchecked")
    private Map<String, Object> getJson(String path) {
        if (!base.startsWith("http://") && !base.startsWith("https://")) {
            throw new IllegalArgumentException("站源基地址必须是 http(s)：" + base);
        }
        HttpURLConnection connection = null;
        try {
            connection = (HttpURLConnection) URI.create(base + path).toURL().openConnection();
            connection.setRequestMethod("GET");
            connection.setRequestProperty("User-Agent", USER_AGENT);
            connection.setConnectTimeout(10_000);
            connection.setReadTimeout(10_000);
            int status = connection.getResponseCode();
            if (status < 200 || status >= 300) {
                throw new IllegalStateException("fixture 返回 HTTP " + status + "（" + path + "）");
            }
            ByteArrayOutputStream buffer = new ByteArrayOutputStream();
            try (InputStream stream = connection.getInputStream()) {
                byte[] chunk = new byte[8192];
                int read;
                while ((read = stream.read(chunk)) > 0) {
                    buffer.write(chunk, 0, read);
                }
            }
            Object parsed = Json.parse(buffer.toString(StandardCharsets.UTF_8));
            if (parsed instanceof Map<?, ?> map) {
                return (Map<String, Object>) map;
            }
            throw new IllegalStateException("fixture 返回的不是 JSON 对象");
        } catch (java.io.IOException error) {
            throw new IllegalStateException("fixture 请求失败：" + error.getMessage(), error);
        } finally {
            if (connection != null) {
                connection.disconnect();
            }
        }
    }

    private static int pageOf(String page) {
        if (page == null) {
            return 1;
        }
        try {
            int value = Integer.parseInt(page.trim());
            return value >= 1 ? value : 1;
        } catch (NumberFormatException error) {
            return 1;
        }
    }

    /** 供 `createSpider(manifest)` 工厂形态使用。 */
    public static Spider createSpider(Map<String, Object> manifest) {
        FixtureSpider spider = new FixtureSpider();
        spider.manifest = manifest == null ? new LinkedHashMap<>() : manifest;
        return spider;
    }

    /** 便于测试构造不依赖 manifest 的实例。 */
    public static FixtureSpider withBase(String base) {
        FixtureSpider spider = new FixtureSpider();
        spider.base = base;
        return spider;
    }

    static List<String> emptyList() {
        return new ArrayList<>();
    }
}
