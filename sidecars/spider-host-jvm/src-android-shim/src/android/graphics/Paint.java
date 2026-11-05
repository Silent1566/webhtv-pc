package android.graphics;

// 为什么 Paint 要真实存值：站点在字段初始化里配好颜色/字号/线宽，后续即便走
// 自绘降级路径也会读回这些值；空壳会让样式全丢，且 null 会传到下游。
public class Paint {

    public static final int ANTI_ALIAS_FLAG = 1;
    public static final int FILTER_BITMAP_FLAG = 2;
    public static final int DITHER_FLAG = 4;
    public static final int UNDERLINE_TEXT_FLAG = 8;
    public static final int STRIKE_THRU_TEXT_FLAG = 16;
    public static final int FAKE_BOLD_TEXT_FLAG = 32;
    public static final int LINEAR_TEXT_FLAG = 64;
    public static final int SUBPIXEL_TEXT_FLAG = 128;
    public static final int DEV_KERN_TEXT_FLAG = 256;
    public static final int EMBEDDED_BITMAP_TEXT_FLAG = 1024;
    public static final int VERTICAL_TEXT_FLAG = 4096;
    public static final int HINTING_OFF = 0;
    public static final int HINTING_ON = 1;
    public static final int CURSOR_BEFORE = 2;
    public static final int CURSOR_AFTER = 0;
    public static final int CURSOR_AT = 4;
    public static final int CURSOR_AT_OR_AFTER = 1;
    public static final int CURSOR_AT_OR_BEFORE = 3;

    private static final String UI_PREFIX = "Android UI 路径不在 P1-2 支持范围：";

    // 没有独立批次文件的嵌套枚举就地声明，二进制名仍是 android/graphics/Paint$Cap 等。
    // 顺序取自 javap -c 的 <clinit> putstatic 顺序。
    public enum Cap {
        BUTT,
        ROUND,
        SQUARE
    }

    public enum Join {
        BEVEL,
        MITER,
        ROUND
    }

    public enum Align {
        CENTER,
        LEFT,
        RIGHT
    }

    public static class FontMetricsInt {
        public int ascent;
        public int bottom;
        public int descent;
        public int leading;
        public int top;

        public void set(Paint$FontMetrics metrics) {
            if (metrics == null) {
                return;
            }
            ascent = (int) Math.floor(metrics.ascent);
            descent = (int) Math.ceil(metrics.descent);
            top = (int) Math.floor(metrics.top);
            bottom = (int) Math.ceil(metrics.bottom);
            leading = (int) Math.floor(metrics.leading);
        }

        public void set(FontMetricsInt metrics) {
            if (metrics == null) {
                return;
            }
            ascent = metrics.ascent;
            descent = metrics.descent;
            top = metrics.top;
            bottom = metrics.bottom;
            leading = metrics.leading;
        }

        @Override
        public String toString() {
            return "FontMetricsInt: top=" + top + " ascent=" + ascent + " descent=" + descent
                    + " bottom=" + bottom + " leading=" + leading;
        }

        @Override
        public boolean equals(Object o) {
            if (this == o) {
                return true;
            }
            if (o == null || getClass() != o.getClass()) {
                return false;
            }
            FontMetricsInt m = (FontMetricsInt) o;
            return ascent == m.ascent && descent == m.descent && top == m.top
                    && bottom == m.bottom && leading == m.leading;
        }

        @Override
        public int hashCode() {
            int result = ascent;
            result = 31 * result + bottom;
            result = 31 * result + descent;
            result = 31 * result + leading;
            result = 31 * result + top;
            return result;
        }
    }

    private static UnsupportedOperationException uiUnsupported(String methodName) {
        return new UnsupportedOperationException(UI_PREFIX + "android.graphics.Paint" + "#" + methodName);
    }

