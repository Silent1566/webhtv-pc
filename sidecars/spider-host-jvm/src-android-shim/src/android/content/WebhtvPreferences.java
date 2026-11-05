package android.content;

import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.util.HashMap;
import java.util.HashSet;
import java.util.Map;
import java.util.Properties;
import java.util.Set;

/**
 * SharedPreferences 的桌面真实现：一个文件 + 内存缓存。
 *
 * <p>为什么不用 Android 的 XML 格式：本站只需要「写进去、重启后还能读回来」，
 * {@link Properties} 是 JDK 自带、可读写、会自动把非 Latin1 转成 \\uXXXX 的现成格式，
 * 不引入任何依赖就能保证转义可逆。
 *
 * <p>为什么值要带类型前缀：Properties 只存字符串，若不留标记，读回后无法区分
 * int 1 与 String "1"，站源 {@code getInt("port", 0)} 会拿到类型不符的值。
 * 前缀加上后，落盘格式自带类型信息，新实例读回即可还原。
 *
 * <p>线程安全：站源可能在初始化线程与回调线程同时写配置，所有读写都落在同一个对象锁上。
 */
public class WebhtvPreferences implements SharedPreferences {

    /** StringSet 的连接符：真机 XML 也用 {@code \u0000} 分隔，键里不可能出现该字符。 */
    private static final char SET_SEPARATOR = '\u0000';

    private static final char TAG_STRING = 's';
    private static final char TAG_STRING_SET = 't';
    private static final char TAG_INT = 'i';
    private static final char TAG_LONG = 'l';
    private static final char TAG_FLOAT = 'f';
    private static final char TAG_BOOLEAN = 'b';

    private final File file;
    private final Map<String, Object> values = new HashMap<String, Object>();

    public WebhtvPreferences(File file) {
        this.file = file;
        load();
    }

    public synchronized SharedPreferences.Editor edit() {
        return new EditorImpl();
    }

    @Override
    public synchronized String getString(String key, String defValue) {
        Object v = values.get(key);
        // 类型不符时返回默认值而不是抛 ClassCastException：站源普遍把「没有这项配置」当空串处理，
        // 抛异常会让整条初始化失败，而它本来只是想读一个可缺省的字段。
        return v instanceof String ? (String) v : defValue;
    }

    @Override
    public synchronized Set<String> getStringSet(String key, Set<String> defValues) {
        Object v = values.get(key);
        if (!(v instanceof Set)) {
            return defValues;
        }
        @SuppressWarnings("unchecked")
        Set<String> stored = (Set<String>) v;
        // 返回副本：调用方修改返回值不应该反过来改掉已持久化的配置（真机同样返回拷贝）。
        return new HashSet<String>(stored);
    }

    @Override
    public synchronized int getInt(String key, int defValue) {
        Object v = values.get(key);
        return v instanceof Integer ? ((Integer) v).intValue() : defValue;
    }

    @Override
    public synchronized long getLong(String key, long defValue) {
        Object v = values.get(key);
        return v instanceof Long ? ((Long) v).longValue() : defValue;
    }

    @Override
    public synchronized float getFloat(String key, float defValue) {
        Object v = values.get(key);
        return v instanceof Float ? ((Float) v).floatValue() : defValue;
    }

    @Override
    public synchronized boolean getBoolean(String key, boolean defValue) {
        Object v = values.get(key);
        return v instanceof Boolean ? ((Boolean) v).booleanValue() : defValue;
    }

    @Override
    public synchronized boolean contains(String key) {
        return values.containsKey(key);
    }

    @Override
    public synchronized Map<String, ?> getAll() {
        // 返回副本：真机返回的是快照，调用方遍历时不应看到并发写入的中间态。
        return new HashMap<String, Object>(values);
    }

    private synchronized void load() {
        if (file == null || !file.isFile()) {
            // 首次运行：文件不存在是正常路径，不是错误，保持空配置。
            return;
        }
        Properties props = new Properties();
        FileInputStream in = null;
        try {
            in = new FileInputStream(file);
            props.load(in);
        } catch (IOException e) {
            // 解析失败按空配置处理：缓存文件损坏只应让站源回到默认值，不应让宿主直接崩。
            return;
        } finally {
            closeQuietly(in);
        }
        for (String name : props.stringPropertyNames()) {
            Object value = decode(props.getProperty(name));
            if (value != null) {
                values.put(name, value);
            }
        }
    }

    /** 只在持有本对象锁时调用；返回 false 表示写盘失败（调用方据此决定 commit 的返回值）。 */
    private boolean save() {
        Properties props = new Properties();
        for (Map.Entry<String, Object> entry : values.entrySet()) {
            String encoded = encode(entry.getValue());
            if (encoded != null) {
                props.setProperty(entry.getKey(), encoded);
            }
        }
        FileOutputStream out = null;
        try {
            File parent = file.getParentFile();
            if (parent != null && !parent.isDirectory()) {
                // 目录不存在时 Properties.store 会直接抛 FileNotFoundException，
                // 而这里的目录在真机上由系统创建，桌面侧只能自己补。
                parent.mkdirs();
            }
            out = new FileOutputStream(file);
            props.store(out, null);
            return true;
        } catch (IOException e) {
            return false;
        } finally {
            closeQuietly(out);
        }
    }

