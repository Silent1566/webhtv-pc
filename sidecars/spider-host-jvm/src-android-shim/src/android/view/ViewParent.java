package android.view;

public interface ViewParent {

    void bringChildToFront(View child);

    boolean canResolveLayoutDirection();

    boolean canResolveTextAlignment();

    boolean canResolveTextDirection();

    void childDrawableStateChanged(View child);

    void childHasTransientStateChanged(View child, boolean hasTransientState);

    void clearChildFocus(View child);

    View focusSearch(View focused, int direction);

    void focusableViewAvailable(View v);

    int getLayoutDirection();

    ViewParent getParent();

    ViewParent getParentForAccessibility();

    int getTextAlignment();

    int getTextDirection();

    boolean isLayoutDirectionResolved();

    boolean isLayoutRequested();

    boolean isTextAlignmentResolved();

    boolean isTextDirectionResolved();

    View keyboardNavigationClusterSearch(View currentView, int direction);

    void notifySubtreeAccessibilityStateChanged(View child, View source, int changeType);

    default void onDescendantInvalidated(View child, View target) {
    }

    boolean onNestedFling(View target, float velocityX, float velocityY, boolean consumed);

    boolean onNestedPreFling(View target, float velocityX, float velocityY);

    void onNestedPreScroll(View target, int dx, int dy, int[] consumed);

    void onNestedScroll(View target, int dxConsumed, int dyConsumed, int dxUnconsumed, int dyUnconsumed);

    void onNestedScrollAccepted(View child, View target, int axes);

    boolean onStartNestedScroll(View child, View target, int nestedScrollAxes);

    void onStopNestedScroll(View target);

    void recomputeViewAttributes(View child);

    void requestChildFocus(View child, View focused);

    void requestDisallowInterceptTouchEvent(boolean disallowIntercept);

    void requestFitSystemWindows();

    void requestLayout();

    void requestTransparentRegion(View child);

    boolean showContextMenuForChild(View originalView);

    boolean showContextMenuForChild(View originalView, float x, float y);
}
