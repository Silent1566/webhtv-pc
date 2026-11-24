package android.graphics;

import java.awt.Graphics2D;
import java.awt.RenderingHints;
import java.awt.image.BufferedImage;
import java.io.IOException;
import java.io.OutputStream;
import java.util.Objects;
import javax.imageio.ImageIO;
import javax.imageio.ImageWriteParam;
import javax.imageio.stream.MemoryCacheImageOutputStream;

/** Offscreen pixels only; no Android surface or window ownership. */
public class Bitmap {
    public static final int DENSITY_NONE = 0;
    public enum CompressFormat { JPEG, PNG, WEBP, WEBP_LOSSLESS, WEBP_LOSSY }
    private BufferedImage image;
    private int width, height;
    private Bitmap$Config config;
    private boolean recycled, mutable, hasAlpha = true, hasMipMap;
    private int density, generation;

    public Bitmap() { }
    private Bitmap(int w, int h, Bitmap$Config c) {
        validateDimensions(w,h);
        Objects.requireNonNull(c, "config");
        switch (c) {
            case ARGB_8888: case ARGB_4444: case RGB_565: case ALPHA_8: break;
            default: throw unsupported("createBitmap config=" + c);
        }
        width = w; height = h; config = c; mutable = true; hasAlpha = c != Bitmap$Config.RGB_565;
        image = new BufferedImage(w, h, BufferedImage.TYPE_INT_ARGB);
        if (!hasAlpha) eraseColor(0xff000000);
    }
    static void validateDimensions(int w,int h) {
        if(w<=0 || h<=0 || (long)w*h>16_777_216L)
            throw new IllegalArgumentException("Bitmap#createBitmap: positive dimensions and at most 16777216 pixels (64MiB ARGB) required");
    }
    private static UnsupportedOperationException unsupported(String member) {
        return new UnsupportedOperationException("Unsupported offscreen android.graphics.Bitmap#" + member);
    }
    private void live(String member) {
        if (recycled) throw new IllegalStateException("android.graphics.Bitmap#" + member + ": recycled bitmap");
        if (image == null) throw unsupported(member + ": bitmap has no pixels");
    }
    private void writable(String member) {
        live(member);
        if (!mutable) throw new IllegalStateException("android.graphics.Bitmap#" + member + ": immutable bitmap");
    }
    BufferedImage raster(String member, boolean write) {
        if (write) writable(member); else live(member);
        return image;
    }
    private int normalized(int color) {
        switch (config) {
            case ALPHA_8: return color & 0xff000000;
            case RGB_565:
                int r = (color >>> 19) & 31, g = (color >>> 10) & 63, b = (color >>> 3) & 31;
                return 0xff000000 | ((r << 3 | r >>> 2) << 16) | ((g << 2 | g >>> 4) << 8) | (b << 3 | b >>> 2);
            case ARGB_4444:
                int c = color & 0xf0f0f0f0;
                return c | (c >>> 4);
            default: return hasAlpha?color:color | 0xff000000;
        }
    }
    void drawn() {
        if (config != Bitmap$Config.ARGB_8888 || !hasAlpha) {
            for (int y=0; y<height; y++) for (int x=0; x<width; x++) image.setRGB(x,y,normalized(image.getRGB(x,y)));
        }
        generation++;
    }
    private void region(int x, int y, int w, int h) {
        if (x < 0 || y < 0 || w < 0 || h < 0 || (long)x+w > width || (long)y+h > height)
            throw new IllegalArgumentException("Bitmap pixel rectangle outside bounds");
    }
    private static void rows(int[] pixels, int offset, int stride, int w, int h) {
        Objects.requireNonNull(pixels,"pixels");
        if (Math.abs((long)stride) < w) throw new IllegalArgumentException("Bitmap stride smaller than width");
        if (w == 0 || h == 0) return;
        long last = offset + (long)(h-1)*stride;
        if (Math.min(offset,last) < 0 || Math.max(offset,last)+w > pixels.length) throw new ArrayIndexOutOfBoundsException("Bitmap pixel array rows");
    }
    public static Bitmap createBitmap(int w,int h,Bitmap$Config c) { return new Bitmap(w,h,c); }
    public static Bitmap createBitmap(int w,int h,Bitmap$Config c,boolean alpha) { Bitmap b = new Bitmap(w,h,c); b.setHasAlpha(alpha); return b; }
    public static Bitmap createBitmap(int[] colors,int w,int h,Bitmap$Config c) { return createBitmap(colors,0,w,w,h,c); }
    public static Bitmap createBitmap(int[] colors,int offset,int stride,int w,int h,Bitmap$Config c) {
        validateDimensions(w,h); rows(colors,offset,stride,w,h);
        Bitmap b=new Bitmap(w,h,c); b.setPixels(colors,offset,stride,0,0,w,h); b.mutable=false; return b;
    }
    private void inheritMetadata(Bitmap source) {
        hasAlpha=source.hasAlpha && config!=Bitmap$Config.RGB_565;
        hasMipMap=source.hasMipMap;density=source.density;
    }
    public static Bitmap createBitmap(Bitmap source) { source.live("createBitmap"); return createBitmap(source,0,0,source.width,source.height); }
    public static Bitmap createBitmap(Bitmap source,int x,int y,int w,int h) {
        source.live("createBitmap"); source.region(x,y,w,h);
        Bitmap b=new Bitmap(w,h,source.config); b.inheritMetadata(source);
        int[] colors=source.image.getRGB(x,y,w,h,null,0,w); b.setPixels(colors,0,w,0,0,w,h);
        b.density=source.density; return b;
    }
    public static Bitmap createScaledBitmap(Bitmap source,int w,int h,boolean filter) {
        source.live("createScaledBitmap"); Bitmap b=new Bitmap(w,h,source.config); b.inheritMetadata(source);
        Graphics2D g=b.image.createGraphics();
        try {
            g.setComposite(java.awt.AlphaComposite.Src);
            g.setRenderingHint(RenderingHints.KEY_INTERPOLATION, filter ? RenderingHints.VALUE_INTERPOLATION_BILINEAR : RenderingHints.VALUE_INTERPOLATION_NEAREST_NEIGHBOR);
            g.drawImage(source.image,0,0,w,h,null);
        } finally { g.dispose(); }
        b.drawn(); b.density=source.density; return b;
    }
    public Bitmap copy(Bitmap$Config c,boolean isMutable) {
        live("copy"); Bitmap b=new Bitmap(width,height,c); b.inheritMetadata(this);
        int[] pixels=image.getRGB(0,0,width,height,null,0,width); b.setPixels(pixels,0,width,0,0,width,height);
        b.mutable=isMutable; b.density=density; return b;
    }
    public void setPixels(int[] pixels,int offset,int stride,int x,int y,int w,int h) {
        writable("setPixels"); region(x,y,w,h); rows(pixels,offset,stride,w,h);
        for(int row=0;row<h;row++) for(int col=0;col<w;col++) image.setRGB(x+col,y+row,normalized(pixels[offset+row*stride+col]));
        generation++;
    }
    public void getPixels(int[] pixels,int offset,int stride,int x,int y,int w,int h) {
        live("getPixels"); region(x,y,w,h); rows(pixels,offset,stride,w,h);
        for(int row=0;row<h;row++) for(int col=0;col<w;col++) pixels[offset+row*stride+col]=image.getRGB(x+col,y+row);
    }
    public int getPixel(int x,int y) { live("getPixel"); region(x,y,1,1); return image.getRGB(x,y); }
    public void setPixel(int x,int y,int color) { writable("setPixel"); region(x,y,1,1); image.setRGB(x,y,normalized(color)); generation++; }
    public void eraseColor(int color) {
        writable("eraseColor"); int[] row=new int[width]; java.util.Arrays.fill(row,normalized(color));
        for(int y=0;y<height;y++) image.setRGB(0,y,width,1,row,0,width); generation++;
    }
    public void eraseColor(long color) { throw unsupported("eraseColor(long)"); }
    public boolean compress(CompressFormat format,int quality,OutputStream stream) {
        live("compress"); Objects.requireNonNull(format,"format"); Objects.requireNonNull(stream,"stream");
        if(quality<0 || quality>100) throw new IllegalArgumentException("Bitmap#compress quality outside 0..100");
        if(format!=CompressFormat.PNG && format!=CompressFormat.JPEG) throw unsupported("compress("+format+")");
        try {
            if(format==CompressFormat.PNG) return ImageIO.write(image,"png",stream);
            BufferedImage rgb=new BufferedImage(width,height,BufferedImage.TYPE_INT_RGB);
            Graphics2D g=rgb.createGraphics(); try { g.drawImage(image,0,0,null); } finally { g.dispose(); }
            var writers=ImageIO.getImageWritersByFormatName("jpeg"); if(!writers.hasNext()) return false;
            var writer=writers.next();
            try(MemoryCacheImageOutputStream out=new MemoryCacheImageOutputStream(stream)) {
                writer.setOutput(out); ImageWriteParam params=writer.getDefaultWriteParam();
                params.setCompressionMode(ImageWriteParam.MODE_EXPLICIT); params.setCompressionQuality(quality/100f);
                writer.write(null,new javax.imageio.IIOImage(rgb,null,null),params); out.flush(); return true;
            } finally { writer.dispose(); }
        } catch(IOException error) { return false; }
    }
    public void recycle() { if(image!=null) image.flush(); image=null; recycled=true; }
    public boolean isRecycled() { return recycled; }
    public int getWidth() { return width; }
    public int getHeight() { return height; }
    public Bitmap$Config getConfig() { return config; }
    public boolean isMutable() { return mutable && !recycled; }
    public boolean hasAlpha() { return hasAlpha; }
    public void setHasAlpha(boolean value) { live("setHasAlpha"); hasAlpha=value && config!=Bitmap$Config.RGB_565; if(!hasAlpha) drawn(); }
    public boolean hasMipMap() { return hasMipMap; }
    public void setHasMipMap(boolean value) { live("setHasMipMap"); hasMipMap=value; }
    public int getDensity() { return density; }
    public void setDensity(int value) { density=value; }
    public int getGenerationId() { return generation; }
    public int getRowBytes() { return width*(config==Bitmap$Config.ALPHA_8?1:config==Bitmap$Config.RGB_565 || config==Bitmap$Config.ARGB_4444?2:4); }
    public int getByteCount() { return Math.multiplyExact(getRowBytes(),height); }
    public int getAllocationByteCount() { return getByteCount(); }
    public void prepareToDraw() { live("prepareToDraw"); }
    public void setWidth(int w) { throw unsupported("setWidth"); }
    public void setHeight(int h) { throw unsupported("setHeight"); }
    public void setConfig(Bitmap$Config c) { throw unsupported("setConfig"); }
}
