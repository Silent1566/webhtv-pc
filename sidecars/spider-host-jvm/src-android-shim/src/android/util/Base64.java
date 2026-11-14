package android.util;

import java.io.ByteArrayOutputStream;
import java.nio.charset.StandardCharsets;

/**
 * android.util.Base64 的 JVM 实现垫片。
 * 行为对齐 Android（换行宽度 76、URL_SAFE 字符表、CRLF、NO_PADDING、decode 容忍缺 padding），
 * 因为 spider 代码普遍依赖这些细节，简化实现会悄悄改变输出。
 */
public class Base64 {

    public static final int DEFAULT = 0;
    public static final int NO_PADDING = 1;
    public static final int NO_WRAP = 2;
    public static final int CRLF = 4;
    public static final int URL_SAFE = 8;
    public static final int NO_CLOSE = 16;

    // Android 的换行宽度固定为 76，不可配置
    private static final int LINE_LENGTH = 76;

    private static final char[] ALPHABET_STD =
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".toCharArray();
    private static final char[] ALPHABET_URL =
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_".toCharArray();

    // 与 android.jar 一致：构造器不公开，工具类只暴露静态方法
    Base64() {
    }

    public static String encodeToString(byte[] input, int flags) {
        return encodeToString(input, 0, input == null ? 0 : input.length, flags);
    }

    public static String encodeToString(byte[] input, int offset, int len, int flags) {
        return new String(encode(input, offset, len, flags), StandardCharsets.US_ASCII);
    }

    public static byte[] encode(byte[] input, int flags) {
        return encode(input, 0, input == null ? 0 : input.length, flags);
    }

    public static byte[] encode(byte[] input, int offset, int len, int flags) {
        final boolean wrap = (flags & NO_WRAP) == 0;
        final boolean urlSafe = (flags & URL_SAFE) != 0;
        final boolean padded = (flags & NO_PADDING) == 0;
        final char[] alphabet = urlSafe ? ALPHABET_URL : ALPHABET_STD;
        final String separator = (flags & CRLF) != 0 ? "\r\n" : "\n";

        final StringBuilder out = new StringBuilder(len * 4 / 3 + 4);
        final int end = Math.min(offset + len, input.length);
        int column = 0;
        int i = offset;
        while (i + 3 <= end) {
            final int triple = ((input[i] & 0xff) << 16) | ((input[i + 1] & 0xff) << 8) | (input[i + 2] & 0xff);
            for (int shift = 18; shift >= 0; shift -= 6) {
                out.append(alphabet[(triple >>> shift) & 0x3f]);
                if (wrap && ++column == LINE_LENGTH) {
                    out.append(separator);
                    column = 0;
                }
            }
            i += 3;
        }

        final int remaining = end - i;
        if (remaining == 1) {
            final int triple = (input[i] & 0xff) << 16;
            out.append(alphabet[(triple >>> 18) & 0x3f]);
            out.append(alphabet[(triple >>> 12) & 0x3f]);
            if (padded) {
                out.append('=').append('=');
            }
        } else if (remaining == 2) {
            final int triple = ((input[i] & 0xff) << 16) | ((input[i + 1] & 0xff) << 8);
            out.append(alphabet[(triple >>> 18) & 0x3f]);
            out.append(alphabet[(triple >>> 12) & 0x3f]);
            out.append(alphabet[(triple >>> 6) & 0x3f]);
            if (padded) {
                out.append('=');
            }
        }

        // Android 在启用换行时总会在末尾补一个行分隔符
        if (wrap) {
            out.append(separator);
        }
        return out.toString().getBytes(StandardCharsets.US_ASCII);
    }

    public static byte[] decode(String str, int flags) {
        if (str == null) {
            return new byte[0];
        }
        return decode(str.getBytes(StandardCharsets.US_ASCII), 0, str.length(), flags);
    }

    public static byte[] decode(byte[] input, int flags) {
        return decode(input, 0, input == null ? 0 : input.length, flags);
    }

    public static byte[] decode(byte[] input, int offset, int len, int flags) {
        if (input == null) {
            return new byte[0];
        }
        final int end = Math.min(offset + len, input.length);
        final ByteArrayOutputStream out = new ByteArrayOutputStream(len * 3 / 4 + 3);
        int buffer = 0;
        int bits = 0;
        for (int i = offset; i < end; i++) {
            final int b = input[i] & 0xff;
            // 换行、空白一律忽略：Android 编码结果自带 76 列换行，未要求 NO_WRAP 时必然出现
            if (b == '\n' || b == '\r' || b == ' ' || b == '\t' || b == '\f') {
                continue;
            }
            if (b == '=') {
                // padding 之后没有有效数据
                break;
            }
            final int value = valueOf(b);
            if (value < 0) {
                throw new IllegalArgumentException("bad base-64 input");
            }
            buffer = (buffer << 6) | value;
            bits += 6;
            if (bits >= 8) {
                bits -= 8;
                out.write((buffer >>> bits) & 0xff);
            }
        }
        // 缺 padding 的输入在上面按已有位数自然截断，无需额外处理
        return out.toByteArray();
    }

    /** 同时接受标准字符表与 URL_SAFE 字符表，避免调用方混用标志时静默失败。 */
    private static int valueOf(int c) {
        if (c >= 'A' && c <= 'Z') {
            return c - 'A';
        }
        if (c >= 'a' && c <= 'z') {
            return c - 'a' + 26;
        }
        if (c >= '0' && c <= '9') {
            return c - '0' + 52;
        }
        if (c == '+' || c == '-') {
            return 62;
        }
        if (c == '/' || c == '_') {
            return 63;
        }
        return -1;
    }
}
