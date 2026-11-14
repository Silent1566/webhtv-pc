package android.graphics.drawable;

import android.graphics.Canvas;

/**
 * android.graphics.drawable.Drawable 的最小占位（javap：public abstract class）。
 *
 * <p>裁剪依据是实际引用而不是 javap 全量：在 android/view/{View,ViewGroup,SurfaceView,
 * TextureView,Window}.java 里搜索 Drawable，9 处全部是**签名类型**用法
 * （View#setBackground/setBackgroundDrawable/getBackground、Window#setBackgroundDrawable、
 * setChildDrawable、setFeatureDrawable、setResizingCaptionDrawable 的参数/返回值/字段），
 * 没有一行调用 Drawable 的成员方法。所以这里只需要类型存在。
 *
 * <p>绘制类成员故意写成「抛异常」而不是 abstract：抽象方法会逼着将来的子类补一份静默无效的
 * draw 实现，把「画不出来」这件事藏进空实现里；直接抛能让越界调用在第一次发生时就报出
 * 明确原因（UI 路径不在支持范围）。
 */
public abstract class Drawable {

    private static final String UI_PREFIX = "Android UI 路径不在 P1-2 支持范围：";

    public void draw(Canvas canvas) {
        throw new UnsupportedOperationException(UI_PREFIX + "android.graphics.drawable.Drawable#draw");
    }

    public int getOpacity() {
        throw new UnsupportedOperationException(
                UI_PREFIX + "android.graphics.drawable.Drawable#getOpacity");
    }

    public void setAlpha(int alpha) {
        throw new UnsupportedOperationException(UI_PREFIX + "android.graphics.drawable.Drawable#setAlpha");
    }

    // ---- 未声明成员（按实际引用裁剪，全部省略）： ----
    // setColorFilter(android.graphics.ColorFilter) -> ColorFilter 本仓库不存在，声明即编译失败。
    // getIntrinsicWidth/getIntrinsicHeight/setBounds(Rect)/getBounds/setVisible/mutate/setTint...
    //   -> 无任何引用；setBounds 还需 android.graphics.Rect，同样不存在。
}