    private static String encode(Object value) {
        if (value instanceof String) {
            return TAG_STRING + (String) value;
        }
        if (value instanceof Integer) {
            return TAG_INT + value.toString();
        }
        if (value instanceof Long) {
            return TAG_LONG + value.toString();
        }
        if (value instanceof Float) {
            return TAG_FLOAT + value.toString();
        }
        if (value instanceof Boolean) {
            return TAG_BOOLEAN + value.toString();
        }
        if (value instanceof Set) {
            StringBuilder sb = new StringBuilder();
            sb.append(TAG_STRING_SET);
            for (Object item : (Set<?>) value) {
                if (sb.length() > 1) {
                    sb.append(SET_SEPARATOR);
                }
                sb.append((String) item);
            }
            return sb.toString();
        }
        return null;
    }

    /** 返回 null 表示这条记录无法还原（损坏或未知类型），调用处直接丢弃该键。 */
    private static Object decode(String raw) {
        if (raw == null || raw.isEmpty()) {
            // 无前缀的历史记录：按裸字符串处理，避免旧文件整体丢弃。
            return raw;
        }
        String body = raw.substring(1);
        try {
            switch (raw.charAt(0)) {
                case TAG_STRING:
                    return body;
                case TAG_INT:
                    return Integer.valueOf(body);
                case TAG_LONG:
                    return Long.valueOf(body);
                case TAG_FLOAT:
                    return Float.valueOf(body);
                case TAG_BOOLEAN:
                    return Boolean.valueOf(body);
                case TAG_STRING_SET:
                    return splitSet(body);
                default:
                    return raw;
            }
        } catch (NumberFormatException e) {
            return null;
        }
    }

    private static Set<String> splitSet(String body) {
        Set<String> result = new HashSet<String>();
        if (body.isEmpty()) {
            return result;
        }
        int start = 0;
        for (int i = 0; i < body.length(); i++) {
            if (body.charAt(i) == SET_SEPARATOR) {
                result.add(body.substring(start, i));
                start = i + 1;
            }
        }
        result.add(body.substring(start));
        return result;
    }

    private static void closeQuietly(java.io.Closeable c) {
        if (c == null) {
            return;
        }
        try {
            c.close();
        } catch (IOException ignored) {
            // 关闭失败不影响已写入的内容；真机同样吞掉这个异常。
        }
    }

    /**
     * 编辑事务：所有改动先落在缓冲里，commit/apply 时一次性合并并落盘。
     *
     * <p>为什么要把「清空」「删除」「写入」分成三份记录而不是直接在 values 上改：
     * 站源存在 commit 前多次 put 同一键、以及 clear 后再 put 的写法，按顺序合并才能复现真机结果。
     */
    private final class EditorImpl implements SharedPreferences.Editor {

        private final Map<String, Object> pending = new HashMap<String, Object>();
        private final Set<String> removals = new HashSet<String>();
        private boolean clearRequested;

        @Override
        public SharedPreferences.Editor putString(String key, String value) {
            pending.put(key, value);
            return this;
        }

        @Override
        public SharedPreferences.Editor putStringSet(String key, Set<String> values) {
            // 拷贝一份：调用方随后修改传入的 Set 不应该影响已经提交的配置。
            pending.put(key, values == null ? null : new HashSet<String>(values));
            return this;
        }

        @Override
        public SharedPreferences.Editor putInt(String key, int value) {
            pending.put(key, Integer.valueOf(value));
            return this;
        }

        @Override
        public SharedPreferences.Editor putLong(String key, long value) {
            pending.put(key, Long.valueOf(value));
            return this;
        }

        @Override
        public SharedPreferences.Editor putFloat(String key, float value) {
            pending.put(key, Float.valueOf(value));
            return this;
        }

        @Override
        public SharedPreferences.Editor putBoolean(String key, boolean value) {
            pending.put(key, Boolean.valueOf(value));
            return this;
        }

        @Override
        public SharedPreferences.Editor remove(String key) {
            removals.add(key);
            return this;
        }

        @Override
        public SharedPreferences.Editor clear() {
            clearRequested = true;
            return this;
        }

        @Override
        public boolean commit() {
            synchronized (WebhtvPreferences.this) {
                if (clearRequested) {
                    values.clear();
                }
                for (String key : removals) {
                    values.remove(key);
                }
                for (Map.Entry<String, Object> entry : pending.entrySet()) {
                    if (entry.getValue() == null) {
                        // putString(key, null) 在真机上等价于移除该键，这里保持同样语义。
                        values.remove(entry.getKey());
                    } else {
                        values.put(entry.getKey(), entry.getValue());
                    }
                }
                return save();
            }
        }

        @Override
        public void apply() {
            // 桌面没有后台写盘线程，apply 与 commit 同义；用 apply 的语义（不关心结果）包一次即可。
            commit();
        }
    }
}
