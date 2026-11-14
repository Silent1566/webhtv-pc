package android.graphics;

// 为什么是空壳：Shader 只出现在 Paint.setShader/getShader 的签名里，
// 着色本身不在 P1-2 支持范围，真正的绘制方法一个都不声明，也就没有可抛的入口。
public class Shader {

    public Shader() {
    }
}
