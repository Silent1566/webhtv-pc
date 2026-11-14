package android.view;

import android.content.Context;
import android.graphics.Canvas;
import android.util.AttributeSet;

public class SurfaceView extends View {

    public static final int SURFACE_LIFECYCLE_DEFAULT = 0;
    public static final int SURFACE_LIFECYCLE_FOLLOWS_VISIBILITY = 1;
    public static final int SURFACE_LIFECYCLE_FOLLOWS_ATTACHMENT = 2;

    private static final String UI_PREFIX = "Android UI 路径不在 P1-2 支持范围：";

    private boolean mSecure;
    private boolean mZOrderOnTop;
    private boolean mZOrderMediaOverlay;
    private int mSurfaceLifecycle = SURFACE_LIFECYCLE_DEFAULT;

    public SurfaceView(Context context) {
        super(context);
    }

    public SurfaceView(Context context, AttributeSet attrs) {
        super(context, attrs);
    }

    public SurfaceView(Context context, AttributeSet attrs, int defStyleAttr) {
        super(context, attrs, defStyleAttr);
    }

    public SurfaceView(Context context, AttributeSet attrs, int defStyleAttr, int defStyleRes) {
        super(context, attrs, defStyleAttr, defStyleRes);
    }

    private static String uiUnsupported(String className, String methodName) {
        return UI_PREFIX + className + "#" + methodName;
    }

    public boolean hasOverlappingRendering() {
        return false;
    }

    public CharSequence getAccessibilityClassName() {
        return SurfaceView.class.getName();
    }

    public void setSecure(boolean secure) {
        mSecure = secure;
    }

    public void setSurfaceLifecycle(int lifecycleStrategy) {
        mSurfaceLifecycle = lifecycleStrategy;
    }

    public void setZOrderMediaOverlay(boolean isMediaOverlay) {
        mZOrderMediaOverlay = isMediaOverlay;
    }

    public void setZOrderOnTop(boolean onTop) {
        mZOrderOnTop = onTop;
    }

    public void draw(Canvas canvas) {
        throw new UnsupportedOperationException(uiUnsupported("android.view.SurfaceView", "draw"));
    }

    protected void dispatchDraw(Canvas canvas) {
        throw new UnsupportedOperationException(uiUnsupported("android.view.SurfaceView", "dispatchDraw"));
    }

    protected void onMeasure(int widthMeasureSpec, int heightMeasureSpec) {
        throw new UnsupportedOperationException(uiUnsupported("android.view.SurfaceView", "onMeasure"));
    }
}
