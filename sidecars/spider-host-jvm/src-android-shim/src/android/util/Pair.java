package android.util;

/**
 * android.util.Pair 的 JVM 实现垫片。
 *
 * <p>真机上这个类只有「两个 final 字段 + 值语义」三件事，没有隐藏状态，所以可以完整实现，
 * 不存在需要登记为「未声明」的成员。
 *
 * <p>字段名 {@code first}/{@code second} 与公开文档一致，且**不能**改名：站源字节码直接
 * 按 {@code getfield android/util/Pair.first} 链接，改字段名只会把失败从缺类换成缺字段。
 */
public class Pair<F, S> {

    public final F first;

    public final S second;

    public Pair(F first, S second) {
        this.first = first;
        this.second = second;
    }

    /** 与 AOSP 同签名：{@code Pair.create(a, b)} 等价于 {@code new Pair<>(a, b)}。 */
    public static <A, B> Pair<A, B> create(A a, B b) {
        return new Pair<>(a, b);
    }

    /** 值语义：任一侧为 null 也按相等比较（{@code Objects.equals} 语义）。 */
    @Override
    public boolean equals(Object object) {
        if (object == this) {
            return true;
        }
        if (!(object instanceof Pair<?, ?> other)) {
            return false;
        }
        return (first == null ? other.first == null : first.equals(other.first))
                && (second == null ? other.second == null : second.equals(other.second));
    }

    /** AOSP 的异或组合；两侧都为空时得 0（与 {@code new Pair<>(null, null)} 的约定一致）。 */
    @Override
    public int hashCode() {
        return (first == null ? 0 : first.hashCode()) ^ (second == null ? 0 : second.hashCode());
    }

    /**
     * 这里**超出** AOSP 声明面一步：AOSP 的 Pair 没有覆写 toString（沿用
     * {@code Object.toString} 的「类名@哈希」）。垫片覆写它的理由是桌面侧没有调试器时
     * 站源日志会打印 Pair，而 {@code android.util.Log} 垫片只落 stderr，无法回查对象内容。
     * 该差异只影响日志文本，不影响任何相等性或链接行为。
     */
    @Override
    public String toString() {
        return "Pair{" + first + ", " + second + "}";
    }
}
