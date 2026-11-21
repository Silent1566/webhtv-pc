package android.os;

import java.io.Serializable;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.Set;

/**
 * android.os.Bundle 的 JVM 实现垫片：一张 {@code Map} 支撑的键值包。
 *
 * <p>真机的 Bundle 是 Parcel 上的惰性视图，主要价值在于「跨进程/跨组件传递」。桌面载体没有
 * Parcel，只有进程内传递这一个用法有实际意义，因此垫片按 {@code Map} 实现，保留类型检查与
 * 取值语义。
 *
 * <p><b>取值语义对齐 AOSP，且「缺失」与「类型不符」严格分开</b>（两者都靠 {@link #cast} 区分）：
 * <ul>
 *   <li>key **不存在** → 返回默认值（无默认值重载返回 {@code null}/{@code 0}/{@code false}）；</li>
 *   <li>key **存在但类型不符** → 抛 {@code ClassCastException}，**即使调用的是带默认值的重载**。
 *       这是 AOSP 的实际行为：它先把值强转成目标类型，CCE 发生在「值为 null 才回落默认值」
 *       之前；把这两档合并成「类型不符也返回默认值」会让站源在打包/解包类型搞错时静默拿到
 *       默认值，正是本垫片要消除的那类失败。</li>
 *   <li>与 AOSP 的唯一差异：AOSP 在类型不符时还会打一条 {@code Log.w}，垫片不打（桌面侧不缺
 *       这条日志，缺的是别让错误变成静默的默认值）。</li>
 * </ul>
 *
 * <p>存储用 {@link LinkedHashMap}（真机是 {@code HashMap}）：键序只是排障可读性，不在任何公开
 * 契约里，站源不应依赖。
 */
public class Bundle {

    private final Map<String, Object> map;

    public Bundle() {
        this.map = new LinkedHashMap<>();
    }

    /** 浅拷贝（真机语义：值本身不复制）。 */
    public Bundle(Bundle other) {
        this.map = new LinkedHashMap<>();
        if (other != null) {
            this.map.putAll(other.map);
        }
    }

    // ------------------------------------------------------------ 容器

    public int size() {
        return map.size();
    }

    public boolean isEmpty() {
        return map.isEmpty();
    }

    public void clear() {
        map.clear();
    }

    public boolean containsKey(String key) {
        return map.containsKey(key);
    }

    public Object get(String key) {
        return map.get(key);
    }

    public void remove(String key) {
        map.remove(key);
    }

    /** 与真机同签名：只接受 {@link Bundle}（不是任意 {@code Map}）。 */
    public void putAll(Bundle bundle) {
        if (bundle == null) {
            throw new NullPointerException("bundle");
        }
        map.putAll(bundle.map);
    }

    public Set<String> keySet() {
        return map.keySet();
    }

    // ------------------------------------------------------------ String

    public void putString(String key, String value) {
        map.put(key, value);
    }

    public String getString(String key) {
        return cast(key, map.get(key), String.class);
    }

    public String getString(String key, String defaultValue) {
        String value = cast(key, map.get(key), String.class);
        return value == null ? defaultValue : value;
    }

    // ------------------------------------------------------------ CharSequence

    public void putCharSequence(String key, CharSequence value) {
        map.put(key, value);
    }

    public CharSequence getCharSequence(String key) {
        return cast(key, map.get(key), CharSequence.class);
    }

    public CharSequence getCharSequence(String key, CharSequence defaultValue) {
        CharSequence value = cast(key, map.get(key), CharSequence.class);
        return value == null ? defaultValue : value;
    }

    // ------------------------------------------------------------ int

    public void putInt(String key, int value) {
        map.put(key, value);
    }

    public int getInt(String key) {
        Integer value = cast(key, map.get(key), Integer.class);
        return value == null ? 0 : value;
    }

    public int getInt(String key, int defaultValue) {
        Integer value = cast(key, map.get(key), Integer.class);
        return value == null ? defaultValue : value;
    }

    // ------------------------------------------------------------ long

    public void putLong(String key, long value) {
        map.put(key, value);
    }

    public long getLong(String key) {
        Long value = cast(key, map.get(key), Long.class);
        return value == null ? 0L : value;
    }

