package android.text;

import java.util.Iterator;
import java.util.regex.Pattern;

/**
 * android.text.TextUtils 的 JVM 实现垫片。
 * 只覆盖不依赖 TextPaint / Spanned / Parcel / Context 的成员：
 * 宿主侧没有渲染与跨进程序列化，补齐那些签名只会拖入整片缺失类型。
 */
public class TextUtils {

    public static final int CAP_MODE_CHARACTERS = 4096;
    public static final int CAP_MODE_WORDS = 8192;
    public static final int CAP_MODE_SENTENCES = 16384;

    public static final int SAFE_STRING_FLAG_TRIM = 1;
    public static final int SAFE_STRING_FLAG_SINGLE_LINE = 2;
    public static final int SAFE_STRING_FLAG_FIRST_LINE = 4;

    TextUtils() {
    }

    public static boolean isEmpty(CharSequence str) {
        return str == null || str.length() == 0;
    }

    public static boolean equals(CharSequence a, CharSequence b) {
        if (a == b) {
            return true;
        }
        if (a != null && b != null && a.length() == b.length()) {
            if (a instanceof String && b instanceof String) {
                return a.equals(b);
            }
            for (int i = 0; i < a.length(); i++) {
                if (a.charAt(i) != b.charAt(i)) {
                    return false;
                }
            }
            return true;
        }
        return false;
    }

    public static String join(CharSequence delimiter, Iterable<?> tokens) {
        final StringBuilder sb = new StringBuilder();
        if (tokens != null) {
            final Iterator<?> it = tokens.iterator();
            boolean first = true;
            while (it.hasNext()) {
                if (!first) {
                    sb.append(delimiter);
                }
                sb.append(it.next());
                first = false;
            }
        }
        return sb.toString();
    }

    public static String join(CharSequence delimiter, Object[] tokens) {
        final StringBuilder sb = new StringBuilder();
        if (tokens != null) {
            for (int i = 0; i < tokens.length; i++) {
                if (i > 0) {
                    sb.append(delimiter);
                }
                sb.append(tokens[i]);
            }
        }
        return sb.toString();
    }

    public static String[] split(String text, String expression) {
        if (isEmpty(text)) {
            return new String[0];
        }
        return text.split(expression, -1);
    }

    public static String[] split(String text, Pattern pattern) {
        if (isEmpty(text)) {
            return new String[0];
        }
        return pattern.split(text, -1);
    }

    public static CharSequence concat(CharSequence... text) {
        final StringBuilder sb = new StringBuilder();
        for (CharSequence cs : text) {
            sb.append(cs);
        }
        return sb.toString();
    }

    public static int getTrimmedLength(CharSequence s) {
        int len = s.length();
        int start = 0;
        while (start < len && s.charAt(start) <= ' ') {
            start++;
        }
        int end = len;
        while (end > start && s.charAt(end - 1) <= ' ') {
            end--;
        }
        return end - start;
    }

    public static void getChars(CharSequence s, int start, int end, char[] dest, int destoff) {
        for (int i = start; i < end; i++) {
            dest[destoff++] = s.charAt(i);
        }
    }

    public static String substring(CharSequence source, int start, int end) {
        return source.subSequence(start, end).toString();
    }

    public static int indexOf(CharSequence s, char ch) {
        return indexOf(s, ch, 0);
    }

    public static int indexOf(CharSequence s, char ch, int start) {
        return indexOf(s, ch, start, s.length());
    }

    public static int indexOf(CharSequence s, char ch, int start, int end) {
        for (int i = start; i < end; i++) {
            if (s.charAt(i) == ch) {
                return i;
            }
        }
        return -1;
    }

    public static int indexOf(CharSequence s, CharSequence needle) {
        return indexOf(s, needle, 0, s.length());
    }

    public static int indexOf(CharSequence s, CharSequence needle, int start) {
        return indexOf(s, needle, start, s.length());
    }

    public static int indexOf(CharSequence s, CharSequence needle, int start, int end) {
        final int nlen = needle.length();
        if (nlen == 0) {
            return start;
        }
        for (int i = start; i <= end - nlen; i++) {
            if (regionMatches(s, i, needle, 0, nlen)) {
                return i;
            }
        }
        return -1;
    }