    private int mColor = 0xFF000000;
    private int mAlpha = 255;
    private float mStrokeWidth;
    private float mTextSize;
    private float mTextScaleX = 1.0f;
    private float mTextSkewX;
    private float mLetterSpacing;
    private float mWordSpacing;
    private float mStrokeMiter = 4.0f;
    private Paint$Style mStyle = Paint$Style.FILL;
    private Cap mStrokeCap = Cap.BUTT;
    private Join mStrokeJoin = Join.MITER;
    private Align mTextAlign = Align.LEFT;
    private Typeface mTypeface;
    private int mFlags;

    public Paint() {
    }

    public Paint(int flags) {
        mFlags = flags;
    }

    // 拷贝构造只搬本垫片保存的标量字段；Shader/PathEffect 等一律不支持，天然为 null。
    public Paint(Paint p) {
        if (p == null) {
            return;
        }
        mColor = p.mColor;
        mAlpha = p.mAlpha;
        mStrokeWidth = p.mStrokeWidth;
        mTextSize = p.mTextSize;
        mTextScaleX = p.mTextScaleX;
        mTextSkewX = p.mTextSkewX;
        mLetterSpacing = p.mLetterSpacing;
        mWordSpacing = p.mWordSpacing;
        mStrokeMiter = p.mStrokeMiter;
        mStyle = p.mStyle;
        mStrokeCap = p.mStrokeCap;
        mStrokeJoin = p.mStrokeJoin;
        mTextAlign = p.mTextAlign;
        mTypeface = p.mTypeface;
        mFlags = p.mFlags;
    }

    public void set(Paint src) {
        if (src == null || src == this) {
            return;
        }
        mColor = src.mColor;
        mAlpha = src.mAlpha;
        mStrokeWidth = src.mStrokeWidth;
        mTextSize = src.mTextSize;
        mTextScaleX = src.mTextScaleX;
        mTextSkewX = src.mTextSkewX;
        mLetterSpacing = src.mLetterSpacing;
        mWordSpacing = src.mWordSpacing;
        mStrokeMiter = src.mStrokeMiter;
        mStyle = src.mStyle;
        mStrokeCap = src.mStrokeCap;
        mStrokeJoin = src.mStrokeJoin;
        mTextAlign = src.mTextAlign;
        mTypeface = src.mTypeface;
        mFlags = src.mFlags;
    }

    public void reset() {
        set(new Paint());
    }

    public void setColor(int color) {
        mColor = color;
        mAlpha = (color >>> 24) & 0xFF;
    }

    public int getColor() {
        return mColor;
    }

    public void setAlpha(int alpha) {
        mAlpha = alpha;
    }

    public int getAlpha() {
        return mAlpha;
    }

    public void setARGB(int a, int r, int g, int b) {
        setColor((a << 24) | (r << 16) | (g << 8) | b);
        mAlpha = a;
    }

    public void setStrokeWidth(float width) {
        mStrokeWidth = width;
    }

    public float getStrokeWidth() {
        return mStrokeWidth;
    }

    public void setStyle(Paint$Style style) {
        mStyle = style;
    }

    public Paint$Style getStyle() {
        return mStyle;
    }

    public void setStrokeCap(Cap cap) {
        mStrokeCap = cap;
    }

    public Cap getStrokeCap() {
        return mStrokeCap;
    }

    public void setStrokeJoin(Join join) {
        mStrokeJoin = join;
    }

    public Join getStrokeJoin() {
        return mStrokeJoin;
    }

    public void setStrokeMiter(float miter) {
        mStrokeMiter = miter;
    }

    public float getStrokeMiter() {
        return mStrokeMiter;
    }

    public void setTextSize(float textSize) {
        mTextSize = textSize;
    }

    public float getTextSize() {
        return mTextSize;
    }

    public void setTextScaleX(float scaleX) {
        mTextScaleX = scaleX;
    }

    public float getTextScaleX() {
        return mTextScaleX;
    }

    public void setTextSkewX(float skewX) {
        mTextSkewX = skewX;
    }

    public float getTextSkewX() {
        return mTextSkewX;
    }

    public void setLetterSpacing(float letterSpacing) {
        mLetterSpacing = letterSpacing;
    }

