package webhtv.spider;

import android.graphics.*;
import java.io.*;
import java.util.Arrays;
import javax.imageio.ImageIO;
import java.awt.image.BufferedImage;

public final class AndroidGraphicsContractTest {
    private static int checks;
    private static void check(boolean value, String message) {
        checks++;
        if (!value) throw new AssertionError(message);
    }
    private static BufferedImage png(Bitmap bitmap) throws Exception {
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        check(bitmap.compress(Bitmap.CompressFormat.PNG, 100, out), "PNG encoded");
        return ImageIO.read(new ByteArrayInputStream(out.toByteArray()));
    }
    private static void fails(Runnable action, Class<? extends Throwable> type, String member) {
        try { action.run(); throw new AssertionError("expected " + member); }
        catch (Throwable error) {
            check(type.isInstance(error) && error.getMessage().contains(member), "named failure " + member + ": " + error);
        }
    }
    private static byte[] oversizedPngHeader() throws Exception {
        ByteArrayOutputStream bytes=new ByteArrayOutputStream();DataOutputStream out=new DataOutputStream(bytes);
        out.writeLong(0x89504e470d0a1a0aL);out.writeInt(13);
        ByteArrayOutputStream chunk=new ByteArrayOutputStream();DataOutputStream data=new DataOutputStream(chunk);
        data.writeBytes("IHDR");data.writeInt(Integer.MAX_VALUE);data.writeInt(2);data.write(new byte[]{8,6,0,0,0});
        byte[] ihdr=chunk.toByteArray();out.write(ihdr);java.util.zip.CRC32 crc=new java.util.zip.CRC32();crc.update(ihdr);out.writeInt((int)crc.getValue());
        return bytes.toByteArray();
    }
    public static void main(String[] args) throws Exception {
        fails(()->Bitmap.createBitmap(4097,4097,Bitmap$Config.ARGB_8888),IllegalArgumentException.class,"Bitmap#createBitmap");
        fails(()->Bitmap.createBitmap(Integer.MAX_VALUE,Integer.MAX_VALUE,Bitmap$Config.ARGB_8888),IllegalArgumentException.class,"Bitmap#createBitmap");
        fails(()->Bitmap.createBitmap(0,128,Bitmap$Config.ARGB_8888),IllegalArgumentException.class,"Bitmap#createBitmap");
        fails(()->Bitmap.createBitmap(-1,128,Bitmap$Config.ARGB_8888),IllegalArgumentException.class,"Bitmap#createBitmap");
        fails(()->Bitmap.createBitmap(4,4,Bitmap$Config.RGBA_F16),UnsupportedOperationException.class,"Bitmap#createBitmap");
        byte[] oversizedHeader=oversizedPngHeader();
        fails(()->BitmapFactory.decodeByteArray(oversizedHeader,0,oversizedHeader.length),IllegalArgumentException.class,"Bitmap#createBitmap");
        check(BitmapFactory.decodeByteArray(new byte[]{1,2,3},0,3)==null,"invalid image fails honestly");
        fails(()->Bitmap.createBitmap(new int[0],0,4096,4096,4096,Bitmap$Config.ARGB_8888),ArrayIndexOutOfBoundsException.class,"Bitmap");
        fails(()->Bitmap.createBitmap(new int[0],0,0,4096,4096,Bitmap$Config.ARGB_8888),IllegalArgumentException.class,"Bitmap");
        Bitmap bitmap = Bitmap.createBitmap(128, 128, Bitmap$Config.ARGB_8888);
        Canvas canvas = new Canvas(bitmap);
        canvas.drawColor(0xffeeeeee);
        Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG);
        paint.setColor(0xffff0000);
        canvas.drawRoundRect(new RectF(5,5,123,123), 18,18, paint);
        check(bitmap.getPixel(64,64) == 0xffff0000 && bitmap.getPixel(0,0) == 0xffeeeeee, "rounded rect changes pixels");
        Path path = new Path(); path.moveTo(10,10); path.lineTo(50,10); path.quadTo(55,20,50,30); path.cubicTo(40,40,20,40,10,30); path.close();
        paint.setColor(0xff00ff00); canvas.drawPath(path,paint);
        check(bitmap.getPixel(25,20) == 0xff00ff00, "Path2D filled");
        paint.setColor(0xff0000ff); canvas.drawCircle(90,30,10,paint);
        check(bitmap.getPixel(90,30) == 0xff0000ff, "circle filled");
        check(Typeface.DEFAULT != null && Typeface.DEFAULT_BOLD != null, "logical typefaces non-null");
        paint.setTypeface(Typeface.DEFAULT); paint.setTextSize(24); paint.setColor(0xff000000);
        canvas.drawText("Raster",10,90,paint);
        int textPixels=0, minX=128,minY=128,maxX=-1,maxY=-1;
        for(int y=65;y<95;y++) for(int x=5;x<110;x++) if((bitmap.getPixel(x,y)&0xffffff)<0x404040) {
            textPixels++; minX=Math.min(minX,x);minY=Math.min(minY,y);maxX=Math.max(maxX,x);maxY=Math.max(maxY,y);
        }
        check(textPixels>20 && maxX>minX && maxY>minY, "text produces non-empty ink bounding box");
        BufferedImage decoded=png(bitmap);
        check(decoded.getWidth()==128 && decoded.getHeight()==128, "PNG dimensions");
        for(int y=0;y<128;y++) for(int x=0;x<128;x++) check(decoded.getRGB(x,y)==bitmap.getPixel(x,y), "drawn ARGB pixel lossless");
        int[] pixels={0x00112233,0x80445566,0xff778899,0x01234567,0xffabcdef,0xffffffff};
        Bitmap rows=Bitmap.createBitmap(3,2,Bitmap$Config.ARGB_8888);
        rows.setPixels(pixels,0,3,0,0,3,2); int[] actual=new int[6]; rows.getPixels(actual,0,3,0,0,3,2);
        check(Arrays.equals(pixels,actual), "ARGB rows including transparent RGB round-trip");
        decoded=png(rows);
        for(int y=0;y<2;y++) for(int x=0;x<3;x++) check(decoded.getRGB(x,y)==pixels[y*3+x], "PNG preserves exact ARGB");
        int[] padded=new int[10]; rows.getPixels(padded,6,-4,0,0,3,2);
        check(padded[6]==pixels[0] && padded[2]==pixels[3] && padded[0]==0, "negative stride and padding");
        fails(()->rows.setPixels(padded,0,-4,0,0,3,2),ArrayIndexOutOfBoundsException.class,"Bitmap");
        fails(()->rows.getPixels(actual,0,2,0,0,3,2),IllegalArgumentException.class,"Bitmap");
        fails(()->rows.setPixel(Integer.MAX_VALUE,0,0),IllegalArgumentException.class,"Bitmap");
        fails(()->Bitmap.createBitmap(rows,Integer.MAX_VALUE,0,2,2),IllegalArgumentException.class,"Bitmap");
        Bitmap reversed=Bitmap.createBitmap(padded,6,-4,3,2,Bitmap$Config.ARGB_8888);
        check(reversed.getPixel(0,1)==pixels[3], "array factory row semantics");
        check(!reversed.isMutable(), "color array factory immutable");
        Bitmap duplicate=Bitmap.createBitmap(rows); check(duplicate.getPixel(1,1)==pixels[4], "copy factory");
        Bitmap crop=Bitmap.createBitmap(rows,1,0,2,2); check(crop.getWidth()==2 && crop.getPixel(0,1)==pixels[4], "crop factory");
        Bitmap scaled=Bitmap.createScaledBitmap(rows,6,4,false); check(scaled.getPixel(4,2)==pixels[5], "nearest scaling");
        Bitmap copy=rows.copy(Bitmap$Config.ARGB_8888,true); copy.setPixel(0,0,0xff010203);
        check(rows.getPixel(0,0)==pixels[0] && copy.getPixel(0,0)==0xff010203, "copy independent");
        Bitmap opaque=Bitmap.createBitmap(4,4,Bitmap$Config.ARGB_8888,false);
        Bitmap[] opaqueCopies={Bitmap.createBitmap(opaque),Bitmap.createBitmap(opaque,1,1,2,2),Bitmap.createScaledBitmap(opaque,8,8,false),opaque.copy(Bitmap$Config.ARGB_8888,true)};
        for(Bitmap owned:opaqueCopies) {
            check(!owned.hasAlpha(),"copy/crop/scale preserves opaque source alpha metadata");
            owned.setPixel(0,0,0x00123456);check(Color.alpha(owned.getPixel(0,0))==255,"copied opaque semantics retained");
        }
        check(rows.getRowBytes()==12 && rows.getByteCount()==24, "ARGB byte accounting");
        for(Bitmap$Config config:new Bitmap$Config[]{Bitmap$Config.ALPHA_8,Bitmap$Config.RGB_565,Bitmap$Config.ARGB_4444}) {
            Bitmap b=Bitmap.createBitmap(2,2,config); b.setPixel(0,0,0x8099ccff);
            check(b.getRowBytes()==(config==Bitmap$Config.ALPHA_8?2:4), "config row bytes");
            check(png(b).getRGB(0,0)==b.getPixel(0,0), "quantized config PNG round-trip");
        }
        check(Color.parseColor("#12aBcD")==0xff12abcd, "#RRGGBB");
        check(Color.parseColor("#8012abcd")==0x8012abcd, "#AARRGGBB");
        fails(()->Color.parseColor("#abc"),IllegalArgumentException.class,"color");
        check(Color.parseColor("RED")==0xffff0000 && Color.parseColor("transparent")==0, "named colors");
        check(Color.rgb(1,2,3)==0xff010203 && Color.argb(128,1,2,3)==0x80010203, "color helpers");
        check(Color.alpha(0x80123456)==128 && Color.red(0x80123456)==0x12 && Color.green(0x80123456)==0x34 && Color.blue(0x80123456)==0x56, "channel extraction");
        fails(()->Color.parseColor("#badbadbad"),IllegalArgumentException.class,"color");
        Paint gradient=new Paint(); Shader shader=new LinearGradient(0,0,128,0,0xffff0000,0xff0000ff,Shader.TileMode.CLAMP);
        check(gradient.setShader(shader)==shader && gradient.getShader()==shader,"Shader binary return contract");
        canvas.drawRect(0,100,128,128,gradient);
        check(Color.red(bitmap.getPixel(4,110))>Color.red(bitmap.getPixel(120,110)) && Color.blue(bitmap.getPixel(4,110))<Color.blue(bitmap.getPixel(120,110)), "gradient varies along axis");
        paint.setShader(null); paint.setStyle(Paint$Style.STROKE); paint.setStrokeWidth(4);paint.setStrokeCap(Paint.Cap.ROUND);paint.setStrokeJoin(Paint.Join.ROUND);
        canvas.drawLine(10,50,30,50,paint);check(bitmap.getPixel(20,50)==0xff000000,"stroke line");
        canvas.drawOval(new RectF(65,45,85,65),paint);check(bitmap.getPixel(75,45)!=0xffff0000,"oval stroke");
        canvas.drawArc(new RectF(90,60,120,90),0,90,false,paint);check(bitmap.getPixel(119,76)!=0xffff0000,"clockwise arc");
        Bitmap negativeArc=Bitmap.createBitmap(32,32,Bitmap$Config.ARGB_8888),positiveArc=Bitmap.createBitmap(32,32,Bitmap$Config.ARGB_8888);
        Canvas nc=new Canvas(negativeArc),pc=new Canvas(positiveArc);RectF arcBox=new RectF(2,2,30,30);
        nc.drawArc(arcBox,-360,-90,false,paint);pc.drawArc(arcBox,0,270,false,paint);
        int[] neg=new int[1024],pos=new int[1024];negativeArc.getPixels(neg,0,32,0,0,32,32);positiveArc.getPixels(pos,0,32,0,0,32,32);
        check(!Arrays.equals(neg,pos) && negativeArc.getPixel(16,30)==0 && positiveArc.getPixel(16,30)!=0,"negative sweep retains Android native signed direction");
        negativeArc.eraseColor(0);nc.drawArc(arcBox,0,-360,false,paint);
        check(negativeArc.getPixel(30,16)!=0,"Android native absolute full sweep draws oval");
        Bitmap translucent=Bitmap.createBitmap(32,32,Bitmap$Config.ARGB_8888);Paint combined=new Paint();
        combined.setColor(0x80ff0000);combined.setStyle(Paint$Style.FILL_AND_STROKE);combined.setStrokeWidth(8);
        new Canvas(translucent).drawRect(8,8,24,24,combined);
        check(Color.alpha(translucent.getPixel(10,16))==128 && Color.alpha(translucent.getPixel(16,16))==128,"fill-and-stroke alpha applies once to union");
        translucent.eraseColor(0);combined.setTextSize(20);new Canvas(translucent).drawText("I",8,24,combined);
        int maxAlpha=0;for(int yy=0;yy<32;yy++) for(int xx=0;xx<32;xx++) maxAlpha=Math.max(maxAlpha,Color.alpha(translucent.getPixel(xx,yy)));
        check(maxAlpha==128,"text fill-and-stroke alpha applies once to union");
        translucent.eraseColor(0);combined.setAntiAlias(true);
        new Canvas(translucent).drawRoundRect(new RectF(8,8,24,24),4,4,combined);
        boolean partialCoverage=false;maxAlpha=0;
        for(int yy=0;yy<32;yy++) for(int xx=0;xx<32;xx++) {
            int a=Color.alpha(translucent.getPixel(xx,yy));maxAlpha=Math.max(maxAlpha,a);partialCoverage|=a>0 && a<128;
        }
        check(maxAlpha==128 && partialCoverage,"antialiased union alpha uses single coverage");
        Paint alpha=new Paint();alpha.setColor(0xff000000);alpha.setAlpha(128);canvas.drawRect(0,0,2,2,alpha);
        check(Color.red(bitmap.getPixel(0,0))>100 && Color.red(bitmap.getPixel(0,0))<130,"alpha composited once");
        check(alpha.getColor()==0x80000000,"Paint alpha updates color");
        ByteArrayOutputStream jpeg=new ByteArrayOutputStream();check(bitmap.compress(Bitmap.CompressFormat.JPEG,90,jpeg),"JPEG encoded");
        check(ImageIO.read(new ByteArrayInputStream(jpeg.toByteArray())).getWidth()==128,"JPEG decodable");
        int[] jpegColors={0xffff0000,0x80ff0000,0x00ff0000},jpegRed={255,128,0};
        for(int index=0;index<jpegColors.length;index++) {
            Bitmap sample=Bitmap.createBitmap(8,8,Bitmap$Config.ARGB_8888);sample.eraseColor(jpegColors[index]);
            ByteArrayOutputStream sampleBytes=new ByteArrayOutputStream();check(sample.compress(Bitmap.CompressFormat.JPEG,100,sampleBytes),"uniform JPEG alpha sample encoded");
            int encoded=ImageIO.read(new ByteArrayInputStream(sampleBytes.toByteArray())).getRGB(4,4);
            check(Color.alpha(encoded)==255 && Math.abs(Color.red(encoded)-jpegRed[index])<=2 && Color.green(encoded)<=2 && Color.blue(encoded)<=2,"JPEG matches scoped premultiplied-native black flattening");
        }
        Bitmap fromBytes=BitmapFactory.decodeByteArray(jpeg.toByteArray(),0,jpeg.size());check(fromBytes.getWidth()==128,"referenced BitmapFactory decode");
        fails(()->bitmap.compress(Bitmap.CompressFormat.WEBP,90,new ByteArrayOutputStream()),UnsupportedOperationException.class,"Bitmap#compress");
        fails(()->paint.setMaskFilter(new MaskFilter()),UnsupportedOperationException.class,"Paint#setMaskFilter");
        fails(()->new Canvas().drawColor(0),UnsupportedOperationException.class,"Canvas#drawColor");
        rows.recycle();rows.recycle();check(rows.isRecycled() && rows.getWidth()==3,"recycled retains metadata");
        fails(()->rows.getPixel(0,0),IllegalStateException.class,"Bitmap#getPixel");
        fails(()->rows.setPixels(pixels,0,3,0,0,3,2),IllegalStateException.class,"Bitmap#setPixels");
        System.out.println("PASS AndroidGraphicsContractTest assertions="+checks+" textBounds="+minX+","+minY+".."+maxX+","+maxY+" headless="+java.awt.GraphicsEnvironment.isHeadless());
    }
}
