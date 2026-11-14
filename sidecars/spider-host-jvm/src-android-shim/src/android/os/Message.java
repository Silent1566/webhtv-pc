package android.os;

/**
 * android.os.Message 的桌面实现。
 *
 * <p>真机 Message 是 Looper 队列里的消息载体，靠 obtain/recycle 池化来减少分配；
 * 这里没有队列、也没有并发消费，池化只会把「上一个使用者留下的旧字段」变成难以复现的脏数据，
 * 所以 obtain 系列一律返回全新实例，recycle 退化为空操作。
 *
 * <p>{@code sendToTarget()} 直接转交 Handler：本仓库的 Handler 是同步退化实现
 * （投递即执行），所以这里不需要把消息压进任何队列。
 */
public final class Message {

    // 站源直接读写这些公有字段（msg.what / arg1 / arg2 / obj），必须与 javap 完全一致地真实存在。
    public int what;
    public int arg1;
    public int arg2;
    public Object obj;
    public int sendingUid = -1;

    private Handler target;
    private Runnable callback;
    private long when;
    private boolean asynchronous;

    public Message() {
        // when 在这里取时刻：桌面版没有延迟投递的时序语义，只要 getWhen() 能给出一个单调可信的值即可。
        this.when = System.currentTimeMillis();
    }

    public static Message obtain() {
        return new Message();
    }

    public static Message obtain(Message orig) {
        Message m = new Message();
        if (orig != null) {
            m.what = orig.what;
            m.arg1 = orig.arg1;
            m.arg2 = orig.arg2;
            m.obj = orig.obj;
            m.callback = orig.callback;
            m.asynchronous = orig.asynchronous;
        }
        return m;
    }

    public static Message obtain(Handler h) {
        Message m = new Message();
        m.target = h;
        return m;
    }

    public static Message obtain(Handler h, int what) {
        Message m = obtain(h);
        m.what = what;
        return m;
    }

    public static Message obtain(Handler h, int what, int arg1, int arg2) {
        Message m = obtain(h, what);
        m.arg1 = arg1;
        m.arg2 = arg2;
        return m;
    }

    public static Message obtain(Handler h, int what, int arg1, int arg2, Object obj) {
        Message m = obtain(h, what, arg1, arg2);
        m.obj = obj;
        return m;
    }

    public static Message obtain(Handler h, int what, Object obj) {
        Message m = obtain(h, what);
        m.obj = obj;
        return m;
    }

    public static Message obtain(Handler h, Runnable callback) {
        Message m = obtain(h);
        m.callback = callback;
        return m;
    }

    public void recycle() {
        // 空操作：obtain 每次都给新实例，没有池可以归还；把字段清空反而会丢掉调用方仍在读的数据。
    }

    public void copyFrom(Message o) {
        if (o == null) {
            return;
        }
        this.what = o.what;
        this.arg1 = o.arg1;
        this.arg2 = o.arg2;
        this.obj = o.obj;
        this.callback = o.callback;
        this.asynchronous = o.asynchronous;
    }

    public Runnable getCallback() {
        return callback;
    }

    public Handler getTarget() {
        return target;
    }

    public long getWhen() {
        return when;
    }

    public void setTarget(Handler target) {
        this.target = target;
    }

    public boolean isAsynchronous() {
        return asynchronous;
    }

    public void setAsynchronous(boolean async) {
        this.asynchronous = async;
    }

    public void sendToTarget() {
        if (target == null) {
            // 静默返回：站源里常见「先 obtain 再补 target」的写法，真机此处会抛，抛了只会打断整条初始化链路。
            return;
        }
        target.sendMessage(this);
    }

    @Override
    public String toString() {
        return "Message{what=" + what + ", arg1=" + arg1 + ", arg2=" + arg2 + ", obj=" + obj + "}";
    }

    // ---- 未声明成员（签名依赖本仓库没有的类型，声明即编译失败）： ----
    // public android.os.Messenger replyTo                     -> android.os.Messenger 不存在
    // public android.os.Bundle getData()/peekData()/setData() -> android.os.Bundle 不存在
    // implements android.os.Parcelable + writeToParcel/describeContents/CREATOR
    //                                                          -> android.os.Parcel / Parcelable 不存在
}
