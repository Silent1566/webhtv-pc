package android.graphics;

public class Shader {
    public enum TileMode { CLAMP, REPEAT, MIRROR }
    public Shader() { }
    java.awt.Paint awtPaint() {
        throw new UnsupportedOperationException("Unsupported offscreen android.graphics.Shader#awtPaint");
    }
}
