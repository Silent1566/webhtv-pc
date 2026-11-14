package android.view;

import android.content.Context;
import android.graphics.Canvas;
import android.graphics.drawable.Drawable;
import android.util.AttributeSet;

public class View implements KeyEvent.Callback {

    public static final int NO_ID = -1;
    public static final int VISIBLE = 0;
    public static final int INVISIBLE = 4;
    public static final int GONE = 8;

    private static final String UI_PREFIX = "Android UI 路径不在 P1-2 支持范围：";

    private final Context mContext;
    private int mId = NO_ID;
    private int mVisibility = VISIBLE;
    private Object mTag;
    private ViewGroup.LayoutParams mLayoutParams;
    private Drawable mBackground;
    private OnClickListener mOnClickListener;
    private CharSequence mContentDescription;
    private boolean mEnabled = true;
    private boolean mClickable;
    private boolean mFocusable;
    private int mMinimumWidth;
    private int mMinimumHeight;
    private float mAlpha = 1.0f;
    private int mPaddingLeft;
    private int mPaddingTop;
    private int mPaddingRight;
    private int mPaddingBottom;
    private int mLeft;
    private int mTop;
    private int mRight;
    private int mBottom;

    public interface OnClickListener {
        void onClick(View v);
    }

    public View(Context context) {
        mContext = context;
    }

    public View(Context context, AttributeSet attrs) {
        this(context);
    }

    public View(Context context, AttributeSet attrs, int defStyleAttr) {
        this(context);
    }

    public View(Context context, AttributeSet attrs, int defStyleAttr, int defStyleRes) {
        this(context);
    }

    private static String uiUnsupported(String className, String methodName) {
        return UI_PREFIX + className + "#" + methodName;
    }

    public final Context getContext() {
        return mContext;
    }

    public void setId(int id) {
        mId = id;
    }

    public int getId() {
        return mId;
    }

    public void setTag(Object tag) {
        mTag = tag;
    }

    public void setTag(int key, Object tag) {
        mTag = tag;
    }

    public Object getTag() {
        return mTag;
    }

    public Object getTag(int key) {
        return mTag;
    }

    public void setVisibility(int visibility) {
        mVisibility = visibility;
    }

    public int getVisibility() {
        return mVisibility;
    }

    public void setLayoutParams(ViewGroup.LayoutParams params) {
        mLayoutParams = params;
    }

    public ViewGroup.LayoutParams getLayoutParams() {
        return mLayoutParams;
    }

    public void setBackground(Drawable background) {
        mBackground = background;
    }

    public void setBackgroundDrawable(Drawable background) {
        mBackground = background;
    }

    public void setBackgroundColor(int color) {
    }

    public void setBackgroundResource(int resid) {
    }

    public Drawable getBackground() {
        return mBackground;
    }

    public void setOnClickListener(OnClickListener l) {
        mOnClickListener = l;
    }

    public boolean hasOnClickListeners() {
        return mOnClickListener != null;
    }

    public void setEnabled(boolean enabled) {
        mEnabled = enabled;
    }

    public boolean isEnabled() {
        return mEnabled;
    }

    public void setClickable(boolean clickable) {
        mClickable = clickable;
    }

    public boolean isClickable() {
        return mClickable;
    }

    public void setFocusable(boolean focusable) {
        mFocusable = focusable;
    }

    public void setFocusable(int focusable) {
        mFocusable = focusable != 0;
    }

    public final boolean isFocusable() {
        return mFocusable;
    }

    public void setContentDescription(CharSequence contentDescription) {
        mContentDescription = contentDescription;
    }

    public CharSequence getContentDescription() {
        return mContentDescription;
    }

    public void setPadding(int left, int top, int right, int bottom) {
        mPaddingLeft = left;
        mPaddingTop = top;
        mPaddingRight = right;
        mPaddingBottom = bottom;
    }

    public int getPaddingLeft() {
        return mPaddingLeft;
    }

    public int getPaddingTop() {
        return mPaddingTop;
    }

    public int getPaddingRight() {
        return mPaddingRight;
    }

    public int getPaddingBottom() {
        return mPaddingBottom;
    }

    public void setMinimumWidth(int minWidth) {
        mMinimumWidth = minWidth;
    }

    public int getMinimumWidth() {
        return mMinimumWidth;
    }

    public void setMinimumHeight(int minHeight) {
        mMinimumHeight = minHeight;
    }

    public int getMinimumHeight() {
        return mMinimumHeight;
    }

    public void setAlpha(float alpha) {
        mAlpha = alpha;
    }

    public float getAlpha() {
        return mAlpha;
    }

    public final int getLeft() {
        return mLeft;
    }

    public final int getTop() {
        return mTop;
    }

    public final int getRight() {
        return mRight;
    }

    public final int getBottom() {
        return mBottom;
    }

    public final int getWidth() {
        return mRight - mLeft;
    }

    public final int getHeight() {
        return mBottom - mTop;
    }

    public final int getMeasuredWidth() {
        return 0;
    }

    public final int getMeasuredHeight() {
        return 0;
    }

    public View getRootView() {
        return this;
    }

    public final <T extends View> T findViewById(int id) {
        return null;
    }

    public void requestLayout() {
    }

    public final void measure(int widthMeasureSpec, int heightMeasureSpec) {
        throw new UnsupportedOperationException(uiUnsupported("android.view.View", "measure"));
    }

    public void layout(int l, int t, int r, int b) {
        throw new UnsupportedOperationException(uiUnsupported("android.view.View", "layout"));
    }

    public void draw(Canvas canvas) {
        throw new UnsupportedOperationException(uiUnsupported("android.view.View", "draw"));
    }

    protected void onDraw(Canvas canvas) {
        throw new UnsupportedOperationException(uiUnsupported("android.view.View", "onDraw"));
    }

    public void invalidate() {
        throw new UnsupportedOperationException(uiUnsupported("android.view.View", "invalidate"));
    }

    public void invalidate(int l, int t, int r, int b) {
        throw new UnsupportedOperationException(uiUnsupported("android.view.View", "invalidate"));
    }

    public boolean performClick() {
        throw new UnsupportedOperationException(uiUnsupported("android.view.View", "performClick"));
    }

    public boolean onKeyDown(int keyCode, KeyEvent event) {
        return false;
    }

    public boolean onKeyLongPress(int keyCode, KeyEvent event) {
        return false;
    }

    public boolean onKeyMultiple(int keyCode, int repeatCount, KeyEvent event) {
        return false;
    }

    public boolean onKeyUp(int keyCode, KeyEvent event) {
        return false;
    }
}
