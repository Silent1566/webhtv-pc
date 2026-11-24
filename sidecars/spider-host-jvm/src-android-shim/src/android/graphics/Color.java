package android.graphics;

import java.util.Locale;

public final class Color {
    private Color() { }
    public static int argb(int a,int r,int g,int b) { return a<<24 | r<<16 | g<<8 | b; }
    public static int rgb(int r,int g,int b) { return argb(255,r,g,b); }
    public static int alpha(int c) { return c>>>24; }
    public static int red(int c) { return c>>>16 & 255; }
    public static int green(int c) { return c>>>8 & 255; }
    public static int blue(int c) { return c & 255; }
    public static int parseColor(String value) {
        if(value==null) throw new IllegalArgumentException("Unknown color: null");
        if(value.startsWith("#")) {
            String hex=value.substring(1);
            if(!hex.matches("[0-9a-fA-F]+")) throw new IllegalArgumentException("Unknown color");
            if(hex.length()!=6 && hex.length()!=8) throw new IllegalArgumentException("Unknown color");
            long c=Long.parseLong(hex,16); return (int)(hex.length()==6?c|0xff000000L:c);
        }
        switch(value.toLowerCase(Locale.ROOT)) {
            case "black": return 0xff000000; case "darkgray": case "darkgrey": return 0xff444444;
            case "gray": case "grey": return 0xff888888; case "lightgray": case "lightgrey": return 0xffcccccc;
            case "white": return 0xffffffff; case "red": return 0xffff0000; case "green": case "lime": return 0xff00ff00;
            case "blue": return 0xff0000ff; case "yellow": return 0xffffff00; case "cyan": case "aqua": return 0xff00ffff;
            case "magenta": case "fuchsia": return 0xffff00ff; case "transparent": return 0;
            case "maroon": return 0xff800000; case "navy": return 0xff000080; case "olive": return 0xff808000;
            case "purple": return 0xff800080; case "silver": return 0xffc0c0c0; case "teal": return 0xff008080;
            default: throw new IllegalArgumentException("Unknown color");
        }
    }
}
