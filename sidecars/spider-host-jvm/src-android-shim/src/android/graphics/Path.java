package android.graphics;

// 为什么是空壳：Path 仅在 Paint.getTextPath 的参数位出现，而那个方法本身就是直接抛
// UnsupportedOperationException 的桩，路径数据绝不会流到这里。
// 因此 moveTo/lineTo 等绘制成员一律不声明——声明了反而会诱导上层写出走不通的代码。
public class Path {

    public Path() {
    }
}