    public float getLetterSpacing() {
        return mLetterSpacing;
    }

    public void setWordSpacing(float wordSpacing) {
        mWordSpacing = wordSpacing;
    }

    public float getWordSpacing() {
        return mWordSpacing;
    }

    public void setTextAlign(Align align) {
        mTextAlign = align;
    }

    public Align getTextAlign() {
        return mTextAlign;
    }

    public void setAntiAlias(boolean aa) {
        mFlags = aa ? (mFlags | ANTI_ALIAS_FLAG) : (mFlags & ~ANTI_ALIAS_FLAG);
    }

    public final boolean isAntiAlias() {
        return (mFlags & ANTI_ALIAS_FLAG) != 0;
    }

    public void setDither(boolean dither) {
        mFlags = dither ? (mFlags | DITHER_FLAG) : (mFlags & ~DITHER_FLAG);
    }

    public final boolean isDither() {
        return (mFlags & DITHER_FLAG) != 0;
    }

    public void setFilterBitmap(boolean filter) {
        mFlags = filter ? (mFlags | FILTER_BITMAP_FLAG) : (mFlags & ~FILTER_BITMAP_FLAG);
    }

    public final boolean isFilterBitmap() {
        return (mFlags & FILTER_BITMAP_FLAG) != 0;
    }

    public void setFakeBoldText(boolean fakeBoldText) {
        mFlags = fakeBoldText ? (mFlags | FAKE_BOLD_TEXT_FLAG) : (mFlags & ~FAKE_BOLD_TEXT_FLAG);
    }

    public final boolean isFakeBoldText() {
        return (mFlags & FAKE_BOLD_TEXT_FLAG) != 0;
    }

    public void setUnderlineText(boolean underlineText) {
        mFlags = underlineText ? (mFlags | UNDERLINE_TEXT_FLAG) : (mFlags & ~UNDERLINE_TEXT_FLAG);
    }

    public final boolean isUnderlineText() {
        return (mFlags & UNDERLINE_TEXT_FLAG) != 0;
    }

    public void setStrikeThruText(boolean strikeThruText) {
        mFlags = strikeThruText ? (mFlags | STRIKE_THRU_TEXT_FLAG) : (mFlags & ~STRIKE_THRU_TEXT_FLAG);
    }

    public final boolean isStrikeThruText() {
        return (mFlags & STRIKE_THRU_TEXT_FLAG) != 0;
    }

    public void setSubpixelText(boolean subpixelText) {
        mFlags = subpixelText ? (mFlags | SUBPIXEL_TEXT_FLAG) : (mFlags & ~SUBPIXEL_TEXT_FLAG);
    }

    public final boolean isSubpixelText() {
        return (mFlags & SUBPIXEL_TEXT_FLAG) != 0;
    }

    public void setLinearText(boolean linearText) {
        mFlags = linearText ? (mFlags | LINEAR_TEXT_FLAG) : (mFlags & ~LINEAR_TEXT_FLAG);
    }

    public final boolean isLinearText() {
        return (mFlags & LINEAR_TEXT_FLAG) != 0;
    }

    public void setFlags(int flags) {
        mFlags = flags;
    }

    public int getFlags() {
        return mFlags;
    }

    // 返回旧值而不是 null：Android 原实现如此，调用方会用返回值还原样式。
    public Typeface setTypeface(Typeface typeface) {
        Typeface old = mTypeface;
        mTypeface = typeface;
        return old;
    }

    public Typeface getTypeface() {
        return mTypeface;
    }

    public void setShadowLayer(float radius, float dx, float dy, int color) {
    }

    public void setShadowLayer(float radius, float dx, float dy, long color) {
    }

    public void clearShadowLayer() {
    }

    // 没有字体引擎，只能按「字符数 × 字号 × 平均字宽系数」估算；
    // 该值仅用于布局占位，站点若据此做像素级对齐会偏差，故注释标明是估算。
    public float measureText(String text) {
        if (text == null || text.isEmpty()) {
            return 0.0f;
        }
        return text.length() * mTextSize * 0.5f;
    }

