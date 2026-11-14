package android.os;

/**
 * android.os.Looper 的桌面退化实现。
 *
 * <p>真机上 Looper 是「阻塞消费消息队列」的主循环；桌面宿主没有消息队列，
 * 也不需要把线程让出去，所以这里只保留「每线程一个实例」和退出语义。
 *
 * <p>loop() 刻意写成**有界**循环：站源里常见的
 * {@code new Thread(() -> { Looper.prepare(); ...; Looper.loop(); }).start()}
 * 若在桌面用 while(true) 实现，会把宿主进程永久挂住。这里最多转
 * {@link #MAX_LOOP_ROUNDS} 轮就返回。
 */
public final class Looper {

    /** loop() 的硬上界；不是业务量，只是防挂死的安全阀。 */
    private static final int MAX_LOOP_ROUNDS = 1000;

    private static final ThreadLocal<Looper> THREAD_LOCAL = new ThreadLocal<>();

    private static volatile Looper sMainLooper;

    private final Thread thread;

    private volatile boolean quitRequested;

    Looper() {
        // javap 显示构造器是包级私有，保持一致的可见性。
        this.thread = Thread.currentThread();
    }

    public static void prepare() {
        if (THREAD_LOCAL.get() != null) {
            // 真机会抛 RuntimeException；桌面下重复 prepare 无害，直接幂等返回更不容易炸站源。
            return;
        }
        THREAD_LOCAL.set(new Looper());
    }

    public static void prepareMainLooper() {
        prepare();
        synchronized (Looper.class) {
            if (sMainLooper == null) {
                sMainLooper = myLooper();
            }
        }
    }

    public static Looper getMainLooper() {
        return sMainLooper;
    }

    public static Looper myLooper() {
        return THREAD_LOCAL.get();
    }

    public static void loop() {
        Looper me = myLooper();
        if (me == null) {
            throw new IllegalStateException("No Looper; Looper.prepare() wasn't called on this thread.");
        }
        // 桌面退化：没有可阻塞消费的消息队列（Handler 直接同步执行，队列恒为空），
        // 等价于真机「队列已空且没有下一条消息」的情形，第一轮即返回。
        // 外层上界仍然保留：将来若真的接了队列，忘记设退出条件也不会挂住宿主进程。
        for (int rounds = 0; !me.quitRequested && rounds < MAX_LOOP_ROUNDS; rounds++) {
            break;
        }
    }

    public Thread getThread() {
        return thread;
    }

    public boolean isCurrentThread() {
        return thread == Thread.currentThread();
    }

    public void quit() {
        quitRequested = true;
    }

    public void quitSafely() {
        // 同步模型下没有「已入队但未执行」的消息，两个退出语义合并。
        quitRequested = true;
    }

    @Override
    public String toString() {
        return "Looper (" + thread.getName() + ")";
    }

    // ---- 以下成员在真机存在，但签名依赖本批次不负责/仓库中尚缺的类型，故未声明： ----
    // public MessageQueue getQueue()
    // public static MessageQueue myQueue()            -> android.os.MessageQueue 需由其他批次补
    // public void dump(android.util.Printer, String)  -> android.util.Printer 需补
    // public void setMessageLogging(android.util.Printer) 同上
}
