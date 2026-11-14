package android.view;

import android.content.Context;
import android.graphics.Canvas;
import android.util.AttributeSet;

public abstract class ViewGroup extends View implements ViewParent {

    private static final String UI_PREFIX = "Android UI 路径不在 P1-2 支持范围：";

    public static class LayoutParams {

        public static final int FILL_PARENT = -1;
        public static final int MATCH_PARENT = -1;
        public static final int WRAP_CONTENT = -2;

        public int height;
        public int width;

        public LayoutParams(Context c, AttributeSet attrs) {
        }

        public LayoutParams(int width, int height) {
            this.width = width;
            this.height = height;
        }

        public LayoutParams(LayoutParams source) {
            this.width = source.width;
            this.height = source.height;
        }

        public void resolveLayoutDirection(int layoutDirection) {
        }
    }

    public static class MarginLayoutParams extends LayoutParams {

        public int bottomMargin;
        public int leftMargin;
        public int rightMargin;
        public int topMargin;

        private int mMarginStart;
        private int mMarginEnd;
        private int mLayoutDirection;
        private boolean mMarginRelative;

        public MarginLayoutParams(Context c, AttributeSet attrs) {
            super(c, attrs);
        }

        public MarginLayoutParams(int width, int height) {
            super(width, height);
        }

        public MarginLayoutParams(LayoutParams source) {
            super(source);
        }

        public MarginLayoutParams(MarginLayoutParams source) {
            super(source);
            this.leftMargin = source.leftMargin;
            this.topMargin = source.topMargin;
            this.rightMargin = source.rightMargin;
            this.bottomMargin = source.bottomMargin;
            this.mMarginStart = source.mMarginStart;
            this.mMarginEnd = source.mMarginEnd;
            this.mMarginRelative = source.mMarginRelative;
            this.mLayoutDirection = source.mLayoutDirection;
        }

        public int getLayoutDirection() {
            return mLayoutDirection;
        }

        public int getMarginEnd() {
            return mMarginEnd;
        }

        public int getMarginStart() {
            return mMarginStart;
        }

        public boolean isMarginRelative() {
            return mMarginRelative;
        }

        public void resolveLayoutDirection(int layoutDirection) {
            this.mLayoutDirection = layoutDirection;
        }

        public void setLayoutDirection(int layoutDirection) {
            this.mLayoutDirection = layoutDirection;
        }

        public void setMarginEnd(int end) {
            this.mMarginEnd = end;
            this.mMarginRelative = true;
        }

        public void setMarginStart(int start) {
            this.mMarginStart = start;
            this.mMarginRelative = true;
        }

        public void setMargins(int left, int top, int right, int bottom) {
            this.leftMargin = left;
            this.topMargin = top;
            this.rightMargin = right;
            this.bottomMargin = bottom;
            this.mMarginRelative = false;
        }
    }

    private boolean mClipChildren = true;
    private boolean mClipToPadding = true;
    private int mDescendantFocusability;

    public ViewGroup(Context context) {
        super(context);
    }

    public ViewGroup(Context context, AttributeSet attrs) {
        super(context, attrs);
    }

    public ViewGroup(Context context, AttributeSet attrs, int defStyleAttr) {
        super(context, attrs, defStyleAttr);
    }

    public ViewGroup(Context context, AttributeSet attrs, int defStyleAttr, int defStyleRes) {
        super(context, attrs, defStyleAttr, defStyleRes);
    }

    private static String uiUnsupported(String className, String methodName) {
        return UI_PREFIX + className + "#" + methodName;
    }

    public void addView(View child) {
        throw new UnsupportedOperationException(uiUnsupported("android.view.ViewGroup", "addView"));
    }

    public void addView(View child, int index) {
        throw new UnsupportedOperationException(uiUnsupported("android.view.ViewGroup", "addView"));
    }

    public void addView(View child, LayoutParams params) {
        throw new UnsupportedOperationException(uiUnsupported("android.view.ViewGroup", "addView"));
    }

    public void addView(View child, int index, LayoutParams params) {
        throw new UnsupportedOperationException(uiUnsupported("android.view.ViewGroup", "addView"));
    }

    public void addView(View child, int width, int height) {
        throw new UnsupportedOperationException(uiUnsupported("android.view.ViewGroup", "addView"));
    }

    public void updateViewLayout(View view, LayoutParams params) {
        throw new UnsupportedOperationException(uiUnsupported("android.view.ViewGroup", "updateViewLayout"));
    }

