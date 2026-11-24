package android.content;

import java.io.File;
import java.io.IOException;
import java.nio.ByteBuffer;
import java.nio.charset.CharacterCodingException;
import java.nio.charset.CharsetDecoder;
import java.nio.charset.CodingErrorAction;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.Set;
import webhtv.spider.Json;

/**
 * 仅对站源 {@code NewWexFnw_preferences} 启用的账号**读穿透**层：账号值由宿主启动参数
 * {@code -Dwebhtv.accountStore=<绝对路径>} 指向一个应用级共享文件，其余键与全部写操作仍落在原来的站点私有文件。
 *
 * <p>为什么读时才重新加载：Dart 侧写入方可能在站源已构造出 preferences 对象之后才完成一次原子替换，
 * 缓存快照会让老对象永远停在旧值。账号文件有 128KiB 上限，每次读取重读一次是可接受的代价。
 *
 * <p>为什么空串不是「缺失」：全局清除动作会把键写成空串，它必须压过站点私有文件里的旧 Cookie；
 * 只有**键不存在**（或文件不存在）才回落到站点私有值。
 *
 * <p>为什么不写全局：站源的本地编辑器（{@code edit()}）在本版本仍只改站点私有文件，避免一次静默的
 * 站内修改就把账号扩散到所有站源。
 */
public final class SharedAccountPreferences implements SharedPreferences {

    /** 只有这个精确名字的 preferences 参与读穿透。 */
    public static final String NAME = "NewWexFnw_preferences";

    /** 宿主提供的共享账号文件绝对路径；命令行里永远只出现路径，不出现 Cookie。 */
    public static final String PROPERTY = "webhtv.accountStore";

    private static final Set<String> ACCOUNT_KEYS = Set.of("Wex_quark_cookie", "Wex_baidu_cookie");

    private static final long MAX_DOCUMENT_BYTES = 128L * 1024L;
    private static final int MAX_VALUE_BYTES = 32 * 1024;

    private final SharedPreferences local;
    private final File file;

    private SharedAccountPreferences(SharedPreferences local, File file) {
        this.local = local;
        this.file = file;
    }

    /**
     * 按精确 preferences 名与启动参数决定是否包装；参数缺失/为空时原样返回站点私有实现（旧行为）。
     *
     * @throws IllegalStateException 参数存在但不是绝对路径：这是宿主配置错误，不能静默降级成站点私有值
     */
    public static SharedPreferences wrap(String name, SharedPreferences local) {
        if (!NAME.equals(name)) {
            return local;
        }
        String path = System.getProperty(PROPERTY);
        if (path == null || path.trim().isEmpty()) {
            return local;
        }
        File file = new File(path);
        if (!file.isAbsolute()) {
            throw invalid("webhtv.accountStore 必须是绝对路径");
        }
        return new SharedAccountPreferences(local, file);
    }

    // ------------------------------------------------------------------ 读

    @Override
    public String getString(String key, String defValue) {
        // 非账号键完全不碰共享文件：一个损坏的全局文件不应该阻断站点自己的常规配置读取。
        if (!isAccountKey(key)) {
            return local.getString(key, defValue);
        }
        Map<String, String> shared = sharedValues();
        return shared.containsKey(key) ? shared.get(key) : local.getString(key, defValue);
    }

    @Override
    public Map<String, ?> getAll() {
        Map<String, Object> merged = new HashMap<String, Object>(local.getAll());
        for (Map.Entry<String, String> entry : sharedValues().entrySet()) {
            merged.put(entry.getKey(), entry.getValue());
        }
        return merged;
    }

    @Override
    public boolean contains(String key) {
        if (isAccountKey(key) && sharedValues().containsKey(key)) {
            return true;
        }
        return local.contains(key);
    }

    // 其余取值器不做类型转换：共享值若是字符串，它们的行为与站点私有实现遇到字符串时一致（返回默认值）。
    @Override
    public int getInt(String key, int defValue) {
        return isOverridden(key) ? defValue : local.getInt(key, defValue);
    }

    @Override
    public long getLong(String key, long defValue) {
        return isOverridden(key) ? defValue : local.getLong(key, defValue);
    }

