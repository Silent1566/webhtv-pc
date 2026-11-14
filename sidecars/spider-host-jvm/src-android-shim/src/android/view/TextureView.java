package android.view;

import android.content.Context;
import android.graphics.Canvas;
import android.util.AttributeSet;

public class TextureView extends View {

    private static final String UI_PREFIX = "Android UI 路径不在 P1-2 支持范围：";

    private boolean mOpaque = true;
    private boolean mAvailable;

    public TextureView(Context context) {
        super(context);
    }

    public TextureView(Context context, AttributeSet attrs) {
        super(context, attrs);
    }

    public TextureView(Context context, AttributeSet attrs, int defStyleAttr) {
        super(context, attrs, defStyleAttr);
    }

    public TextureView(Context context, AttributeSet attrs, int defStyleAttr, int defStyleRes) {
        super(context, attrs, defStyleAttr, defStyleRes);
    }

    private static String uiUnsupported(String className, String methodName) {
        return UI_PREFIX + className + "#" + methodName;
    }

    public CharSequence getAccessibilityClassName() {
        return TextureView.class.getName();
    }

    public boolean isAvailable() {
        return mAvailable;
    }

    public boolean isOpaque() {
        return mOpaque;
    }

    public void setOpaque(boolean opaque) {
        mOpaque = opaque;
    }

    public final void draw(Canvas canvas) {
        throw new UnsupportedOperationException(uiUnsupported("android.view.TextureView", "draw"));
    }

    protected final void onDraw(Canvas canvas) {
        throw new UnsupportedOperationException(uiUnsupported("android.view.TextureView", "onDraw"));
    }
}
