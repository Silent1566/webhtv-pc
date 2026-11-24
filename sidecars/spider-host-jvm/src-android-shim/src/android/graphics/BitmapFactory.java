package android.graphics;

import java.io.ByteArrayInputStream;
import java.io.IOException;
import java.util.Objects;
import javax.imageio.ImageIO;
import javax.imageio.stream.MemoryCacheImageInputStream;

public final class BitmapFactory {
    private BitmapFactory() { }
    public static Bitmap decodeByteArray(byte[] data,int offset,int length) {
        Objects.requireNonNull(data,"data");
        if(offset<0 || length<0 || (long)offset+length>data.length) throw new ArrayIndexOutOfBoundsException("BitmapFactory#decodeByteArray");
        if(length>134_217_728) throw new IllegalArgumentException("BitmapFactory#decodeByteArray: encoded input exceeds 128MiB");
        try(var stream=new MemoryCacheImageInputStream(new ByteArrayInputStream(data,offset,length))) {
            var readers=ImageIO.getImageReaders(stream);
            if(!readers.hasNext()) return null;
            var reader=readers.next();
            try {
                reader.setInput(stream,true,true);
                int width=reader.getWidth(0),height=reader.getHeight(0);
                Bitmap.validateDimensions(width,height);
                var image=reader.read(0);
                return Bitmap.createBitmap(image.getRGB(0,0,width,height,null,0,width),width,height,Bitmap$Config.ARGB_8888);
            } finally { reader.dispose(); }
        } catch(IOException error) { return null; }
    }
}
