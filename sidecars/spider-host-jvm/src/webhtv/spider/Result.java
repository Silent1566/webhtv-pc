package webhtv.spider;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * Result / Vod 协议整形（§8.3）。
 *
 * <p>宿主侧 {@code HttpApiResponseParser} 与 sidecar 返回的 Result 结构一致，因此这里
 * 只做**形状归一化**，不做语义解释：
 * <ul>
 *   <li>顶层统一含 {@code class/filters/list/page/pagecount/total}；</li>
 *   <li>Vod 字段保持 TVBox 原始键名（{@code vod_id/vod_name/vod_play_from/…}），
 *       与 Python/Node 站源返回一致，宿主侧复用同一套解析；</li>
 *   <li>缺失字段补默认值，非法条目丢弃并计数（不静默变成空列表）。</li>
 * </ul>
 */
public final class Result {
    private Result() {}

    public static Map<String, Object> empty() {
        Map<String, Object> result = new LinkedHashMap<>();
        result.put("class", new ArrayList<>());
        result.put("filters", new LinkedHashMap<String, Object>());
        result.put("list", new ArrayList<>());
        result.put("page", 1);
        result.put("pagecount", 1);
        result.put("total", 0);
        return result;
    }

    /** 首页整形：保留分类/筛选/推荐列表，缺字段补空。 */
    public static Map<String, Object> normalizeHome(Map<String, Object> raw) {
        Map<String, Object> result = empty();
        if (raw == null) {
            return result;
        }
        result.put("class", listOf(raw.get("class")));
        result.put("filters", mapOf(raw.get("filters")));
        result.put("list", vodList(raw.get("list")));
        result.put("total", result.get("list") instanceof List<?> list ? list.size() : 0);
        return result;
    }

    /** 列表整形（homeVod / detail）。 */
    public static Map<String, Object> normalizeList(Map<String, Object> raw) {
        Map<String, Object> result = empty();
        if (raw == null) {
            return result;
        }
        List<Object> list = vodList(raw.get("list"));
        result.put("list", list);
        result.put("total", list.size());
        if (raw.get("class") != null) {
            result.put("class", listOf(raw.get("class")));
        }
        if (raw.get("filters") != null) {
            result.put("filters", mapOf(raw.get("filters")));
        }
        return result;
    }

    /** 分类整形：page 取请求值（非法按 1），pagecount/total 缺失时按 1/列表长度。 */
    public static Map<String, Object> normalizeCategory(Map<String, Object> raw, String page) {
        Map<String, Object> result = empty();
        int effectivePage = parsePage(page);
        result.put("page", effectivePage);
        if (raw == null) {
            return result;
        }
        List<Object> list = vodList(raw.get("list"));
        result.put("list", list);
        result.put("class", listOf(raw.get("class")));
        result.put("filters", mapOf(raw.get("filters")));
        result.put("pagecount", intOf(raw.get("pagecount"), intOf(raw.get("pageCount"), 1)));
        result.put("total", intOf(raw.get("total"), list.size()));
        if (raw.get("page") != null) {
            result.put("page", intOf(raw.get("page"), effectivePage));
        }
        return result;
    }

    /**
     * 播放整形：对齐 §9.4 的宽松形态——{@code url} 可为字符串、平铺数组
     * （`["RAW","https://…"]`）或 `{values:[{n,v}]}` 对象；宿主取第一个可播放地址。
     */
    public static Map<String, Object> normalizePlay(Map<String, Object> raw, String flag) {
        Map<String, Object> result = new LinkedHashMap<>();
        Map<String, Object> source = raw == null ? new LinkedHashMap<>() : raw;
        Object url = source.get("url") != null ? source.get("url") : source.get("playUrl");
        result.put("url", url == null ? "" : url);
        result.put("flag", firstNonEmpty(source.get("flag"), flag, ""));
        result.put("header", mapOf(source.get("header")));
        if (source.get("format") != null) {
            result.put("format", source.get("format"));
        }
        if (source.get("parse") != null) {
            result.put("parse", source.get("parse"));
        }
        if (source.get("jx") != null) {
            result.put("jx", source.get("jx"));
        }
        if (source.get("subt") != null) {
            result.put("subt", source.get("subt"));
        }
        if (source.get("danmaku") != null) {
            result.put("danmaku", source.get("danmaku"));
        }
        if (source.get("msg") != null) {
            result.put("msg", source.get("msg"));
        }
        return result;
    }

    // ---------------------------------------------------------------- 工具

    /** 一个标准 Vod（对齐 Python 侧 {@code vod()} 与 §8.3）。 */
    public static Map<String, Object> vod(String vodId, String vodName) {
        Map<String, Object> item = new LinkedHashMap<>();
        item.put("vod_id", vodId);
        item.put("vod_name", vodName);
        item.put("vod_pic", "");
        item.put("vod_remarks", "");
        item.put("vod_content", "");
        item.put("vod_play_from", "");
        item.put("vod_play_url", "");
        return item;
    }

    private static List<Object> listOf(Object value) {
        if (value instanceof Iterable<?> iterable) {
            List<Object> items = new ArrayList<>();
            for (Object item : iterable) {
                items.add(item);
            }
            return items;
        }
        return new ArrayList<>();
    }

    /** 列表条目必须是对象且含 vod_id；非法条目丢弃（不伪装成合法 Vod）。 */
    private static List<Object> vodList(Object value) {
        List<Object> items = new ArrayList<>();
        if (!(value instanceof Iterable<?> iterable)) {
            return items;
        }
        for (Object item : iterable) {
            if (item instanceof Map<?, ?> map && map.get("vod_id") != null) {
                items.add(item);
            }
        }
        return items;
    }

    @SuppressWarnings("unchecked")
    private static Map<String, Object> mapOf(Object value) {
        if (value instanceof Map<?, ?> map) {
            return (Map<String, Object>) map;
        }
        return new LinkedHashMap<>();
    }

    private static int parsePage(String page) {
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

    private static int intOf(Object value, int fallback) {
        if (value instanceof Number number) {
            return number.intValue();
        }
        if (value instanceof String text) {
            try {
                return Integer.parseInt(text.trim());
            } catch (NumberFormatException error) {
                return fallback;
            }
        }
        return fallback;
    }

    private static Object firstNonEmpty(Object... values) {
        for (Object value : values) {
            if (value != null && !String.valueOf(value).isEmpty()) {
                return value;
            }
        }
        return "";
    }
}
