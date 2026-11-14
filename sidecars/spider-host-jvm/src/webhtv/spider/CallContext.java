package webhtv.spider;

import java.util.concurrent.CancellationException;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;

/**
 * 传给站源的调用上下文：提供取消检查与可中断等待（§9.2、§9.5）。
 *
 * <p>与 Python 侧 {@code CallContext} 语义一致：站源在耗时循环里调用
 * {@link #checkCancelled()}，宿主发来的 {@code $/cancelRequest} 就能立即生效；
 * {@link #sleep(long)} 是可被取消打断的等待。
 */
public final class CallContext {
    private final String requestId;
    private final CountDownLatch cancelled = new CountDownLatch(1);
    private volatile long deadlineNanos;

    CallContext(String requestId, long deadlineNanos) {
        this.requestId = requestId;
        this.deadlineNanos = deadlineNanos;
    }

    public String requestId() {
        return requestId;
    }

    public boolean isCancelled() {
        return cancelled.getCount() == 0;
    }

    /** 已取消或已过 deadline 时抛异常，让宿主归一化为 SPIDER_CANCELLED。 */
    public void checkCancelled() {
        if (isCancelled()) {
            throw new CancellationException("调用方已取消该请求");
        }
        if (deadlineNanos > 0 && System.nanoTime() > deadlineNanos) {
            throw new CancellationException("请求已超过 deadline");
        }
    }

    /** 可被取消打断的等待。 */
    public void sleep(long millis) throws InterruptedException {
        checkCancelled();
        if (cancelled.await(millis, TimeUnit.MILLISECONDS)) {
            throw new CancellationException("调用方已取消该请求");
        }
        checkCancelled();
    }

    void markCancelled() {
        cancelled.countDown();
    }

    void setDeadline(long deadlineNanos) {
        this.deadlineNanos = deadlineNanos;
    }
}
