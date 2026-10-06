package webhtv.spider;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * 最小 JSON 编解码：不引入任何第三方依赖（§20.3「按需下载或内置 sidecar」）。
 *
 * <p>语义对齐 Python 侧 {@code json.dumps(..., ensure_ascii=False, separators=(",", ":"))}
 * 与 Dart 侧 {@code jsonEncode}：UTF-8、不转义非 ASCII、紧凑分隔符。
 */
public final class Json {
    private Json() {}

    public static Object parse(String text) {
        Parser parser = new Parser(text);
        Object value = parser.value();
        parser.ws();
        if (!parser.atEnd()) {
            throw new IllegalArgumentException("JSON 尾部有多余内容（位置 " + parser.pos + "）");
        }
        return value;
    }

    public static String write(Object value) {
        StringBuilder sb = new StringBuilder();
        writeValue(sb, value);
        return sb.toString();
    }

    // ---------------------------------------------------------------- 写

    private static void writeValue(StringBuilder sb, Object value) {
        if (value == null) {
            sb.append("null");
        } else if (value instanceof String text) {
            writeString(sb, text);
        } else if (value instanceof Boolean flag) {
            sb.append(flag.booleanValue());
        } else if (value instanceof Double || value instanceof Float) {
            double number = ((Number) value).doubleValue();
            if (Double.isNaN(number) || Double.isInfinite(number)) {
                // 非有限浮点不是合法 JSON：写 null 而不是污染协议帧。
                sb.append("null");
            } else if (number == Math.rint(number) && Math.abs(number) < 9.007199254740992E15) {
                sb.append((long) number);
            } else {
                sb.append(number);
            }
        } else if (value instanceof Number number) {
            sb.append(number.toString());
        } else if (value instanceof Map<?, ?> map) {
            sb.append('{');
            boolean first = true;
            for (Map.Entry<?, ?> entry : map.entrySet()) {
                if (!first) {
                    sb.append(',');
                }
                first = false;
                writeString(sb, String.valueOf(entry.getKey()));
                sb.append(':');
                writeValue(sb, entry.getValue());
            }
            sb.append('}');
        } else if (value instanceof Iterable<?> iterable) {
            sb.append('[');
            boolean first = true;
            for (Object item : iterable) {
                if (!first) {
                    sb.append(',');
                }
                first = false;
                writeValue(sb, item);
            }
            sb.append(']');
        } else if (value instanceof Object[] array) {
            sb.append('[');
            for (int i = 0; i < array.length; i++) {
                if (i > 0) {
                    sb.append(',');
                }
                writeValue(sb, array[i]);
            }
            sb.append(']');
        } else {
            writeString(sb, String.valueOf(value));
        }
    }

    private static void writeString(StringBuilder sb, String value) {
        sb.append('"');
        for (int i = 0; i < value.length(); i++) {
            char c = value.charAt(i);
            switch (c) {
                case '"' -> sb.append("\\\"");
                case '\\' -> sb.append("\\\\");
                case '\n' -> sb.append("\\n");
                case '\r' -> sb.append("\\r");
                case '\t' -> sb.append("\\t");
                case '\b' -> sb.append("\\b");
                case '\f' -> sb.append("\\f");
                default -> {
                    if (c < 0x20) {
                        sb.append(String.format("\\u%04x", (int) c));
                    } else {
                        sb.append(c);
                    }
                }
            }
        }
        sb.append('"');
    }

    // ---------------------------------------------------------------- 读

    private static final class Parser {
        private final String text;
        private int pos;

        Parser(String text) {
            this.text = text;
        }

        boolean atEnd() {
            return pos >= text.length();
        }

        void ws() {
            while (pos < text.length()) {
                char c = text.charAt(pos);
                if (c == ' ' || c == '\n' || c == '\r' || c == '\t') {
                    pos++;
                } else {
                    break;
                }
            }
        }

