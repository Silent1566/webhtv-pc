package webhtv.spider;

import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * {@code webhtv-ipc-v1} 传输层（JVM 侧）。
 *
 * <p>这是同一份契约的**第四份**实现，必须与 Dart 侧
 * {@code apps/desktop-flutter/lib/core/ipc_protocol.dart}、Python 侧
 * {@code sidecars/spider-host-python/webhtv_ipc.py}、Node 侧
 * {@code sidecars/spider-host-js/host.js} 对帧格式、握手与错误信封给出**一致**行为
 * （设计文档 §9.3、§9.3.1、§9.5）。
 *
 * <p>硬约束：
 * <ul>
 *   <li>帧为 {@code Content-Length} 头 + 空行 + 指定字节数的 UTF-8 JSON；禁止依赖
 *       「一行一个 JSON」（§9.3.1）。</li>
 *   <li>stdout 只承载协议帧，运行日志只能写 stderr（§9.3.1）。</li>
 *   <li>{@code initialize} 交换 ABI major/minor、capabilities、权限与限制。</li>
 *   <li>取消使用 {@code $/cancelRequest}，同时接受历史名 {@code $/cancel}。</li>
 *   <li>统一错误对象至少含 {@code code/category/message/retryable/userVisible/}
 *       {@code siteKey/requestId/details/diagnosticId}（§9.3.1）。</li>
 * </ul>
 */
public final class Ipc {
    private Ipc() {}

    public static final String ABI_NAME = "webhtv-ipc-v1";
    public static final int ABI_MAJOR = 1;
    public static final int ABI_MINOR = 0;
    public static final int DEFAULT_MAX_FRAME_BYTES = 16 * 1024 * 1024;
    private static final int MAX_HEADER_BYTES = 8192;

    /** 必需方法集（§9.3）；用于 manifest 与文档一致性校验。 */
    public static final List<String> REQUIRED_METHODS =
            List.of("init", "home", "category", "detail", "search", "play", "destroy");

    /** 可选方法集（§9.3）。 */
    public static final List<String> OPTIONAL_METHODS =
            List.of("homeVod", "live", "proxy", "action");

    /** 参与 capability 声明的方法集（§9.7）；`init`/`destroy` 属于生命周期，不在此列。 */
    public static final List<String> KNOWN_CAPABILITIES = knownCapabilities();

    public static final List<String> CANCEL_METHODS =
            List.of("$/cancelRequest", "$/cancel");

    public static final String ERROR_INIT_FAILED = "SPIDER_INIT_FAILED";
    public static final String ERROR_UNSUPPORTED = "SPIDER_UNSUPPORTED";
    public static final String ERROR_BAD_REQUEST = "SPIDER_BAD_REQUEST";
    public static final String ERROR_HTTP_ERROR = "SPIDER_HTTP_ERROR";
    public static final String ERROR_PARSE_ERROR = "SPIDER_PARSE_ERROR";
    public static final String ERROR_TIMEOUT = "SPIDER_TIMEOUT";
    public static final String ERROR_CANCELLED = "SPIDER_CANCELLED";
    public static final String ERROR_CRASHED = "SPIDER_CRASHED";
    public static final String ERROR_RESOURCE_LIMIT = "SPIDER_RESOURCE_LIMIT";
    public static final String ERROR_PROTOCOL_VIOLATION = "SPIDER_PROTOCOL_VIOLATION";

    private static List<String> knownCapabilities() {
        List<String> values = new ArrayList<>();
        for (String method : REQUIRED_METHODS) {
            if (!"init".equals(method) && !"destroy".equals(method)) {
                values.add(method);
            }
        }
        values.addAll(OPTIONAL_METHODS);
        return List.copyOf(values);
    }

    /** 运行日志只能写 stderr（§9.3.1）；stdout 被协议独占。 */
    public static void log(String message) {
        System.err.println(message);
        System.err.flush();
    }

    // ------------------------------------------------------------------ 帧

    public static byte[] encodeFrame(Object payload) {
        byte[] body = Json.write(payload).getBytes(StandardCharsets.UTF_8);
        String header = "Content-Length: " + body.length + "\r\n"
                + "Content-Type: application/json; charset=utf-8\r\n\r\n";
        byte[] head = header.getBytes(StandardCharsets.US_ASCII);
        byte[] frame = new byte[head.length + body.length];
        System.arraycopy(head, 0, frame, 0, head.length);
        System.arraycopy(body, 0, frame, head.length, body.length);
        return frame;
    }

    /** 帧或信封非法。对应 Dart 的 {@code IpcFrameError} / Python 的 {@code ProtocolError}。 */
    public static final class ProtocolException extends RuntimeException {
        private static final long serialVersionUID = 1L;

