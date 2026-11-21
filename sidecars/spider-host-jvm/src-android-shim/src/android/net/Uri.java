package android.net;

import java.io.ByteArrayOutputStream;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Set;

/**
 * android.net.Uri 的 JVM 实现垫片（分层 URI 的解析/编码子集）。
 *
 * <p>只覆盖「解析 + 取组成部分 + {@link Builder} 拼装 + 百分号编解码」四类成员：垫片侧没有
 * {@code Parcel}、没有 {@code ContentResolver}、没有 {@code File}，声明那些成员只会拉进整片
 * 缺失类型（见文件末尾登记）。
 *
 * <p><b>为什么 Builder 继承 Uri</b>：真机上 {@code Uri.Builder} 不是 {@code Uri}，但这个垫片
 * 必须让**旧字节码里按 {@code ()Landroid/net/Uri;} 链接的 buildUpon 调用**也能解析成功。
 * bridge 方法只能由「子类协变覆写」产生，而协变要求返回类型是父声明的返回类型的子类型——
 * 所以要同时满足两者，只有一条路：父类
 * （{@link LegacyUriBuilderApi}）声明 {@code Uri buildUpon()}，{@code Uri} 用
 * {@code Builder buildUpon()} 覆写，并让 {@code Builder extends Uri}。javac 于是生成合成
 * bridge {@code public android.net.Uri buildUpon()}，两个重载并存（{@code javap -p} 可见）。
 *
 * <p>代价是 {@code Builder} 多了一条真机不存在的 is-a 关系。为让这条关系不自相矛盾，
 * {@code Builder} 覆写了 {@link #text()}，因此对 {@code Builder} 调用 Uri 的读取方法时，
 * 返回的是**当前拼装状态**的组成部分，而不是构造时的快照。
 */
public class Uri extends LegacyUriBuilderApi {

    /** 原始（未解码）URI 文本；{@code Builder} 覆写 {@link #text()} 时不会用到它。 */
    private final String text;

    Uri(String text) {
        this.text = text == null ? "" : text;
    }

    /**
     * 与 AOSP 同语义：{@code null} 入参返回 {@code null}，其余一律原样保存（**不做**合法性
     * 校验，也不在 parse 期解码）。
     */
    public static Uri parse(String uriString) {
        return uriString == null ? null : new Uri(uriString);
    }

    @Override
    public String toString() {
        return text();
    }

    /**
     * AOSP 语义：非 {@link Uri} 入参一律 {@code false}，同类型按**字符串**比较。
     *
     * <p>必须成对覆写 {@link #hashCode()}——只覆写一个会让 Uri 作为 {@code HashMap}/
     * {@code HashSet} 键时行为错乱；而两个都不覆写就退化成 {@code Object} 的**引用相等**，
     * 站源里 {@code uriA.equals(uriB)} 会静默得到 false，属于「静默行为不同」，正是本垫片要
     * 消除的那类失败。
     *
     * <p>已知副作用：{@code Uri.Builder} 继承 {@code Uri}（见类注释的 bridge 说明），因此
     * 一个 Builder 会与「它所拼装出的 URI 字符串相等」的 Uri 判等。真机上 Builder 不是 Uri，
     * 这种比较根本编译不过，所以没有站源会依赖它；这里只作为继承结构的已知代价记录。
     */
    @Override
    public boolean equals(Object object) {
        if (object == this) {
            return true;
        }
        if (!(object instanceof Uri other)) {
            return false;
        }
        return toString().equals(other.toString());
    }

    @Override
    public int hashCode() {
        return toString().hashCode();
    }

    /** 当前 URI 文本；{@code Builder} 覆写成「按当前组成序列化」的结果。 */
    String text() {
        return text;
    }

    // ------------------------------------------------------------ 分层判定

    /** scheme 后的冒号下标，无法识别 scheme 时为 -1。 */
    private int schemeColon() {
        String s = text();
        int colon = s.indexOf(':');
        if (colon <= 0) {
            return -1;
        }
        return isScheme(s.substring(0, colon)) ? colon : -1;
    }

