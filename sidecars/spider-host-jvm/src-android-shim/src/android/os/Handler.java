package android.os;

/**
 * android.os.Handler 的同步退化实现。
 *
 * <p>真机 Handler 把 Runnable/Message 投递到 Looper 的消息队列，由 loop 线程异步消费；
 * 桌面宿主没有独立 UI 线程，也不需要异步——站源里 {@code handler.post(x)} 的语义本质是
 * 「稍后会执行 x」，同步执行只会让时序变早，不会丢执行，因此这里一律**在调用线程立即执行**。
 *
 * <p>线程安全：因为全部同步执行、无共享队列，不需要 synchronized。
 */
public class Handler {

    /**
     * 真机 Handler$Callback 是嵌套接口，仓库里没有单独的 Callback.java；
     * 声明成嵌套接口既与 javap 的 {@code android.os.Handler$Callback} 一致，也不额外建文件。
     */
    public interface Callback {
        boolean handleMessage(Message msg);
    }

    private final Looper looper;
    private final Callback callback;

    public Handler() {
        this(Looper.myLooper(), null);
    }

    public Handler(Callback callback) {
        this(Looper.myLooper(), callback);
    }

    public Handler(Looper looper) {
        this(looper, null);
    }

    public Handler(Looper looper, Callback callback) {
        // looper 为 null 时也照常工作：同步实现不需要队列，只有 getLooper() 会返回 null。
        this.looper = looper;
        this.callback = callback;
    }

    public static Handler createAsync(Looper looper) {
        return new Handler(looper);
    }

    public static Handler createAsync(Looper looper, Callback callback) {
        return new Handler(looper, callback);
    }

    public final Looper getLooper() {
        return looper;
    }

    public final boolean post(Runnable r) {
        return postAtTime(r, 0L);
    }

    public final boolean postDelayed(Runnable r, long delayMillis) {
        // 忽略延迟：桌面没有定时器线程，延迟执行只会让站源的初始化逻辑变成竞态。
        return postAtTime(r, delayMillis);
    }

    public final boolean postDelayed(Runnable r, Object token, long delayMillis) {
        return postAtTime(r, token, delayMillis);
    }

    public final boolean postAtTime(Runnable r, long uptimeMillis) {
        if (r == null) {
            return false;
        }
        r.run();
        return true;
    }

    public final boolean postAtTime(Runnable r, Object token, long uptimeMillis) {
        // token 只在 removeCallbacks 里用于取消；同步执行后已无待执行项，故不必保存。
        return postAtTime(r, uptimeMillis);
    }

    public final boolean postAtFrontOfQueue(Runnable r) {
        return postAtTime(r, 0L);
    }

    public final void removeCallbacks(Runnable r) {
        // 空操作：投递即执行，调用此方法时已经没有排队中的回调可移除。
    }

    public final void removeCallbacks(Runnable r, Object token) {
        // 同上。
    }

    public final void removeCallbacksAndMessages(Object token) {
        // 同上。
    }

    public final void removeMessages(int what) {
        // 同上。
    }

    public final void removeMessages(int what, Object object) {
        // 同上。
    }

    public final boolean hasCallbacks(Runnable r) {
        return false;
    }

    public final boolean hasMessages(int what) {
        return false;
    }

    public final boolean hasMessages(int what, Object object) {
        return false;
    }

    public void handleMessage(Message msg) {
        // 供子类覆盖的空方法，与真机一致。
    }

    public void dispatchMessage(Message msg) {
        if (msg == null) {
            return;
        }
        Runnable callback = msg.getCallback();
        if (callback != null) {
            callback.run();
            return;
        }
        if (this.callback != null && this.callback.handleMessage(msg)) {
            return;
        }
        handleMessage(msg);
    }

    public String getMessageName(Message message) {
        return message == null ? "null" : Integer.toString(message.what);
    }

    public final boolean sendMessage(Message msg) {
        return sendMessageAtTime(msg, 0L);
    }

    public final boolean sendMessageDelayed(Message msg, long delayMillis) {
        return sendMessageAtTime(msg, delayMillis);
    }

    public boolean sendMessageAtTime(Message msg, long uptimeMillis) {
        if (msg == null) {
            return false;
        }
        msg.setTarget(this);
        dispatchMessage(msg);
        return true;
    }

    public final boolean sendMessageAtFrontOfQueue(Message msg) {
        return sendMessageAtTime(msg, 0L);
    }

    public final boolean sendEmptyMessage(int what) {
        return sendMessage(Message.obtain(this, what));
    }

    public final boolean sendEmptyMessageDelayed(int what, long delayMillis) {
        return sendMessageDelayed(Message.obtain(this, what), delayMillis);
    }

    public final boolean sendEmptyMessageAtTime(int what, long uptimeMillis) {
        return sendMessageAtTime(Message.obtain(this, what), uptimeMillis);
    }

    public final Message obtainMessage() {
        return Message.obtain(this);
    }

    public final Message obtainMessage(int what) {
        return Message.obtain(this, what);
    }

    public final Message obtainMessage(int what, Object obj) {
        return Message.obtain(this, what, obj);
    }

    public final Message obtainMessage(int what, int arg1, int arg2) {
        return Message.obtain(this, what, arg1, arg2);
    }

    public final Message obtainMessage(int what, int arg1, int arg2, Object obj) {
        return Message.obtain(this, what, arg1, arg2, obj);
    }

    @Override
    public String toString() {
        return "Handler (" + looper + ")";
    }

    // ---- 未声明成员（签名依赖本批次不负责的类型，另见报告的「仓库内缺失类」）： ----
    // public final void dump(android.util.Printer, String)  -> android.util.Printer 需补
}
