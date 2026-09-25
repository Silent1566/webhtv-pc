package local.webhtv.phase0;

public final class LibMpv implements AutoCloseable {
    static {
        System.loadLibrary("webhtv_mpv_jni");
    }

    private long handle;

    public LibMpv() {
        handle = create();
        if (handle == 0) {
            throw new IllegalStateException("libmpv 初始化失败");
        }
    }

    public native String clientVersion();
    public native void load(String url, String referer, String userAgent);
    public native void seek(double seconds);
    public native double playbackTime();
    public native void setFullscreen(boolean enabled);
    public native String waitForEvent(double timeoutSeconds);
    public native String waitForPlaybackResult(double timeoutSeconds);

    private native long create();
    private native void destroy(long value);

    @Override
    public void close() {
        if (handle != 0) {
            destroy(handle);
            handle = 0;
        }
    }
}
