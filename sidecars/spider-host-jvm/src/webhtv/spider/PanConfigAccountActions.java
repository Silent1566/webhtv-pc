package webhtv.spider;

import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;

/**
 * 给"账号配置类"站源的分类条目加上一条**声明式标记**，让桌面端知道这一项是打开/清除共享账号的动作项，
 * 而不是普通媒体条目。
 *
 * <p>为什么按站源类名精确判定：{@code quarkmanual}/{@code quarkclear} 这类 ID 是站源自定义的，任何别的站源
 * 都可以叫同样的名字。只有真正的 PanConfig/PanConfigGuard 才有"手动 Cookie 输入/清除"这一动作语义，
 * 猜标题或猜 URL 会把普通媒体误判成动作项。
 *
 * <p>为什么不改其它字段：标记是额外键，条目原有字段（含图片、备注与站源自定义键）原样保留。
 */
public final class PanConfigAccountActions {

    /** 标记键名。桌面端只认这个键，且校验版本/提供方/操作三者与原始条目 ID 的组合。 */
    public static final String FIELD = "_webhtv_accountAction";

    private static final int VERSION = 1;

    /** 只有这两个**精确类名**算账号配置站源。 */
    private static final Set<String> SOURCE_CLASSES = Set.of(
            "com.github.catvod.spider.PanConfig",
            "com.github.catvod.spider.PanConfigGuard");

    /**
     * 支持的条目 ID → 动作（提供方 + 操作）。
     *
     * <p>为什么扫码/注册项也算账号动作：它们在 PanConfig 里同样是"配置这个提供方的账号"的入口
     * （扫码/取注册链接），未标记时会掉进普通影片详情。它们与手动输入共用同一个账号键，因此统一走
     * 账号页的手动输入路径，而不是去请求一个根本不存在的影片详情。
     *
     * <p>为什么只加 Quark/Baidu：其它提供方（UC/AList/115 等）用的是**另一组偏好键**，本版本没有
     * 共享存储语义，标记它们会把用户送到一个写不了号的界面。
     */
    private static final Map<String, Action> ACTIONS = Map.of(
            "quarkmanual", new Action("quark", "edit"),
            "quarkclear", new Action("quark", "clear"),
            "baidumanual", new Action("baidu", "edit"),
            "baiduclear", new Action("baidu", "clear"),
            "quark", new Action("quark", "edit"),
            "qkregister", new Action("quark", "edit"),
            "baidu", new Action("baidu", "edit"),
            "baiduregister", new Action("baidu", "edit"));

    /** 一个受支持账号动作的固定语义。 */
    private record Action(String provider, String operation) {}

    private PanConfigAccountActions() {}

    /**
     * 摘掉任意 dict 形状结果里条目自带的保留键。
     *
     * <p>为什么所有返回条目列表的钩子都要过一遍：首页/详情/搜索与分类一样会把站源给的条目原样交给桌面端，
     * 只要有一条路径没摘，站源就能用一个伪造标记绕到"账号动作"界面上。
     */
    static void sanitize(Map<String, Object> result) {
        if (result == null) {
            return;
        }
        Object rawList = result.get("list");
        if (!(rawList instanceof List<?> items)) {
            return;
        }
        for (Object rawItem : items) {
            if (rawItem instanceof Map<?, ?> item) {
                @SuppressWarnings("unchecked")
                Map<String, Object> mutable = (Map<String, Object>) item;
                mutable.remove(FIELD);
            }
        }
    }

    public static boolean isAccountSource(String sourceClassName) {
        return sourceClassName != null && SOURCE_CLASSES.contains(sourceClassName);
    }

    /** 该条目应带的操作；返回 null 表示这个 ID 不是受支持的账号动作项。 */
    public static String operation(Object vodId) {
        Action action = vodId instanceof String id ? ACTIONS.get(id) : null;
        return action == null ? null : action.operation();
    }

    /**
     * 分类结果就地处理：先**无条件**摘掉条目里自带的保留字段，再只给账号配置站源的受支持动作项补正确标记。
     *
     * <p>为什么先摘：本字段是宿主的内部元数据，不是站源可用的接口。站源（或它从远端拿到的 JSON）自带一个
     * 结构完全合法的 {@code _webhtv_accountAction}，就能冒充"账号动作项"进入桌面账号界面。摘掉再按类身份重写，
     * 才配得上"按类名验证"这句话。除这一个保留键外，条目的其它字段一律原样保留。
     */
    static void decorate(String sourceClassName, Map<String, Object> category) {
        sanitize(category);
        if (category == null || !isAccountSource(sourceClassName)) {
            return;
        }
        Object rawList = category.get("list");
        if (!(rawList instanceof List<?> items)) {
            return;
        }
        for (Object rawItem : items) {
            if (!(rawItem instanceof Map<?, ?> item)) {
                continue;
            }
            @SuppressWarnings("unchecked")
            Map<String, Object> mutable = (Map<String, Object>) item;
            Object vodId = item.get("vod_id");
            if (!(vodId instanceof String id) || !ACTIONS.containsKey(id)) {
                continue;
            }
            Action action = ACTIONS.get(id);
            Map<String, Object> marker = new LinkedHashMap<String, Object>();
            marker.put("version", VERSION);
            marker.put("provider", action.provider());
            marker.put("operation", action.operation());
            mutable.put(FIELD, marker);
        }
    }
}