    public void removeView(View view) {
        throw new UnsupportedOperationException(uiUnsupported("android.view.ViewGroup", "removeView"));
    }

    public void removeViewAt(int index) {
        throw new UnsupportedOperationException(uiUnsupported("android.view.ViewGroup", "removeViewAt"));
    }

    public void removeViews(int start, int count) {
        throw new UnsupportedOperationException(uiUnsupported("android.view.ViewGroup", "removeViews"));
    }

    public void removeAllViews() {
        throw new UnsupportedOperationException(uiUnsupported("android.view.ViewGroup", "removeAllViews"));
    }

    public int getChildCount() {
        return 0;
    }

    public View getChildAt(int index) {
        return null;
    }

    public int indexOfChild(View child) {
        return -1;
    }

    public void setClipChildren(boolean clipChildren) {
        mClipChildren = clipChildren;
    }

    public void setClipToPadding(boolean clipToPadding) {
        mClipToPadding = clipToPadding;
    }

    public void setDescendantFocusability(int focusability) {
        mDescendantFocusability = focusability;
    }

    public static int getChildMeasureSpec(int spec, int padding, int childDimension) {
        return 0;
    }

    protected ViewGroup.LayoutParams generateDefaultLayoutParams() {
        return new LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT);
    }

    public ViewGroup.LayoutParams generateLayoutParams(AttributeSet attrs) {
        return new LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT);
    }

    protected ViewGroup.LayoutParams generateLayoutParams(ViewGroup.LayoutParams p) {
        return p;
    }

    protected boolean checkLayoutParams(ViewGroup.LayoutParams p) {
        return p != null;
    }

    protected abstract void onLayout(boolean changed, int l, int t, int r, int b);

    protected void dispatchDraw(Canvas canvas) {
        throw new UnsupportedOperationException(uiUnsupported("android.view.ViewGroup", "dispatchDraw"));
    }

    public void bringChildToFront(View child) {
    }

    public boolean canResolveLayoutDirection() {
        return false;
    }

    public boolean canResolveTextAlignment() {
        return false;
    }

    public boolean canResolveTextDirection() {
        return false;
    }

    public void childDrawableStateChanged(View child) {
    }

    public void childHasTransientStateChanged(View child, boolean hasTransientState) {
    }

    public void clearChildFocus(View child) {
    }

    public View focusSearch(View focused, int direction) {
        return null;
    }

    public void focusableViewAvailable(View v) {
    }

    public int getLayoutDirection() {
        return 0;
    }

    public ViewParent getParent() {
        return null;
    }

    public ViewParent getParentForAccessibility() {
        return getParent();
    }

    public int getTextAlignment() {
        return 0;
    }

    public int getTextDirection() {
        return 0;
    }

    public boolean isLayoutDirectionResolved() {
        return false;
    }

    public boolean isLayoutRequested() {
        return false;
    }

    public boolean isTextAlignmentResolved() {
        return false;
    }

    public boolean isTextDirectionResolved() {
        return false;
    }

    public View keyboardNavigationClusterSearch(View currentView, int direction) {
        return null;
    }

    public void notifySubtreeAccessibilityStateChanged(View child, View source, int changeType) {
    }

    public boolean onNestedFling(View target, float velocityX, float velocityY, boolean consumed) {
        return false;
    }

    public boolean onNestedPreFling(View target, float velocityX, float velocityY) {
        return false;
    }

    public void onNestedPreScroll(View target, int dx, int dy, int[] consumed) {
    }

    public void onNestedScroll(View target, int dxConsumed, int dyConsumed, int dxUnconsumed, int dyUnconsumed) {
    }

    public void onNestedScrollAccepted(View child, View target, int axes) {
    }

    public boolean onStartNestedScroll(View child, View target, int nestedScrollAxes) {
        return false;
    }

    public void onStopNestedScroll(View target) {
    }

    public void recomputeViewAttributes(View child) {
    }

    public void requestChildFocus(View child, View focused) {
    }

    public void requestDisallowInterceptTouchEvent(boolean disallowIntercept) {
    }

    public void requestFitSystemWindows() {
    }

    public void requestTransparentRegion(View child) {
    }

    public boolean showContextMenuForChild(View originalView) {
        return false;
    }

    public boolean showContextMenuForChild(View originalView, float x, float y) {
        return false;
    }
}
