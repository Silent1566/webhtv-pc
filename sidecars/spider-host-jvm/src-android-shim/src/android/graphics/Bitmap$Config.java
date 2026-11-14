package android.graphics;

// 为什么是顶层类而不是 Bitmap 的嵌套类：批次文件清单要求每个垫片类各占一个源文件，
// 而 `$` 在 Java 标识符里合法，所以顶层类名为 `Bitmap$Config` 时产出的二进制名
// 仍是 android/graphics/Bitmap$Config.class —— 与 android.jar 里的嵌套枚举二进制名一致，
// dex 转译出来的站代码按二进制名做链接，因此可直接命中。
//
// 常量与顺序按 javap -c 的 <clinit> putstatic 顺序，与 Android 36 的声明顺序一致。
public enum Bitmap$Config {
    ALPHA_8,
    ARGB_4444,
    ARGB_8888,
    HARDWARE,
    RGBA_1010102,
    RGBA_F16,
    RGB_565
}
