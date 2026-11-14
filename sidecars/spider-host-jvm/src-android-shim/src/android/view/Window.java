package android.view;

import android.content.Context;
import android.graphics.drawable.Drawable;

public abstract class Window {

    public static final int FEATURE_ACTION_BAR = 8;
    public static final int FEATURE_CUSTOM_TITLE = 7;
    public static final int FEATURE_INDETERMINATE_PROGRESS = 5;
    public static final int FEATURE_NO_TITLE = 1;
    public static final int FEATURE_PROGRESS = 2;
    public static final int ID_ANDROID_CONTENT = 16908290;

    private static final String UI_PREFIX = "Android UI 路径不在 P1-2 支持范围：";

    private final Context mContext;
    private int mLayoutWidth = -1;
    private int mLayoutHeight = -1;
    private int mGravity;
    private int mFormat;
    private int mType;
    private int mSoftInputMode;
    private float mDimAmount = -1.0f;
    private float mElevation;
    private int mFeatures;

    public Window(Context context) {
        mContext = context;
    }

    private static String uiUnsupported(String className, String methodName) {
        return UI_PREFIX + className + "#" + methodName;
    }

    public final Context getContext() {
        return mContext;
    }

    public void setContentView(int layoutResID) {
        throw new UnsupportedOperationException(uiUnsupported("android.view.Window", "setContentView"));
    }

    public void setContentView(View view) {
        throw new UnsupportedOperationException(uiUnsupported("android.view.Window", "setContentView"));
    }

    public void setContentView(View view, ViewGroup.LayoutParams params) {
        throw new UnsupportedOperationException(uiUnsupported("android.view.Window", "setContentView"));
    }

    public final <T extends View> T findViewById(int id) {
        throw new UnsupportedOperationException(uiUnsupported("android.view.Window", "findViewById"));
    }

    public void setLayout(int width, int height) {
        mLayoutWidth = width;
        mLayoutHeight = height;
    }

    public void setFlags(int flags, int mask) {
    }

    public void addFlags(int flags) {
    }

    public void clearFlags(int flags) {
    }

    public void setGravity(int gravity) {
        mGravity = gravity;
    }

    public void setFormat(int format) {
        mFormat = format;
    }

    public void setType(int type) {
        mType = type;
    }

    public void setSoftInputMode(int mode) {
        mSoftInputMode = mode;
    }

    public void setDimAmount(float amount) {
        mDimAmount = amount;
    }

    public void setElevation(float elevation) {
        mElevation = elevation;
    }

    public void setIcon(int resId) {
    }

    public void setLogo(int resId) {
    }

    public void setBackgroundDrawableResource(int resId) {
    }

    public void setWindowAnimations(int resId) {
    }

    public void setUiOptions(int uiOptions) {
    }

    public void setUiOptions(int uiOptions, int mask) {
    }

    public boolean requestFeature(int featureId) {
        mFeatures |= featureId;
        return true;
    }

    public boolean hasFeature(int feature) {
        return (mFeatures & feature) != 0;
    }

    public abstract void addContentView(View view, ViewGroup.LayoutParams params);

    public abstract void closeAllPanels();

    public abstract void closePanel(int featureId);

    public abstract View getCurrentFocus();

    public abstract View getDecorView();

    public abstract void invalidatePanelMenu(int featureId);

    public abstract boolean isFloating();

    public abstract void openPanel(int featureId, KeyEvent event);

    public abstract View peekDecorView();

    public abstract boolean performContextMenuIdentifierAction(int id, int flags);

    public abstract boolean performPanelIdentifierAction(int featureId, int id, int flags);

    public abstract boolean performPanelShortcut(int featureId, int keyCode, KeyEvent event, int flags);

    public abstract void setBackgroundDrawable(Drawable drawable);

    public abstract void setChildDrawable(int featureId, Drawable drawable);

    public abstract void setChildInt(int featureId, int value);

    public abstract void setDecorCaptionShade(int decorCaptionShade);

    public abstract void setFeatureDrawable(int featureId, Drawable drawable);

    public abstract void setFeatureDrawableAlpha(int featureId, int alpha);

    public abstract void setFeatureDrawableResource(int featureId, int resId);

    public abstract void setFeatureInt(int featureId, int value);

    public abstract int getNavigationBarColor();

    public abstract int getStatusBarColor();

    public abstract int getVolumeControlStream();

    public abstract boolean isShortcutKey(int keyCode, KeyEvent event);

    public abstract void setNavigationBarColor(int color);

    public abstract void setResizingCaptionDrawable(Drawable drawable);

    public abstract void setStatusBarColor(int color);

    public abstract void setTitle(CharSequence title);

    public abstract void setTitleColor(int textColor);

    public abstract void setVolumeControlStream(int streamType);

    public abstract boolean superDispatchKeyEvent(KeyEvent event);

    public abstract boolean superDispatchKeyShortcutEvent(KeyEvent event);

    public abstract void takeKeyEvents(boolean get);

    public abstract void togglePanel(int featureId, KeyEvent event);

    protected abstract void onActive();
}
