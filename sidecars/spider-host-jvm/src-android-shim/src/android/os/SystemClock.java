package android.os;

import java.lang.management.ManagementFactory;
import java.lang.management.ThreadMXBean;

/**
 * android.os.SystemClock 的 JVM 实现垫片。
 *
 * <p>真机上这三个时钟对应内核的三种计时（启动后不含深睡的单调时钟、含深睡的开机计时、
 * 线程 CPU 时间）。桌面载体没有内核计时接口，映射关系是：
 * <ul>
 *   <li>{@code uptimeMillis()} / {@code elapsedRealtime()}：同一个 JVM 单调时钟
 *       （{@code System.nanoTime()} 的毫秒化）——桌面载体没有「深睡」这一状态，两者相等是
 *       诚实的结果，不是占位；</li>
 *   <li>{@code elapsedRealtimeNanos()}：{@code System.nanoTime()} 原值；</li>
 *   <li>{@code currentThreadTimeMillis()}：{@code ThreadMXBean} 的当前线程 CPU 时间，
 *       平台不支持时退化为单调时钟（并在方法注释里说明这层退化）。</li>
 * </ul>
 *
 * <p>站源的常见用法（算耗时、做超时、单调递增判断）全部由这三层覆盖；依赖「开机时长」绝对值
 * 的代码在桌面上本来就没有意义。
 */
public class SystemClock {

    /** 单调时钟的原点：类初始化时刻。取相对值而不是进程启动的绝对时刻，避免泄露宿主信息。 */
    private static final long MONOTONIC_ORIGIN_NANOS = System.nanoTime();

    public SystemClock() {
    }

    /** 自垫片初始化起（含进程被挂起的时间）的毫秒数；单调不减。 */
    public static long elapsedRealtime() {
        return uptimeMillis();
    }

    /** 自垫片初始化起的毫秒数；单调不减。 */
    public static long uptimeMillis() {
        return (System.nanoTime() - MONOTONIC_ORIGIN_NANOS) / 1_000_000L;
    }

    /** 高精度单调时钟（纳秒）；可用于测很短的区间。 */
    public static long elapsedRealtimeNanos() {
        return System.nanoTime() - MONOTONIC_ORIGIN_NANOS;
    }

    /**
     * 当前线程已消耗的 CPU 时间（毫秒）。{@code ThreadMXBean} 不可用时退回
     * {@link #uptimeMillis()}——那时它测的是墙钟而不是 CPU 时间，属于平台退化。
     */
    public static long currentThreadTimeMillis() {
        ThreadMXBean bean = ManagementFactory.getThreadMXBean();
        if (bean == null || !bean.isCurrentThreadCpuTimeSupported()) {
            return uptimeMillis();
        }
        long nanos = bean.getCurrentThreadCpuTime();
        if (nanos < 0) {
            return uptimeMillis();
        }
        return nanos / 1_000_000L;
    }

    /**
     * 睡够指定毫秒（真机语义：**不**抛 {@code InterruptedException}，被打断就重新睡满剩余时间）。
     */
    public static void sleep(long millis) {
        long deadline = uptimeMillis() + Math.max(0L, millis);
        long remaining = Math.max(0L, millis);
        do {
            try {
                Thread.sleep(remaining);
            } catch (InterruptedException ignored) {
                // 真机同样吞掉中断并继续睡；调用方要取消应该用 CallContext.checkCancelled()。
            }
            remaining = deadline - uptimeMillis();
        } while (remaining > 0);
    }

    // ---- 未声明成员（依赖 Android Binder/内核接口，桌面载体无对应能力）： ----
    // setCurrentTimeMillis(long) -> 需要 CAP_SYS_TIME 与系统时钟服务
    // currentGnssTimeClock()/currentNetworkTimeClock() -> android.os.Clock 需补，且桌面无时钟源
}