    public float measureText(String text, int start, int end) {
        if (text == null || start < 0 || end > text.length() || start >= end) {
            return 0.0f;
        }
        return (end - start) * mTextSize * 0.5f;
    }

    public float measureText(char[] text, int index, int count) {
        if (text == null || index < 0 || count <= 0 || index + count > text.length) {
            return 0.0f;
        }
        return count * mTextSize * 0.5f;
    }

    public float measureText(CharSequence text, int start, int end) {
        if (text == null || start < 0 || end > text.length() || start >= end) {
            return 0.0f;
        }
        return (end - start) * mTextSize * 0.5f;
    }

    public int breakText(String text, boolean measureForwards, float maxWidth, float[] measuredWidth) {
        if (text == null || mTextSize <= 0.0f) {
            if (measuredWidth != null && measuredWidth.length > 0) {
                measuredWidth[0] = 0.0f;
            }
            return 0;
        }
        float perChar = mTextSize * 0.5f;
        int count = Math.min(text.length(), (int) (maxWidth / perChar));
        if (count < 0) {
            count = 0;
        }
        if (measuredWidth != null && measuredWidth.length > 0) {
            measuredWidth[0] = count * perChar;
        }
        return count;
    }

    public int getTextWidths(String text, float[] widths) {
        if (text == null || widths == null) {
            return 0;
        }
        int n = Math.min(text.length(), widths.length);
        for (int i = 0; i < n; i++) {
            widths[i] = mTextSize * 0.5f;
        }
        return n;
    }

    // 度量值按字号比例给出（与常见字体的比例接近），供基线计算使用。
    public float ascent() {
        return -mTextSize * 0.8f;
    }

    public float descent() {
        return mTextSize * 0.2f;
    }

    public float getFontSpacing() {
        return descent() - ascent();
    }

    public Paint$FontMetrics getFontMetrics() {
        Paint$FontMetrics fm = new Paint$FontMetrics();
        getFontMetrics(fm);
        return fm;
    }

    // 返回值是行间距，Android 原实现如此（不是 void），调用方常直接用。
    public float getFontMetrics(Paint$FontMetrics metrics) {
        if (metrics != null) {
            metrics.ascent = ascent();
            metrics.descent = descent();
            metrics.top = -mTextSize;
            metrics.bottom = mTextSize * 0.25f;
            metrics.leading = 0.0f;
        }
        return getFontSpacing();
    }

    public FontMetricsInt getFontMetricsInt() {
        FontMetricsInt fm = new FontMetricsInt();
        getFontMetricsInt(fm);
        return fm;
    }

    public int getFontMetricsInt(FontMetricsInt metrics) {
        if (metrics != null) {
            metrics.ascent = (int) Math.floor(ascent());
            metrics.descent = (int) Math.ceil(descent());
            metrics.top = (int) Math.floor(-mTextSize);
            metrics.bottom = (int) Math.ceil(mTextSize * 0.25f);
            metrics.leading = 0;
        }
        return (int) getFontSpacing();
    }

    public boolean hasGlyph(String string) {
        return false;
    }

    public void setShader(Shader shader) {
        throw uiUnsupported("setShader");
    }

    public Shader getShader() {
        return null;
    }

    public void setPathEffect(PathEffect effect) {
        throw uiUnsupported("setPathEffect");
    }

    public PathEffect getPathEffect() {
        return null;
    }

    public void setMaskFilter(MaskFilter maskfilter) {
        throw uiUnsupported("setMaskFilter");
    }

    public MaskFilter getMaskFilter() {
        return null;
    }

    public void getTextPath(char[] text, int index, int count, float x, float y, Path path) {
        throw uiUnsupported("getTextPath");
    }

    public void getTextPath(String text, int start, int end, float x, float y, Path path) {
        throw uiUnsupported("getTextPath");
    }
}