    private static boolean isScheme(String candidate) {
        char first = candidate.charAt(0);
        if (!(first >= 'a' && first <= 'z') && !(first >= 'A' && first <= 'Z')) {
            return false;
        }
        for (int i = 1; i < candidate.length(); i++) {
            char c = candidate.charAt(i);
            boolean allowed = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
                    || (c >= '0' && c <= '9') || c == '+' || c == '-' || c == '.';
            if (!allowed) {
                return false;
            }
        }
        return true;
    }

    /** 权限段起点（{@code "//"} 之后）；没有权限段时为 -1。 */
    private int authorityStart() {
        String s = text();
        int colon = schemeColon();
        int afterScheme = colon < 0 ? 0 : colon + 1;
        if (s.startsWith("//", afterScheme)) {
            return afterScheme + 2;
        }
        return -1;
    }

    /** 权限段终点（不含）；没有权限段时为 -1。 */
    private int authorityEnd() {
        int start = authorityStart();
        if (start < 0) {
            return -1;
        }
        String s = text();
        for (int i = start; i < s.length(); i++) {
            char c = s.charAt(i);
            if (c == '/' || c == '?' || c == '#') {
                return i;
            }
        }
        return s.length();
    }

    /** 路径段起点（已编码路径的起点）；不是分层 URI 时为 -1。 */
    private int pathStart() {
        int authEnd = authorityEnd();
        if (authEnd >= 0) {
            return authEnd;
        }
        int colon = schemeColon();
        if (colon < 0) {
            return 0;
        }
        return colon + 1;
    }

    /**
     * 真机的 {@code isOpaque()}：有 scheme、没有 {@code "//"} 权限段、且 scheme 之后不是以
     * {@code '/'} 开头的路径（如 {@code mailto:a@b}）。{@code getQueryParameter} 一类只在分层
     * URI 上有定义的成员据此抛 {@code UnsupportedOperationException}。
     */
    public boolean isOpaque() {
        if (schemeColon() < 0) {
            return false;
        }
        int afterScheme = schemeColon() + 1;
        String s = text();
        return !s.startsWith("//", afterScheme)
                && !(afterScheme < s.length() && s.charAt(afterScheme) == '/');
    }

    // ------------------------------------------------------------ 组成部分

    public String getScheme() {
        int colon = schemeColon();
        return colon < 0 ? null : text().substring(0, colon);
    }

    /**
     * 权限段原文（**未解码**）：真机 {@code StringUri#getAuthority()} 同样只是取原文，
     * userinfo 的百分号转义要调用方自己 {@link #decode} 一次。
     */
    public String getAuthority() {
        int start = authorityStart();
        int end = authorityEnd();
        return start < 0 ? null : text().substring(start, end);
    }

    public String getUserInfo() {
        String authority = getAuthority();
        if (authority == null) {
            return null;
        }
        int at = authority.lastIndexOf('@');
        return at < 0 ? null : authority.substring(0, at);
    }

    public String getHost() {
        String authority = getAuthority();
        if (authority == null) {
            return null;
        }
        int at = authority.lastIndexOf('@');
        String hostAndPort = at < 0 ? authority : authority.substring(at + 1);
        int colon = hostAndPort.lastIndexOf(':');
        String host = colon < 0 ? hostAndPort : hostAndPort.substring(0, colon);
        return host.isEmpty() ? null : host;
    }

    /** 端口；没有端口或端口不是十进制数字时返回 -1（真机同此约定）。 */
    public int getPort() {
        String authority = getAuthority();
        if (authority == null) {
            return -1;
        }
        int at = authority.lastIndexOf('@');
        String hostAndPort = at < 0 ? authority : authority.substring(at + 1);
        int colon = hostAndPort.lastIndexOf(':');
        if (colon < 0) {
            return -1;
        }
        String digits = hostAndPort.substring(colon + 1);
        if (digits.isEmpty() || digits.length() > 5) {
            return -1;
        }
        int port = 0;
        for (int i = 0; i < digits.length(); i++) {
            char c = digits.charAt(i);
            if (c < '0' || c > '9') {
                return -1;
            }
            port = port * 10 + (c - '0');
        }
        return port > 65535 ? -1 : port;
    }

