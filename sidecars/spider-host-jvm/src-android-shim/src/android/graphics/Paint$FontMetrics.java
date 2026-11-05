package android.graphics;

// 为什么是顶层类：见 Bitmap$Config.java 的说明（源文件名与二进制名 android/graphics/Paint$FontMetrics.class 对齐）。
// 字段名与顺序按 javap 输出：ascent, bottom, descent, leading, top。
public class Paint$FontMetrics {

    public float ascent;
    public float bottom;
    public float descent;
    public float leading;
    public float top;

    public Paint$FontMetrics() {
    }

    @Override
    public boolean equals(Object o) {
        if (this == o) {
            return true;
        }
        if (o == null || getClass() != o.getClass()) {
            return false;
        }
        Paint$FontMetrics m = (Paint$FontMetrics) o;
        return Float.floatToIntBits(ascent) == Float.floatToIntBits(m.ascent)
                && Float.floatToIntBits(bottom) == Float.floatToIntBits(m.bottom)
                && Float.floatToIntBits(descent) == Float.floatToIntBits(m.descent)
                && Float.floatToIntBits(leading) == Float.floatToIntBits(m.leading)
                && Float.floatToIntBits(top) == Float.floatToIntBits(m.top);
    }

    @Override
    public int hashCode() {
        int result = Float.floatToIntBits(ascent);
        result = 31 * result + Float.floatToIntBits(bottom);
        result = 31 * result + Float.floatToIntBits(descent);
        result = 31 * result + Float.floatToIntBits(leading);
        result = 31 * result + Float.floatToIntBits(top);
        return result;
    }

    @Override
    public String toString() {
        return "FontMetrics [ascent=" + ascent + ", bottom=" + bottom + ", descent=" + descent
                + ", leading=" + leading + ", top=" + top + "]";
    }
}
