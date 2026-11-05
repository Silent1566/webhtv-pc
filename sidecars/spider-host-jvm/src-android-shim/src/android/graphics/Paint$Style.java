package android.graphics;

// 为什么是顶层类：见 Bitmap$Config.java 的说明（源文件名与二进制名 android/graphics/Paint$Style.class 对齐）。
// 顺序取自 javap -c 的 <clinit> putstatic 顺序：FILL, FILL_AND_STROKE, STROKE。
public enum Paint$Style {
    FILL,
    FILL_AND_STROKE,
    STROKE
}