    /** 已编码路径；非分层 URI 上为 {@code null}。 */
    public String getEncodedPath() {
        int start = pathStart();
        if (start < 0) {
            return null;
        }
        String s = text();
        int end = s.length();
        for (int i = start; i < s.length(); i++) {
            char c = s.charAt(i);
            if (c == '?' || c == '#') {
                end = i;
                break;
            }
        }
        return s.substring(start, end);
    }

    /** 解码后的路径；真机 {@code Uri#getPath()} 同样是解码结果。 */
    public String getPath() {
        String encoded = getEncodedPath();
        return encoded == null ? null : decode(encoded);
    }

    /** 已编码查询串（{@code '?' } 之后、{@code '#'} 之前）；没有查询串时为 {@code null}。 */
    public String getEncodedQuery() {
        String s = text();
        int question = s.indexOf('?', Math.max(pathStart(), 0));
        if (question < 0) {
            return null;
        }
        int hash = s.indexOf('#', question + 1);
        return hash < 0 ? s.substring(question + 1) : s.substring(question + 1, hash);
    }

    public String getQuery() {
        String encoded = getEncodedQuery();
        return encoded == null ? null : decode(encoded);
    }

    /** 最后一段路径（已解码）；空路径或只有 {@code "/"} 时返回 {@code null}。 */
    public String getLastPathSegment() {
        String path = getPath();
        if (path == null || path.isEmpty()) {
            return null;
        }
        int slash = path.lastIndexOf('/');
        String segment = slash < 0 ? path : path.substring(slash + 1);
        return segment;
    }

    /**
     * 指定查询参数的首个值（键与值都按 {@code application/x-www-form-urlencoded} 解码，
     * {@code '+'} 视作空格——真机 {@code getQueryParameter} 就是这么解码的）。
     */
    public String getQueryParameter(String key) {
        if (isOpaque()) {
            throw new UnsupportedOperationException("该 URI 不是分层 URI，没有查询参数");
        }
        if (key == null) {
            throw new NullPointerException("key");
        }
        String query = getEncodedQuery();
        if (query == null) {
            return null;
        }
        String encodedKey = encode(key);
        for (String[] pair : rawPairs(query)) {
            if (pair[0].equals(encodedKey)) {
                return pair[1] == null ? "" : decode(pair[1], true);
            }
        }
        return null;
    }

    /** 查询参数名集合（已解码、去重、保持出现顺序）；没有查询串时返回空集合。 */
    public Set<String> getQueryParameterNames() {
        if (isOpaque()) {
            throw new UnsupportedOperationException("该 URI 不是分层 URI，没有查询参数");
        }
        Set<String> names = new LinkedHashSet<>();
        String query = getEncodedQuery();
        if (query != null) {
            for (String[] pair : rawPairs(query)) {
                names.add(decode(pair[0], true));
            }
        }
        return names;
    }

    /** 以当前 URI 为底稿创建 {@link Builder}（bridge 目标方法）。 */
    @Override
    public Builder buildUpon() {
        return new Builder(this);
    }

    // ------------------------------------------------------------ 编解码

    /** 百分号转义（UTF-8）；字母、数字与 {@code "_-!.~'()*"} 保留原样。 */
    public static String encode(String text) {
        return encode(text, null);
    }

    /** @param allow 额外保留原样的字符集（真机 API 里的 allow 参数） */
    static String encode(String text, String allow) {
        if (text == null) {
            return null;
        }
        byte[] bytes = text.getBytes(StandardCharsets.UTF_8);
        StringBuilder builder = new StringBuilder(bytes.length + 16);
        for (byte value : bytes) {
            int c = value & 0xff;
            if (isUnreserved(c) || (allow != null && allow.indexOf(c) >= 0)) {
                builder.append((char) c);
            } else {
                builder.append('%')
                        .append(HEX[(c >> 4) & 0xf])
                        .append(HEX[c & 0xf]);
            }
        }
        return builder.toString();
    }

    /** 解码百分号转义；非法转义原样保留，{@code '+'} **不**转空格（真机 {@code decode} 同此）。 */
    public static String decode(String text) {
        return decode(text, false);
    }