    public static int lastIndexOf(CharSequence s, char ch) {
        return lastIndexOf(s, ch, s.length() - 1);
    }

    public static int lastIndexOf(CharSequence s, char ch, int last) {
        return lastIndexOf(s, ch, 0, last);
    }

    public static int lastIndexOf(CharSequence s, char ch, int start, int last) {
        for (int i = Math.min(last, s.length() - 1); i >= start; i--) {
            if (s.charAt(i) == ch) {
                return i;
            }
        }
        return -1;
    }

    public static boolean regionMatches(CharSequence cs, int toffset, CharSequence other, int ooffset, int len) {
        for (int i = 0; i < len; i++) {
            if (cs.charAt(toffset + i) != other.charAt(ooffset + i)) {
                return false;
            }
        }
        return true;
    }

    public static boolean isDigitsOnly(CharSequence str) {
        for (int i = 0; i < str.length(); ) {
            final int cp = Character.codePointAt(str, i);
            if (!Character.isDigit(cp)) {
                return false;
            }
            i += Character.charCount(cp);
        }
        return true;
    }

    public static boolean isGraphic(char c) {
        return Character.isDefined(c) && !Character.isISOControl(c) && Character.isLetterOrDigit(c)
                || Character.getType(c) == Character.SPACE_SEPARATOR;
    }

    public static boolean isGraphic(CharSequence str) {
        for (int i = 0; i < str.length(); ) {
            final int cp = Character.codePointAt(str, i);
            if (!(Character.isDefined(cp) && !Character.isISOControl(cp) && Character.isLetterOrDigit(cp))
                    && Character.getType(cp) != Character.SPACE_SEPARATOR) {
                return false;
            }
            i += Character.charCount(cp);
        }
        return true;
    }

    public static CharSequence stringOrSpannedString(CharSequence source) {
        return source == null ? null : source.toString();
    }

    public static String htmlEncode(String s) {
        final StringBuilder sb = new StringBuilder();
        for (int i = 0; i < s.length(); i++) {
            final char c = s.charAt(i);
            switch (c) {
                case '<':
                    sb.append("&lt;");
                    break;
                case '>':
                    sb.append("&gt;");
                    break;
                case '&':
                    sb.append("&amp;");
                    break;
                case '\'':
                    sb.append("&#39;");
                    break;
                case '"':
                    sb.append("&quot;");
                    break;
                default:
                    sb.append(c);
            }
        }
        return sb.toString();
    }

    public static CharSequence replace(CharSequence template, String[] sources, CharSequence[] destinations) {
        String result = template.toString();
        for (int i = 0; i < sources.length; i++) {
            final CharSequence dest = i < destinations.length ? destinations[i] : "";
            result = result.replace(sources[i], dest == null ? "" : dest.toString());
        }
        return result;
    }

    public static CharSequence expandTemplate(CharSequence template, CharSequence... values) {
        final StringBuilder sb = new StringBuilder();
        for (int i = 0; i < template.length(); i++) {
            final char c = template.charAt(i);
            if (c == '^' && i + 1 < template.length()) {
                final char idx = template.charAt(++i);
                if (idx == '^') {
                    sb.append('^');
                } else if (idx >= '1' && idx <= '9' && (idx - '1') < values.length) {
                    sb.append(values[idx - '1']);
                } else {
                    throw new IllegalArgumentException("no value for ^" + idx);
                }
            } else {
                sb.append(c);
            }
        }
        return sb.toString();
    }

    public static CharSequence getReverse(CharSequence source, int start, int end) {
        return new StringBuilder(source.subSequence(start, end)).reverse().toString();
    }

    public static int getOffsetBefore(CharSequence text, int offset) {
        if (offset <= 0 || offset > text.length()) {
            return -1;
        }
        return offset - 1;
    }

    public static int getOffsetAfter(CharSequence text, int offset) {
        if (offset < 0 || offset >= text.length()) {
            return -1;
        }
        return offset + 1;
    }

    public static int getLayoutDirectionFromLocale(java.util.Locale locale) {
        return locale == null ? 0 : 0;
    }
}