        Object value() {
            ws();
            if (atEnd()) {
                throw fail("期望一个 JSON 值，但输入已结束");
            }
            char c = text.charAt(pos);
            return switch (c) {
                case '{' -> object();
                case '[' -> array();
                case '"' -> string();
                case 't' -> literal("true", Boolean.TRUE);
                case 'f' -> literal("false", Boolean.FALSE);
                case 'n' -> literal("null", null);
                default -> number();
            };
        }

        private Map<String, Object> object() {
            expect('{');
            Map<String, Object> result = new LinkedHashMap<>();
            ws();
            if (peek() == '}') {
                pos++;
                return result;
            }
            while (true) {
                ws();
                String name = string();
                ws();
                expect(':');
                result.put(name, value());
                ws();
                char c = next();
                if (c == '}') {
                    return result;
                }
                if (c != ',') {
                    throw fail("对象成员之间应为 ','，实际 '" + c + "'");
                }
            }
        }

        private List<Object> array() {
            expect('[');
            List<Object> result = new ArrayList<>();
            ws();
            if (peek() == ']') {
                pos++;
                return result;
            }
            while (true) {
                result.add(value());
                ws();
                char c = next();
                if (c == ']') {
                    return result;
                }
                if (c != ',') {
                    throw fail("数组元素之间应为 ','，实际 '" + c + "'");
                }
            }
        }

        private String string() {
            expect('"');
            StringBuilder sb = new StringBuilder();
            while (true) {
                if (atEnd()) {
                    throw fail("字符串未闭合");
                }
                char c = text.charAt(pos++);
                if (c == '"') {
                    return sb.toString();
                }
                if (c != '\\') {
                    sb.append(c);
                    continue;
                }
                if (atEnd()) {
                    throw fail("转义序列未完成");
                }
                char esc = text.charAt(pos++);
                switch (esc) {
                    case '"' -> sb.append('"');
                    case '\\' -> sb.append('\\');
                    case '/' -> sb.append('/');
                    case 'b' -> sb.append('\b');
                    case 'f' -> sb.append('\f');
                    case 'n' -> sb.append('\n');
                    case 'r' -> sb.append('\r');
                    case 't' -> sb.append('\t');
                    case 'u' -> {
                        if (pos + 4 > text.length()) {
                            throw fail("\\u 转义不足 4 位");
                        }
                        String hex = text.substring(pos, pos + 4);
                        pos += 4;
                        try {
                            sb.append((char) Integer.parseInt(hex, 16));
                        } catch (NumberFormatException error) {
                            throw fail("\\u 转义非法：" + hex);
                        }
                    }
                    default -> throw fail("未知转义：\\" + esc);
                }
            }
        }

        private Object number() {
            int start = pos;
            if (peek() == '-') {
                pos++;
            }
            boolean floating = false;
            while (!atEnd()) {
                char c = text.charAt(pos);
                if (c >= '0' && c <= '9') {
                    pos++;
                } else if (c == '.' || c == 'e' || c == 'E' || c == '+' || c == '-') {
                    floating = floating || c == '.' || c == 'e' || c == 'E';
                    pos++;
                } else {
                    break;
                }
            }
            String raw = text.substring(start, pos);
            if (raw.isEmpty() || raw.equals("-")) {
                throw fail("不是合法 JSON 值");
            }
            try {
                if (!floating) {
                    return Long.parseLong(raw);
                }
                return Double.parseDouble(raw);
            } catch (NumberFormatException error) {
                throw fail("数字非法：" + raw);
            }
        }

        private Object literal(String expected, Object value) {
            if (!text.startsWith(expected, pos)) {
                throw fail("期望字面量 " + expected);
            }
            pos += expected.length();
            return value;
        }

        private char peek() {
            if (atEnd()) {
                throw fail("输入意外结束");
            }
            return text.charAt(pos);
        }

        private char next() {
            char c = peek();
            pos++;
            return c;
        }

        private void expect(char expected) {
            char c = next();
            if (c != expected) {
                throw fail("期望 '" + expected + "'，实际 '" + c + "'");
            }
        }

        private IllegalArgumentException fail(String message) {
            return new IllegalArgumentException(message + "（位置 " + pos + "）");
        }
    }
}
