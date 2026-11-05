package android.graphics;

// 为什么是空壳：只被 Paint.setPathEffect/getPathEffect 的签名引用，
// 虚线/路径特效不在 P1-2 支持范围，setter 侧已经直接抛异常。
public class PathEffect {

    public PathEffect() {
    }
}
