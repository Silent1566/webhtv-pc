package android.content;

import java.util.Map;
import java.util.Set;

/**
 * android.content.SharedPreferences 的接口垫片（javap：public interface）。
 *
 * <p>签名严格照 javap 抄，因为站源是按真机接口写的：返回 Set&lt;String&gt; 的
 * getStringSet、返回 {@code Map<String, ?>} 的 getAll 都必须逐字对上，否则站源里的
 * 实现类会因为「不兼容的返回类型」编译失败。
 *
 * <p>Editor 写成本文件里的嵌套接口：它编译产物是 SharedPreferences$Editor.class，
 * 与真机同名，调用方 {@code prefs.edit().putString(...).commit()} 的链式写法才成立。
 */
public interface SharedPreferences {

    String getString(String key, String defValue);

    Set<String> getStringSet(String key, Set<String> defValues);

    int getInt(String key, int defValue);

    long getLong(String key, long defValue);

    float getFloat(String key, float defValue);

    boolean getBoolean(String key, boolean defValue);

    boolean contains(String key);

    Map<String, ?> getAll();

    Editor edit();

    /**
     * 编辑事务。commit/apply 之前的所有 put/remove/clear 都只作用于缓冲，
     * 这一点与真机一致：站源常把「配置改到一半就 return」的路径依赖它的原子性。
     */
    interface Editor {

        Editor putString(String key, String value);

        Editor putStringSet(String key, Set<String> values);

        Editor putInt(String key, int value);

        Editor putLong(String key, long value);

        Editor putFloat(String key, float value);

        Editor putBoolean(String key, boolean value);

        Editor remove(String key);

        Editor clear();

        /** 同步落盘；返回 true 表示已写入成功。 */
        boolean commit();

        /** 异步落盘；桌面没有后台线程，由实现决定语义。 */
        void apply();
    }

    // ---- 未声明成员： ----
    // registerOnSharedPreferenceChangeListener / unregisterOnSharedPreferenceChangeListener
    //   -> 需要再嵌一个 OnSharedPreferenceChangeListener 接口，而站源只读配置、从不监听变化，
    //      为无人使用的回调类型增加接口只会扩大垫片面。
}
