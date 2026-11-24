package android.graphics;

import java.awt.AlphaComposite;
import java.awt.BasicStroke;
import java.awt.Graphics2D;
import java.awt.RenderingHints;
import java.awt.Shape;
import java.awt.geom.*;
import java.util.Objects;
import java.util.function.Consumer;

/** Draws directly into the bound bitmap, without any AWT window. */
public class Canvas {
    private final Bitmap bitmap;
    public Canvas() { bitmap=null; }
    public Canvas(Bitmap bitmap) { this.bitmap=Objects.requireNonNull(bitmap,"bitmap");bitmap.raster("Canvas",true); }
    private void draw(String member,Consumer<Graphics2D> operation) {
        if(bitmap==null) throw new UnsupportedOperationException("Unsupported offscreen android.graphics.Canvas#"+member+": no bitmap");
        Graphics2D g=bitmap.raster("Canvas#"+member,true).createGraphics();
        try { operation.accept(g); } finally { g.dispose(); }
        bitmap.drawn();
    }
    private void configure(Graphics2D g,Paint paint) {
        Objects.requireNonNull(paint,"paint");
        g.setRenderingHint(RenderingHints.KEY_ANTIALIASING,paint.isAntiAlias()?RenderingHints.VALUE_ANTIALIAS_ON:RenderingHints.VALUE_ANTIALIAS_OFF);
        g.setRenderingHint(RenderingHints.KEY_TEXT_ANTIALIASING,paint.isAntiAlias()?RenderingHints.VALUE_TEXT_ANTIALIAS_ON:RenderingHints.VALUE_TEXT_ANTIALIAS_OFF);
        g.setRenderingHint(RenderingHints.KEY_FRACTIONALMETRICS,RenderingHints.VALUE_FRACTIONALMETRICS_ON);
        if(paint.getShader()==null) {
            g.setPaint(new java.awt.Color(paint.getColor(),true));
            g.setComposite(AlphaComposite.SrcOver);
        } else {
            g.setPaint(paint.getShader().awtPaint());
            g.setComposite(AlphaComposite.getInstance(AlphaComposite.SRC_OVER,paint.getAlpha()/255f));
        }
        int cap=paint.getStrokeCap()==Paint.Cap.ROUND?BasicStroke.CAP_ROUND:paint.getStrokeCap()==Paint.Cap.SQUARE?BasicStroke.CAP_SQUARE:BasicStroke.CAP_BUTT;
        int join=paint.getStrokeJoin()==Paint.Join.ROUND?BasicStroke.JOIN_ROUND:paint.getStrokeJoin()==Paint.Join.BEVEL?BasicStroke.JOIN_BEVEL:BasicStroke.JOIN_MITER;
        g.setStroke(new BasicStroke(paint.getStrokeWidth()==0?1:paint.getStrokeWidth(),cap,join,Math.max(1,paint.getStrokeMiter())));
        g.setFont(paint.font());
    }
    private void shape(String member,Shape shape,Paint paint) {
        draw(member,g->{configure(g,paint);paintShape(g,shape,paint);});
    }
    private void paintShape(Graphics2D g,Shape shape,Paint paint) {
        if(paint.getStyle()==Paint$Style.FILL) g.fill(shape);
        else if(paint.getStyle()==Paint$Style.STROKE) g.draw(shape);
        else {
            Area union=new Area(shape);union.add(new Area(g.getStroke().createStrokedShape(shape)));g.fill(union);
        }
    }
    public void drawColor(int color) {
        draw("drawColor",g->{g.setComposite(AlphaComposite.SrcOver);g.setColor(new java.awt.Color(color,true));g.fillRect(0,0,bitmap.getWidth(),bitmap.getHeight());});
    }
    public void drawRect(float left,float top,float right,float bottom,Paint paint) { shape("drawRect",new Rectangle2D.Float(left,top,right-left,bottom-top),paint); }
    public void drawRoundRect(RectF rect,float rx,float ry,Paint paint) { shape("drawRoundRect",new RoundRectangle2D.Float(rect.left,rect.top,rect.width(),rect.height(),Math.max(0,rx)*2,Math.max(0,ry)*2),paint); }
    public void drawCircle(float cx,float cy,float radius,Paint paint) { shape("drawCircle",new Ellipse2D.Float(cx-radius,cy-radius,radius*2,radius*2),paint); }
    public void drawOval(RectF oval,Paint paint) { shape("drawOval",new Ellipse2D.Float(oval.left,oval.top,oval.width(),oval.height()),paint); }
    public void drawArc(RectF oval,float startAngle,float sweepAngle,boolean useCenter,Paint paint) {
        if(!Float.isFinite(startAngle) || !Float.isFinite(sweepAngle)) throw new IllegalArgumentException("Canvas#drawArc: finite angles required");
        if(Math.abs(sweepAngle)>=360) {drawOval(oval,paint);return;}
        int type=useCenter?Arc2D.PIE:paint.getStyle()==Paint$Style.STROKE?Arc2D.OPEN:Arc2D.CHORD;
        shape("drawArc",new Arc2D.Float(oval.left,oval.top,oval.width(),oval.height(),-startAngle,-sweepAngle,type),paint);
    }
    public void drawLine(float x0,float y0,float x1,float y1,Paint paint) {
        draw("drawLine",g->{configure(g,paint);g.draw(new Line2D.Float(x0,y0,x1,y1));});
    }
    public void drawPath(Path path,Paint paint) { shape("drawPath",Objects.requireNonNull(path,"path").geometry,paint); }
    public void drawText(String text,float x,float y,Paint paint) {
        Objects.requireNonNull(text,"text");
        draw("drawText",g->{
            configure(g,paint);
            float advance=(float)g.getFont().getStringBounds(text,g.getFontRenderContext()).getWidth();
            float left=paint.getTextAlign()==Paint.Align.CENTER?x-advance/2:paint.getTextAlign()==Paint.Align.RIGHT?x-advance:x;
            Shape glyphs=g.getFont().createGlyphVector(g.getFontRenderContext(),text).getOutline(left,y);
            paintShape(g,glyphs,paint);
        });
    }
}