    @Override
    public float getFloat(String key, float defValue) {
        return isOverridden(key) ? defValue : local.getFloat(key, defValue);
    }

    @Override
    public boolean getBoolean(String key, boolean defValue) {
        return isOverridden(key) ? defValue : local.getBoolean(key, defValue);
    }

    @Override
    public Set<String> getStringSet(String key, Set<String> defValues) {
        return isOverridden(key) ? defValues : local.getStringSet(key, defValues);
    }

    private boolean isOverridden(String key) {
        return isAccountKey(key) && sharedValues().containsKey(key);
    }

    private static boolean isAccountKey(String key) {
        return key != null && ACCOUNT_KEYS.contains(key);
    }

    // ------------------------------------------------------------ 本地写

    @Override
    public SharedPreferences.Editor edit() {
        return local.edit();
    }

    // ------------------------------------------------------------ 账号文件

    /** 返回文件里**存在**的已知账号键；文件不存在等价于"没有全局覆盖"，不创建任何文件。 */
    private Map<String, String> sharedValues() {
        if (!file.isFile()) {
            return Map.of();
        }
        byte[] bytes;
        try {
            // 先看文件大小再读：上限必须挡在**分配之前**，否则一个超大文件会先被整个读进内存。
            if (Files.size(file.toPath()) > MAX_DOCUMENT_BYTES) {
                throw invalid("共享账号文件超过128KiB");
            }
            bytes = Files.readAllBytes(file.toPath());
        } catch (IOException | RuntimeException error) {
            // 原因不链进异常：文件内容可能含 Cookie，消息里只保留可公开的种类。
            if (error instanceof IllegalStateException invalidSize) {
                throw invalidSize;
            }
            throw invalid("无法读取共享账号文件");
        }
        if (bytes.length > MAX_DOCUMENT_BYTES) {
            // 读完后复查：文件可能在两次调用之间被替换。
            throw invalid("共享账号文件超过128KiB");
        }
        String document;
        try {
            CharsetDecoder decoder = StandardCharsets.UTF_8.newDecoder()
                    .onMalformedInput(CodingErrorAction.REPORT)
                    .onUnmappableCharacter(CodingErrorAction.REPORT);
            document = decoder.decode(ByteBuffer.wrap(bytes)).toString();
        } catch (CharacterCodingException error) {
            throw invalid("共享账号文件不是合法UTF-8");
        }
        return parse(document);
    }

    private static Map<String, String> parse(String document) {
        Object root;
        try {
            root = Json.parse(document);
        } catch (RuntimeException error) {
            // 解析器的消息可能包含文档片段，坚决不转发。
            throw invalid("共享账号文件不是合法JSON");
        }
        if (!(root instanceof Map<?, ?> map)) {
            throw invalid("共享账号文件顶层必须是对象");
        }
        if (map.size() != 2 || !map.containsKey("version") || !map.containsKey("values")) {
            throw invalid("共享账号文件顶层必须且只能有version与values");
        }
        if (!isVersionOne(map.get("version"))) {
            throw invalid("共享账号文件version必须为1");
        }
        Object rawValues = map.get("values");
        if (!(rawValues instanceof Map<?, ?> values)) {
            throw invalid("共享账号文件values必须是对象");
        }
        Map<String, String> result = new LinkedHashMap<String, String>();
        for (Map.Entry<?, ?> entry : values.entrySet()) {
            Object key = entry.getKey();
            if (!(key instanceof String name) || !ACCOUNT_KEYS.contains(name)) {
                throw invalid("共享账号文件含未知键名");
            }
            if (!(entry.getValue() instanceof String value)) {
                throw invalid("共享账号文件的账号值必须是字符串");
            }
            if (value.getBytes(StandardCharsets.UTF_8).length > MAX_VALUE_BYTES) {
                throw invalid("共享账号值超过32KiB");
            }
            result.put(name, value);
        }
        return result;
    }

    private static boolean isVersionOne(Object value) {
        return value instanceof Number number && number.doubleValue() == 1.0d
                && !(number instanceof Double d && d.isNaN());
    }

    private static IllegalStateException invalid(String reason) {
        return new IllegalStateException(reason + "（webhtv.accountStore）");
    }
}