    static String decode(String text, boolean convertPlus) {
        if (text == null) {
            return null;
        }
        ByteArrayOutputStream out = new ByteArrayOutputStream(text.length());
        String s = text;
        int i = 0;
        while (i < s.length()) {
            char c = s.charAt(i);
            if (c == '%' && i + 2 < s.length()) {
                int high = hexValue(s.charAt(i + 1));
                int low = hexValue(s.charAt(i + 2));
                if (high >= 0 && low >= 0) {
                    out.write((high << 4) | low);
                    i += 3;
                    continue;
                }
            }
            if (convertPlus && c == '+') {
                out.write(' ');
                i++;
                continue;
            }
            int codePoint = s.codePointAt(i);
            byte[] bytes = new String(Character.toChars(codePoint)).getBytes(StandardCharsets.UTF_8);
            out.write(bytes, 0, bytes.length);
            i += Character.charCount(codePoint);
        }
        return new String(out.toByteArray(), StandardCharsets.UTF_8);
    }

    private static final char[] HEX = "0123456789ABCDEF".toCharArray();

    private static boolean isUnreserved(int c) {
        return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')
                || "_-!.~'()*".indexOf(c) >= 0;
    }

    private static int hexValue(char c) {
        if (c >= '0' && c <= '9') {
            return c - '0';
        }
        if (c >= 'a' && c <= 'f') {
            return c - 'a' + 10;
        }
        if (c >= 'A' && c <= 'F') {
            return c - 'A' + 10;
        }
        return -1;
    }

    /** 把查询串切成 {@code [已编码键, 已编码值或 null]}；空串产生空列表。 */
    private static List<String[]> rawPairs(String query) {
        List<String[]> pairs = new ArrayList<>();
        if (query.isEmpty()) {
            return pairs;
        }
        int start = 0;
        while (true) {
            int end = query.indexOf('&', start);
            if (end < 0) {
                end = query.length();
            }
            String segment = query.substring(start, end);
            if (!segment.isEmpty()) {
                int equals = segment.indexOf('=');
                if (equals < 0) {
                    pairs.add(new String[] {segment, null});
                } else {
                    pairs.add(new String[] {
                            segment.substring(0, equals), segment.substring(equals + 1)
                    });
                }
            }
            if (end >= query.length()) {
                break;
            }
            start = end + 1;
        }
        return pairs;
    }

    // ------------------------------------------------------------ Builder

    /**
     * 拼装器。成分里的 {@code path}/{@code query}/{@code fragment} **按已编码文本保存**，
     * 与真机 {@code Builder} 一致：{@code path()} 不做再编码，{@code appendPath()}/
     * {@code appendQueryParameter()} 负责编码入参。
     *
     * <p>继承 {@code Uri} 只为产生 {@code ()Landroid/net/Uri; buildUpon} 的 bridge（见类注释），
     * 因此对 Builder 调用 Uri 的读取方法时看到的是**当前拼装状态**，而不是它「作为 Uri」的
     * 某个历史快照。
     */
    public static class Builder extends Uri {

        private String scheme;

        private String authority;

        private String path;

        private String query;

        private String fragment;

        Builder(Uri base) {
            super("");
            if (base == null) {
                return;
            }
            scheme = base.getScheme();
            authority = base.getAuthority();
            path = base.getEncodedPath();
            query = base.getEncodedQuery();
            fragment = base.encodedFragment();
        }

        @Override
        String text() {
            return serialize();
        }

        private String serialize() {
            StringBuilder builder = new StringBuilder();
            if (scheme != null) {
                builder.append(scheme).append(':');
            }
            if (authority != null) {
                builder.append("//").append(authority);
            }
            if (path != null) {
                builder.append(path);
            }
            if (query != null) {
                builder.append('?').append(query);
            }
            if (fragment != null) {
                builder.append('#').append(fragment);
            }
            return builder.toString();
        }

        public Builder scheme(String value) {
            scheme = value;
            return this;
        }

        /** 权限段**原样**保存（真机 {@code authority()} 也不在 setter 里编码）。 */
        public Builder authority(String value) {
            authority = value;
            return this;
        }

        /** 与 {@link #authority} 同义：两者在真机上的差别只体现在对外读取方法的解码上。 */
        public Builder encodedAuthority(String value) {
            authority = value;
            return this;
        }

