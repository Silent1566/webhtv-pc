package android.graphics;

// 为什么是空壳：现有垫片只把它当作 Paint.mTypeface 的静态类型来声明字段与参数，
// 一个成员都没被调用；补齐常量/工厂只会引入需要长期维护的假值。
// 真机上构造器是包私有的，这里放宽成 public，保证即便有人 new 也不会抛。
public class Typeface {

    public Typeface() {
    }
}
