package android.graphics;

import java.io.OutputStream;

// 为什么 Bitmap 要「可建但不可绘制」：站点代码常在字段初始化里调用
// Bitmap.createBitmap 并在失败后降级到自绘路径，若构造器本身抛异常，
// 站点类连实例化都做不到，降级分支根本没机会执行。
public class Bitmap {

    public static final int DENSITY_NONE = 0;

    private static final String UI_PREFIX = "Android UI 路径不在 P1-2 支持范围：";

    // javap 里 CompressFormat 是 Bitmap 的嵌套枚举，没有独立的批次文件分配，
    // 因此就地嵌套声明；二进制名仍是 android/graphics/Bitmap$CompressFormat。
    // 顺序取自 javap -c 的 <clinit> putstatic 顺序。
    public enum CompressFormat {
        JPEG,
        PNG,
        WEBP,
        WEBP_LOSSLESS,
        WEBP_LOSSY
    }

    private int mWidth;
    private int mHeight;
    private Bitmap$Config mConfig;
    private boolean mRecycled;
    private boolean mMutable;
    private boolean mHasAlpha = true;
    private boolean mHasMipMap;
    private int mDensity = DENSITY_NONE;
    private int mGenerationId;

    // 真实 android.jar 里是包私有构造器；这里放宽为 public：站点代码在 android.graphics
    // 包外也需要一个「能建出来但不带像素」的实例来走降级分支，包私有会让该分支不可达。
    public Bitmap() {
    }

    private static UnsupportedOperationException uiUnsupported(String methodName) {
        return new UnsupportedOperationException(UI_PREFIX + "android.graphics.Bitmap" + "#" + methodName);
    }

    // 每像素字节数只用于 getByteCount/getRowBytes 的估算，不做真实内存分配。
    private static int bytesPerPixel(Bitmap$Config config) {
        if (config == null) {
            return 0;
        }
        switch (config) {
            case ALPHA_8:
                return 1;
            case RGB_565:
            case ARGB_4444:
                return 2;
            case ARGB_8888:
            case RGBA_1010102:
            case HARDWARE:
                return 4;
            case RGBA_F16:
                return 8;
            default:
                return 4;
        }
    }

    public int getWidth() {
        return mWidth;
    }

    public int getHeight() {
        return mHeight;
    }

    // javap 里确实有这对 setter（供 dexdump 出来的代码回写尺寸），保持为普通赋值。
    public void setWidth(int width) {
        mWidth = width;
    }

    public void setHeight(int height) {
        mHeight = height;
    }

    public Bitmap$Config getConfig() {
        return mConfig;
    }

    public void setConfig(Bitmap$Config config) {
        mConfig = config;
    }

    public boolean isRecycled() {
        return mRecycled;
    }

    // recycle 只标记状态：没有底层像素可释放，抛异常反而会让 finally 里的清理炸掉。
    public void recycle() {
        mRecycled = true;
    }

    public boolean isMutable() {
        return mMutable;
    }

    public boolean hasAlpha() {
        return mHasAlpha;
    }

    public void setHasAlpha(boolean hasAlpha) {
        mHasAlpha = hasAlpha;
    }

    public boolean hasMipMap() {
        return mHasMipMap;
    }

    public void setHasMipMap(boolean hasMipMap) {
        mHasMipMap = hasMipMap;
    }

    public int getDensity() {
        return mDensity;
    }

    public void setDensity(int density) {
        mDensity = density;
    }

    public int getGenerationId() {
        return mGenerationId;
    }

    public int getRowBytes() {
        return mWidth * bytesPerPixel(mConfig);
    }

    public int getByteCount() {
        return getRowBytes() * mHeight;
    }

    public int getAllocationByteCount() {
        return getByteCount();
    }

    public void prepareToDraw() {
    }

    public static Bitmap createBitmap(Bitmap src) {
        throw uiUnsupported("createBitmap");
    }

    public static Bitmap createBitmap(Bitmap src, int x, int y, int width, int height) {
        throw uiUnsupported("createBitmap");
    }

    public static Bitmap createBitmap(int width, int height, Bitmap$Config config) {
        throw uiUnsupported("createBitmap");
    }

    public static Bitmap createBitmap(int width, int height, Bitmap$Config config, boolean hasAlpha) {
        throw uiUnsupported("createBitmap");
    }

    public static Bitmap createBitmap(int[] colors, int width, int height, Bitmap$Config config) {
        throw uiUnsupported("createBitmap");
    }

    public static Bitmap createBitmap(int[] colors, int offset, int stride, int width, int height, Bitmap$Config config) {
        throw uiUnsupported("createBitmap");
    }

    public static Bitmap createScaledBitmap(Bitmap src, int dstWidth, int dstHeight, boolean filter) {
        throw uiUnsupported("createScaledBitmap");
    }

    public boolean compress(CompressFormat format, int quality, OutputStream stream) {
        throw uiUnsupported("compress");
    }

    public void getPixels(int[] pixels, int offset, int stride, int x, int y, int width, int height) {
        throw uiUnsupported("getPixels");
    }

    public void setPixels(int[] pixels, int offset, int stride, int x, int y, int width, int height) {
        throw uiUnsupported("setPixels");
    }

    public Bitmap copy(Bitmap$Config config, boolean isMutable) {
        throw uiUnsupported("copy");
    }

    public void eraseColor(int color) {
        throw uiUnsupported("eraseColor");
    }

    public void eraseColor(long color) {
        throw uiUnsupported("eraseColor");
    }

    public int getPixel(int x, int y) {
        throw uiUnsupported("getPixel");
    }

    public void setPixel(int x, int y, int color) {
        throw uiUnsupported("setPixel");
    }
}