        /** 路径原样保存（调用方需自行 {@link Uri#encode}）。 */
        public Builder path(String value) {
            path = value;
            return this;
        }

        public Builder encodedPath(String value) {
            path = value;
            return this;
        }

        /** 追加一段路径；空路径时补前导 {@code '/'}，否则用 {@code '/'} 连接。 */
        public Builder appendPath(String newSegment) {
            if (newSegment == null) {
                throw new NullPointerException("newSegment");
            }
            return appendEncodedPath(encode(newSegment));
        }

        public Builder appendEncodedPath(String newSegment) {
            if (newSegment == null) {
                throw new NullPointerException("newSegment");
            }
            if (path == null || path.isEmpty()) {
                path = "/" + newSegment;
            } else if (path.endsWith("/")) {
                path = path + newSegment;
            } else {
                path = path + "/" + newSegment;
            }
            return this;
        }

        /** 整个查询串原样保存（调用方需自行编码）。 */
        public Builder query(String value) {
            query = value;
            return this;
        }

        public Builder encodedQuery(String value) {
            query = value;
            return this;
        }

        /** 追加查询参数，键与值都做百分号转义。 */
        public Builder appendQueryParameter(String key, String value) {
            if (key == null) {
                throw new NullPointerException("key");
            }
            String encodedKey = encode(key);
            String encodedValue = encode(value);
            String pair = encodedValue == null ? encodedKey : encodedKey + "=" + encodedValue;
            if (query == null || query.isEmpty()) {
                query = pair;
            } else {
                query = query + "&" + pair;
            }
            return this;
        }

        public Builder clearQuery() {
            query = null;
            return this;
        }

        public Builder fragment(String value) {
            fragment = value;
            return this;
        }

        public Builder encodedFragment(String value) {
            fragment = value;
            return this;
        }

        public Uri build() {
            return new Uri(serialize());
        }

        /** 拷贝一份拼装器（真机 {@code Uri#buildUpon()} 的语义）。 */
        @Override
        public Builder buildUpon() {
            Builder copy = new Builder(null);
            copy.scheme = scheme;
            copy.authority = authority;
            copy.path = path;
            copy.query = query;
            copy.fragment = fragment;
            return copy;
        }
    }

    /** 已编码的 fragment 段；没有时为 {@code null}。 */
    public String encodedFragment() {
        String s = text();
        int hash = s.lastIndexOf('#');
        return hash < 0 ? null : s.substring(hash + 1);
    }

    // ---- 未声明成员（签名或语义依赖仓库中尚缺的类型/能力）： ----
    // android.os.Parcel 相关：writeToParcel / CREATOR / describeContents -> android.os.Parcel 需补
    // java.io.File 相关：fromFile(java.io.File) / getPathSegments 之后的 File 变换 -> 桌面无此入口
    // android.content.ContentResolver 相关：withAppendedPath / getQueryParameters(boolean) 的
    //     ContentResolver 重载 -> 需补
    // java.net.URL 相关：toURL() / toJavaUri() -> 桌面侧用 java.net.URI.create 即可，不引入 JDK 依赖
    // boolean isHierarchical() / isRelative() / isAbsolute() / normalizeScheme()
    // List<String> getPathSegments() / getEncodedPathSegments() / getFragment() / getEncodedFragment()
    //     -> 可由现有 getEncodedPath() 派生，暂不声明（宁可少声明）
}

/**
 * {@code Uri.buildUpon()} 的旧版声明面：新版字节码调用 {@code Uri.Builder buildUpon()}，
 * 而旧字节码按 {@code ()Landroid/net/Uri;} 链接同一方法名。JVM 里一个类不能只靠一个方法
 * 同时满足两种描述符，bridge 方法又只能由协变覆写产生，因此这里放一个声明返回 {@code Uri}
 * 的抽象父类，由 {@code Uri}（返回 {@code Uri.Builder}）协变覆写，javac 自动补上 bridge。
 *
 * <p>包内可见即可：它是实现细节，不是公开 Android API，站源不应引用它。
 */
abstract class LegacyUriBuilderApi {

    public abstract Uri buildUpon();
}