        public ProtocolException(String message) {
            super(message);
        }
    }

    /** 从输入流读出一个长度前缀帧；流正常结束返回 null。 */
    public static Object readFrame(java.io.InputStream stream, int maxBytes)
            throws java.io.IOException {
        java.io.ByteArrayOutputStream header = new java.io.ByteArrayOutputStream();
        while (true) {
            int read = stream.read();
            if (read < 0) {
                if (header.size() == 0) {
                    return null;
                }
                throw new ProtocolException("流结束前帧头不完整");
            }
            header.write(read);
            byte[] bytes = header.toByteArray();
            if (endsWith(bytes, "\r\n\r\n".getBytes(StandardCharsets.US_ASCII))
                    || endsWith(bytes, "\n\n".getBytes(StandardCharsets.US_ASCII))) {
                break;
            }
            if (bytes.length > MAX_HEADER_BYTES) {
                throw new ProtocolException("帧头超过 8 KiB，判定为协议污染");
            }
        }

        String text = header.toString(StandardCharsets.UTF_8);
        Integer length = null;
        for (String raw : text.replace("\r\n", "\n").split("\n")) {
            String line = raw.trim();
            if (line.isEmpty()) {
                continue;
            }
            int colon = line.indexOf(':');
            if (colon < 0) {
                throw new ProtocolException("头字段缺少冒号：" + line);
            }
            String name = line.substring(0, colon).trim().toLowerCase();
            if ("content-length".equals(name)) {
                String value = line.substring(colon + 1).trim();
                try {
                    length = Integer.parseInt(value);
                } catch (NumberFormatException error) {
                    throw new ProtocolException("Content-Length 非法：" + value);
                }
            }
        }
        if (length == null) {
            throw new ProtocolException("缺少 Content-Length 头");
        }
        if (length > maxBytes) {
            throw new ProtocolException("声明 " + length + " 字节超过上限 " + maxBytes);
        }

        byte[] body = new byte[length];
        int offset = 0;
        while (offset < length) {
            int read = stream.read(body, offset, length - offset);
            if (read < 0) {
                throw new ProtocolException("流在 payload 结束前关闭");
            }
            offset += read;
        }
        try {
            return Json.parse(new String(body, StandardCharsets.UTF_8));
        } catch (IllegalArgumentException error) {
            throw new ProtocolException("payload 不是 UTF-8 JSON：" + error.getMessage());
        }
    }

    public static void writeFrame(java.io.OutputStream stream, Object payload)
            throws java.io.IOException {
        stream.write(encodeFrame(payload));
        stream.flush();
    }

    private static boolean endsWith(byte[] bytes, byte[] suffix) {
        if (bytes.length < suffix.length) {
            return false;
        }
        int base = bytes.length - suffix.length;
        for (int i = 0; i < suffix.length; i++) {
            if (bytes[base + i] != suffix[i]) {
                return false;
            }
        }
        return true;
    }

    // -------------------------------------------------------------- 错误信封

    public static Map<String, Object> errorObject(
            String code,
            String message,
            String category,
            Boolean retryable,
            Boolean userVisible,
            String siteKey,
            String requestId,
            Map<String, Object> details,
            String diagnosticId) {
        Map<String, Object> error = new LinkedHashMap<>();
        error.put("code", code);
        error.put("category", category != null ? category : defaultCategory(code));
        error.put("message", message);
        error.put("retryable", retryable != null ? retryable : defaultRetryable(code));
        error.put("userVisible", userVisible != null ? userVisible : defaultUserVisible(code));
        error.put("siteKey", siteKey);
        error.put("requestId", requestId);
        error.put("details", details != null ? details : new LinkedHashMap<String, Object>());
        error.put("diagnosticId", diagnosticId != null ? diagnosticId : "diag-jvm");
        return error;
    }

    public static String defaultCategory(String code) {
        if (ERROR_PROTOCOL_VIOLATION.equals(code) || ERROR_BAD_REQUEST.equals(code)) {
            return "protocol";
        }
        if (ERROR_CRASHED.equals(code)) {
            return "transport";
        }
        if (ERROR_RESOURCE_LIMIT.equals(code)) {
            return "resource";
        }
        if (ERROR_CANCELLED.equals(code)) {
            return "user";
        }
        return "site";
    }

    public static boolean defaultRetryable(String code) {
        return ERROR_TIMEOUT.equals(code)
                || ERROR_HTTP_ERROR.equals(code)
                || ERROR_CRASHED.equals(code)
                || ERROR_INIT_FAILED.equals(code);
    }

    public static boolean defaultUserVisible(String code) {
        return !ERROR_PROTOCOL_VIOLATION.equals(code);
    }
}
