package android.graphics;

import java.awt.geom.Path2D;

public class Path {
    final Path2D.Float geometry = new Path2D.Float(Path2D.WIND_NON_ZERO);
    public Path() { }
    public void moveTo(float x,float y) { geometry.moveTo(x,y); }
    private void current() { if(geometry.getCurrentPoint()==null) geometry.moveTo(0,0); }
    public void lineTo(float x,float y) { current(); geometry.lineTo(x,y); }
    public void quadTo(float x1,float y1,float x2,float y2) { current(); geometry.quadTo(x1,y1,x2,y2); }
    public void cubicTo(float x1,float y1,float x2,float y2,float x3,float y3) { current(); geometry.curveTo(x1,y1,x2,y2,x3,y3); }
    public void close() { if(geometry.getCurrentPoint()!=null) geometry.closePath(); }
}
