package android.graphics;

/**
 * android.graphics.Canvas 的最小占位。
 *
 * <p>裁剪依据是实际引用而不是 javap 全量：在 android/view/{View,ViewGroup,SurfaceView,
 * TextureView,Window}.java 里搜索 Canvas，只找到 5 处，全部是把 Canvas 当**签名类型**用
 * （View#draw、View#onDraw、ViewGroup#dispatchDraw、SurfaceView#draw、SurfaceView#dispatchDraw、
 * TextureView#draw、TextureView#onDraw 的参数），**没有一行调用 Canvas 的成员方法**。
 * 因此本类不需要任何绘制能力，只要能当类型、能 new 即可。
 *
 * <p>唯一保留的 drawColor 是一个真实存在的 javap 成员：留一个会抛异常的绘制入口，
 * 是为了让「误用了 UI 绘制路径」当场暴露，而不是拿到一个所有成员都静默无操作的空类型。
 */
public class Canvas {

    private static final String UI_PREFIX = "Android UI 路径不在 P1-2 支持范围：";

    public Canvas() {
        // 真机构造器要么绑 Bitmap 要么绑 Surface；占位只需可实例化，故不做任何事。
    }

    public void drawColor(int color) {
        throw new UnsupportedOperationException(UI_PREFIX + "android.graphics.Canvas#drawColor");
    }

    // ---- 未声明成员（按实际引用裁剪，全部省略）： ----
    // 其余 200+ 个成员（clipRect/drawBitmap/drawText/save/restore/translate/concat/drawRect/...）
    // 一处都没有被引用，而且参数类型 Paint、Path、Matrix、Rect、Region、Bitmap(本仓库只有 Config)、
    // Shader、DrawFilter 等在本仓库都不存在，声明它们会直接编译失败。
}
