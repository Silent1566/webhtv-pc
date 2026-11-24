package android.graphics;

import java.awt.Font;

/** Fixed Java logical families; never probes installed font names. */
public class Typeface {
    public static final Typeface DEFAULT = new Typeface(Font.SANS_SERIF,Font.PLAIN);
    public static final Typeface DEFAULT_BOLD = new Typeface(Font.SANS_SERIF,Font.BOLD);
    public static final Typeface SANS_SERIF = DEFAULT;
    public static final Typeface SERIF = new Typeface(Font.SERIF,Font.PLAIN);
    public static final Typeface MONOSPACE = new Typeface(Font.MONOSPACED,Font.PLAIN);
    private final String family;
    private final int style;
    public Typeface() { this(Font.SANS_SERIF,Font.PLAIN); }
    private Typeface(String family,int style) { this.family=family; this.style=style & 3; }
    public static Typeface create(Typeface family,int style) { return new Typeface(family==null?Font.SANS_SERIF:family.family,style); }
    Font font(float size) { return new Font(family,style,1).deriveFont(Math.max(0.01f,size)); }
}
