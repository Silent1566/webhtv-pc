package android.graphics;

import java.awt.MultipleGradientPaint;
import java.awt.geom.Point2D;
import java.util.Objects;

public class LinearGradient extends Shader {
    private final java.awt.Paint paint;
    public LinearGradient(float x0,float y0,float x1,float y1,int color0,int color1,TileMode mode) {
        Objects.requireNonNull(mode,"tileMode");
        if(x0==x1 && y0==y1) { paint=new java.awt.Color(color1,true); return; }
        MultipleGradientPaint.CycleMethod cycle=mode==TileMode.CLAMP?MultipleGradientPaint.CycleMethod.NO_CYCLE:
            mode==TileMode.REPEAT?MultipleGradientPaint.CycleMethod.REPEAT:MultipleGradientPaint.CycleMethod.REFLECT;
        paint=new java.awt.LinearGradientPaint(new Point2D.Float(x0,y0),new Point2D.Float(x1,y1),new float[]{0,1},
            new java.awt.Color[]{new java.awt.Color(color0,true),new java.awt.Color(color1,true)},cycle);
    }
    @Override java.awt.Paint awtPaint() { return paint; }
}
