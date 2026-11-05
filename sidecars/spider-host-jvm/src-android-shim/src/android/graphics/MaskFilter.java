package android.graphics;

// 为什么是空壳：只被 Paint.setMaskFilter/getMaskFilter 的签名引用，
// 模糊/浮雕效果不在 P1-2 支持范围，setter 侧已经直接抛异常。
public class MaskFilter {

    public MaskFilter() {
    }
}
