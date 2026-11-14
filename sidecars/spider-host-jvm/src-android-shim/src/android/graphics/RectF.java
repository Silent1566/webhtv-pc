package android.graphics;

// 为什么保留真实几何：站点代码用 RectF 做榜单卡片坐标计算与命中判定，
// 空壳会把算出来的坐标全变成 0，问题要等到上层渲染才暴露。
// 未声明的成员（Parcelable / Rect 相关）依赖本批次不提供也不允许创建的类型，
// 见本轮交付报告的「未完成项」。
public class RectF {

    public float left;
    public float top;
    public float right;
    public float bottom;

    public RectF() {
    }

    public RectF(float left, float top, float right, float bottom) {
        this.left = left;
        this.top = top;
        this.right = right;
        this.bottom = bottom;
    }

    // 拷贝构造容忍 null：Android 原实现在 null 时静默保留 0 值，站点有依赖这个宽松行为。
    public RectF(RectF r) {
        if (r != null) {
            set(r);
        }
    }

    public final float centerX() {
        return (left + right) * 0.5f;
    }

    public final float centerY() {
        return (top + bottom) * 0.5f;
    }

    public boolean contains(RectF r) {
        return left < r.left && top < r.top && right > r.right && bottom > r.bottom;
    }

    // 先判空再比较：空矩形在数学上包含不了任何点，顺序反了会给出 true。
    public boolean contains(float x, float y) {
        return left < right && top < bottom
                && x >= left && x < right && y >= top && y < bottom;
    }

    public boolean contains(float left, float top, float right, float bottom) {
        return this.left < this.right && this.top < this.bottom
                && this.left <= left && this.top <= top
                && this.right >= right && this.bottom >= bottom;
    }

    @Override
    public boolean equals(Object o) {
        if (this == o) {
            return true;
        }
        if (o == null || getClass() != o.getClass()) {
            return false;
        }
        RectF r = (RectF) o;
        return left == r.left && top == r.top && right == r.right && bottom == r.bottom;
    }

    @Override
    public int hashCode() {
        int result = Float.floatToIntBits(left);
        result = 31 * result + Float.floatToIntBits(top);
        result = 31 * result + Float.floatToIntBits(right);
        result = 31 * result + Float.floatToIntBits(bottom);
        return result;
    }

    public final float height() {
        return bottom - top;
    }

    // 负的 dx/dy 会把矩形放大，这与 Android 的 inset 语义一致，不做夹取。
    public void inset(float dx, float dy) {
        left += dx;
        top += dy;
        right -= dx;
        bottom -= dy;
    }

    // 相交失败时保持原值：站点用返回值判断「有没有重叠」，改值会让后续绘制错位。
    public boolean intersect(RectF r) {
        return intersect(r.left, r.top, r.right, r.bottom);
    }

    public boolean intersect(float left, float top, float right, float bottom) {
        if (this.left < right && left < this.right && this.top < bottom && top < this.bottom) {
            if (this.left < left) {
                this.left = left;
            }
            if (this.top < top) {
                this.top = top;
            }
            if (this.right > right) {
                this.right = right;
            }
            if (this.bottom > bottom) {
                this.bottom = bottom;
            }
            return true;
        }
        return false;
    }

    public static boolean intersects(RectF a, RectF b) {
        if (a == null || a.isEmpty() || b == null || b.isEmpty()) {
            return false;
        }
        return a.left < b.right && b.left < a.right && a.top < b.bottom && b.top < a.bottom;
    }

    public boolean intersects(float left, float top, float right, float bottom) {
        return this.left < right && left < this.right && this.top < bottom && top < this.bottom;
    }

    public final boolean isEmpty() {
        return left >= right || top >= bottom;
    }

    public void offset(float dx, float dy) {
        left += dx;
        top += dy;
        right += dx;
        bottom += dy;
    }

    // 只移动位置、不改尺寸：先用 width/height 记下尺寸，再整体平移。
    public void offsetTo(float newLeft, float newTop) {
        right += newLeft - left;
        bottom += newTop - top;
        left = newLeft;
        top = newTop;
    }

    public void set(float left, float top, float right, float bottom) {
        this.left = left;
        this.top = top;
        this.right = right;
        this.bottom = bottom;
    }

    public void set(RectF src) {
        if (src != null) {
            left = src.left;
            top = src.top;
            right = src.right;
            bottom = src.bottom;
        }
    }

    public void setEmpty() {
        left = top = right = bottom = 0.0f;
    }

    public boolean setIntersect(RectF a, RectF b) {
        if (a.left < b.right && b.left < a.right && a.top < b.bottom && b.top < a.bottom) {
            left = Math.max(a.left, b.left);
            top = Math.max(a.top, b.top);
            right = Math.min(a.right, b.right);
            bottom = Math.min(a.bottom, b.bottom);
            return true;
        }
        return false;
    }

    // 把坐标排成正序：站点可能先设 right/bottom，再依赖 sort 规范化。
    public void sort() {
        if (left > right) {
            float temp = left;
            left = right;
            right = temp;
        }
        if (top > bottom) {
            float temp = top;
            top = bottom;
            bottom = temp;
        }
    }

    public String toShortString() {
        return "[" + left + "," + top + "][" + right + "," + bottom + "]";
    }

    @Override
    public String toString() {
        return "RectF(" + left + ", " + top + ", " + right + ", " + bottom + ")";
    }

    public void union(RectF r) {
        union(r.left, r.top, r.right, r.bottom);
    }

    public void union(float x, float y) {
        if (x < left) {
            left = x;
        } else if (x > right) {
            right = x;
        }
        if (y < top) {
            top = y;
        } else if (y > bottom) {
            bottom = y;
        }
    }

    // 自身为空时直接取并集矩形，否则逐边扩张——否则空矩形会把并集锁死在 (0,0,0,0)。
    public void union(float left, float top, float right, float bottom) {
        if (left < right && top < bottom) {
            if (this.left < this.right && this.top < this.bottom) {
                if (this.left > left) {
                    this.left = left;
                }
                if (this.top > top) {
                    this.top = top;
                }
                if (this.right < right) {
                    this.right = right;
                }
                if (this.bottom < bottom) {
                    this.bottom = bottom;
                }
            } else {
                this.left = left;
                this.top = top;
                this.right = right;
                this.bottom = bottom;
            }
        }
    }

    public final float width() {
        return right - left;
    }
}
