package android.graphics;

public class Rect {
    public int left, top, right, bottom;
    public Rect() { }
    public int width() { return right-left; }
    public int height() { return bottom-top; }
}