    public long getLong(String key, long defaultValue) {
        Long value = cast(key, map.get(key), Long.class);
        return value == null ? defaultValue : value;
    }

    // ------------------------------------------------------------ boolean

    public void putBoolean(String key, boolean value) {
        map.put(key, value);
    }

    public boolean getBoolean(String key) {
        Boolean value = cast(key, map.get(key), Boolean.class);
        return value != null && value;
    }

    public boolean getBoolean(String key, boolean defaultValue) {
        Boolean value = cast(key, map.get(key), Boolean.class);
        return value == null ? defaultValue : value;
    }

    // ------------------------------------------------------------ float

    public void putFloat(String key, float value) {
        map.put(key, value);
    }

    public float getFloat(String key) {
        Float value = cast(key, map.get(key), Float.class);
        return value == null ? 0f : value;
    }

    public float getFloat(String key, float defaultValue) {
        Float value = cast(key, map.get(key), Float.class);
        return value == null ? defaultValue : value;
    }

    // ------------------------------------------------------------ double

    public void putDouble(String key, double value) {
        map.put(key, value);
    }

    public double getDouble(String key) {
        Double value = cast(key, map.get(key), Double.class);
        return value == null ? 0d : value;
    }

    public double getDouble(String key, double defaultValue) {
        Double value = cast(key, map.get(key), Double.class);
        return value == null ? defaultValue : value;
    }

    // ------------------------------------------------------------ 数组与列表

    /** 形参类型必须是 {@code ArrayList}：真机描述符是 {@code Ljava/util/ArrayList;}。 */
    public void putStringArrayList(String key, ArrayList<String> value) {
        map.put(key, value);
    }

    /**
     * 与真机一致：只做 {@code ArrayList} 的整体类型检查，不逐元素检查（类型擦除后真机也只是
     * 一次强转，元素类型错位会在使用处暴露为 {@code ClassCastException}）。
     */
    @SuppressWarnings("unchecked")
    public ArrayList<String> getStringArrayList(String key) {
        return (ArrayList<String>) cast(key, map.get(key), ArrayList.class);
    }

    public void putCharArray(String key, char[] value) {
        map.put(key, value);
    }

    public char[] getCharArray(String key) {
        return cast(key, map.get(key), char[].class);
    }

    // ------------------------------------------------------------ Serializable

    public void putSerializable(String key, Serializable value) {
        map.put(key, value);
    }

    public Serializable getSerializable(String key) {
        return cast(key, map.get(key), Serializable.class);
    }

    // ------------------------------------------------------------ 工具

    /** 「缺失」返回 {@code null}，「类型不符」抛 {@code ClassCastException}——两档不可合并。 */
    private static <T> T cast(String key, Object value, Class<T> type) {
        if (value == null) {
            return null;
        }
        if (type.isInstance(value)) {
            return type.cast(value);
        }
        throw new ClassCastException("Bundle 的 key=" + key + " 是 "
                + value.getClass().getName() + "，不是 " + type.getSimpleName());
    }

    @Override
    public String toString() {
        return "Bundle[" + map + "]";
    }

    // ---- 未声明成员（签名或语义依赖仓库中尚缺的类型）： ----
    // android.os.Parcelable 一族：putParcelable / getParcelable / putParcelableArray /
    //     putParcelableArrayList -> android.os.Parcelable 需补
    // android.os.Parcel 一族：writeToParcel / CREATOR / describeContents / setClassLoader /
    //     getClassLoader（类加载器只在反序列化 Parcelable 时有意义） -> 需补
    // putBundle / getBundle：签名只依赖 Bundle 本身，但真机语义是「嵌套 Bundle 的 Parcel 视图」，
    //     实现成引用共享会与真机的按值传递不符，留待需要嵌套包的站源出现时再定语义
    // putByte / getByte / putShort / getShort / putChar / getChar / putByteArray / putShortArray /
    //     putIntArray / putLongArray / putFloatArray / putDoubleArray / putBooleanArray /
    //     putStringArray / getByteArray / getStringArray 等：当前无引用证据
    // putIntegerArrayList / getIntegerArrayList
    // clone() / deepCopy()
}
