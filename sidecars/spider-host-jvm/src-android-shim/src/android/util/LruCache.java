package android.util;

import java.util.LinkedHashMap;
import java.util.Map;

/**
 * android.util.LruCache 的 JVM 实现垫片：AOSP 语义子集（LRU 淘汰按**权重**而非条数）。
 *
 * <p>实现与 AOSP 的可见行为对齐，包括几个容易被「重写得更合理」破坏的点：
 * <ul>
 *   <li>{@link #get} 未命中时调用 {@link #create(Object)}，命中 create 的结果算
 *       {@code createCount}，并且**即使刚创建的条目立刻被淘汰也照样返回它**；</li>
 *   <li>淘汰顺序从「最早插入/最早访问」开始（{@code accessOrder=true}）；</li>
 *   <li>{@link #put} 覆盖已有键时先把旧值的权重减回去，再调用
 *       {@link #entryRemoved(boolean, Object, Object, Object)}；</li>
 *   <li>{@code sizeOf} 返回负数视为实现错误，抛 {@code IllegalStateException}；</li>
 *   <li>{@code get}/{@code put}/{@code remove} 是 {@code final}（真机同此）：站源只能通过
 *       {@code sizeOf}/{@code create}/{@code entryRemoved} 参与策略。</li>
 * </ul>
 */
public class LruCache<K, V> {

    private final LinkedHashMap<K, V> map;

    /** 当前占用（{@code sizeOf} 之和），不一定是条数。 */
    private int size;

    private int maxSize;

    private int hitCount;

    private int missCount;

    private int createCount;

    private int putCount;

    private int evictionCount;

    public LruCache(int maxSize) {
        if (maxSize <= 0) {
            throw new IllegalArgumentException("maxSize <= 0");
        }
        this.maxSize = maxSize;
        this.map = new LinkedHashMap<>(0, 0.75f, true);
    }

    /** 条目权重，默认 1（即按条数计）。子类可覆写成字节数/元素数等。 */
    protected int sizeOf(K key, V value) {
        return 1;
    }

    /** 条目被移除或替换时的回调；{@code evicted} 为 {@code true} 表示是被容量淘汰。 */
    protected void entryRemoved(boolean evicted, K key, V oldValue, V newValue) {
        // 默认无操作（与真机一致）。
    }

    /** 未命中时按 key 创建条目；返回 {@code null} 表示不缓存（默认不创建）。 */
    protected V create(K key) {
        return null;
    }

    public final V get(K key) {
        if (key == null) {
            throw new NullPointerException("key == null");
        }
        V value;
        synchronized (this) {
            value = map.get(key);
            if (value != null) {
                hitCount++;
                return value;
            }
            missCount++;
        }

        V created = create(key);
        if (created == null) {
            return null;
        }

        synchronized (this) {
            createCount++;
            value = map.put(key, created);
            if (value != null) {
                // 并发下有人抢先放进了值：把 create 的结果撤回，返回别人的值。
                map.put(key, value);
            } else {
                size += safeSizeOf(key, created);
            }
        }

        if (value != null) {
            entryRemoved(false, key, created, value);
            return value;
        }
        trimToSize(maxSize);
        return created;
    }

    public final V put(K key, V value) {
        if (key == null || value == null) {
            throw new NullPointerException("key == null || value == null");
        }
        V previous;
        synchronized (this) {
            putCount++;
            size += safeSizeOf(key, value);
            previous = map.put(key, value);
            if (previous != null) {
                size -= safeSizeOf(key, previous);
            }
        }
        if (previous != null) {
            entryRemoved(false, key, previous, value);
        }
        trimToSize(maxSize);
        return previous;
    }

    public final V remove(K key) {
        if (key == null) {
            throw new NullPointerException("key == null");
        }
        V previous;
        synchronized (this) {
            previous = map.remove(key);
            if (previous != null) {
                size -= safeSizeOf(key, previous);
            }
        }
        if (previous != null) {
            entryRemoved(false, key, previous, null);
        }
        return previous;
    }

    /** 淘汰到 {@code size <= maxSize}；{@code maxSize < 0} 等价于清空。 */
    public void trimToSize(int maxSize) {
        while (true) {
            K key;
            V value;
            synchronized (this) {
                if (size < 0 || (map.isEmpty() && size != 0)) {
                    throw new IllegalStateException(
                            getClass().getName() + ".sizeOf() 行为不一致：" + size + " " + map);
                }
                if (size <= maxSize || map.isEmpty()) {
                    break;
                }
                Map.Entry<K, V> toEvict = map.entrySet().iterator().next();
                key = toEvict.getKey();
                value = toEvict.getValue();
                map.remove(key);
                size -= safeSizeOf(key, value);
                evictionCount++;
            }
            entryRemoved(true, key, value, null);
        }
    }

    public final void evictAll() {
        trimToSize(-1);
    }

    public final synchronized int size() {
        return size;
    }

    public final synchronized int maxSize() {
        return maxSize;
    }

    /** 已用 / 上限，便于日志输出（真机同此）。 */
    public final synchronized int hitCount() {
        return hitCount;
    }

    public final synchronized int missCount() {
        return missCount;
    }

    public final synchronized int createCount() {
        return createCount;
    }

    public final synchronized int putCount() {
        return putCount;
    }

    public final synchronized int evictionCount() {
        return evictionCount;
    }

    /** 当前内容的**浅拷贝**（真机语义：返回新 Map，之后改动不影响缓存）。 */
    public final synchronized Map<K, V> snapshot() {
        return new LinkedHashMap<>(map);
    }

    @Override
    public final synchronized String toString() {
        int accesses = hitCount + missCount;
        int hitPercent = accesses != 0 ? (100 * hitCount / accesses) : 0;
        return "LruCache[maxSize=" + maxSize + ",hits=" + hitCount + ",misses=" + missCount
                + ",hitRate=" + hitPercent + "%]";
    }

    private int safeSizeOf(K key, V value) {
        int result = sizeOf(key, value);
        if (result < 0) {
            throw new IllegalStateException("sizeOf() 返回了负数：key=" + key + " value=" + value);
        }
        return result;
    }

    // ---- 未声明成员（无引用证据，或依赖 Android 特有的堆计量）： ----
    // resize(int) / resizeForTest -> 会在运行时改变上限，真机也是新近才加；当前无引用证据
    // entryRemoved 的 android.util.LruCache#create 变体之外的策略钩子 -> 无
}
