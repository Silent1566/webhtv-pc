package webhtv.spider;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.CancellationException;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Semaphore;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;

/**
 * 把站源对象暴露为 {@code webhtv-ipc-v1} stdio 服务（§9.3.1、§9.5、§9.7）。
 *
 * <p>与 Python 侧 {@code SidecarServer} 逐条对齐：
 * <ul>
 *   <li>主循环同步读帧（单线程读，避免并发读同一流）；每个请求派发到工作线程；</li>
 *   <li>{@code initialize} 完成 ABI/capability 握手；{@code init} 只是站源内部方法名；</li>
 *   <li>{@code $/cancelRequest} / {@code $/cancel} 取消在途请求；</li>
 *   <li>{@code destroy}/{@code shutdown} 优雅退出；{@code heartbeat} 直接应答；</li>
 *   <li>未声明 capability → {@code SPIDER_UNSUPPORTED}；参数非法 → {@code SPIDER_BAD_REQUEST}；
 *       其余异常 → {@code SPIDER_PARSE_ERROR}；取消 → {@code SPIDER_CANCELLED}；</li>
 *   <li>并发受 {@code limits.concurrency} 限制，防止 sidecar 自身成为资源耗尽点（§9.8）。</li>
 * </ul>
 */
public final class SidecarServer {
    private final Spider spider;
    private final Map<String, Object> manifest;
    private final Set<String> capabilities;
    private final String siteKey;
    private final int maxWorkers;
    private final java.io.InputStream in;
    private final java.io.OutputStream out;
    private final Object writeLock = new Object();

    private final Map<String, CallContext> inflight = new LinkedHashMap<>();
    private final Object stateLock = new Object();
    private final AtomicBoolean stopping = new AtomicBoolean(false);
    private final ExecutorService pool;
    private final Semaphore concurrency;
    private final CountDownLatch finished = new CountDownLatch(1);

    /** 已提交但尚未结束的任务数；主循环在 stdin EOF 后用它等完在途请求。 */
    private final java.util.concurrent.atomic.AtomicInteger pendingTasks =
            new java.util.concurrent.atomic.AtomicInteger(0);

    public SidecarServer(
            Spider spider,
            Map<String, Object> manifest,
            java.io.InputStream in,
            java.io.OutputStream out) {
        this.spider = spider;
        this.manifest = manifest == null ? new LinkedHashMap<>() : manifest;
        this.in = in;
        this.out = out;

        // manifest 是分发契约：声明了 capabilities 时以 manifest 为准，
        // 站源自报能力不得超出 manifest（§9.7）。
        Object declared = this.manifest.get("capabilities");
        Set<String> values = new LinkedHashSet<>();
        if (declared instanceof Iterable<?> iterable) {
            for (Object item : iterable) {
                values.add(String.valueOf(item));
            }
        } else {
            values.addAll(spider.capabilities());
        }
        this.capabilities = values;

        Object key = this.manifest.get("key");
        this.siteKey = spider.siteKey != null && !spider.siteKey.isEmpty()
                ? spider.siteKey
                : (key != null ? String.valueOf(key) : "unknown");
        spider.siteKey = this.siteKey;

        int concurrencyLimit = 4;
        Object limits = this.manifest.get("limits");
        if (limits instanceof Map<?, ?> map && map.get("concurrency") instanceof Number number) {
            concurrencyLimit = Math.max(1, number.intValue());
        }
        this.maxWorkers = concurrencyLimit;
        this.concurrency = new Semaphore(concurrencyLimit);
        this.pool = Executors.newFixedThreadPool(
                concurrencyLimit,
                runnable -> {
                    Thread thread = new Thread(runnable, "webhtv-spider-worker");
                    thread.setDaemon(true);
                    return thread;
                });
    }

    public String siteKey() {
        return siteKey;
    }

    public Set<String> capabilities() {
        return capabilities;
    }

    /** 主循环：读帧 → 派发；返回进程退出码。 */
    public int serve() {
        try {
            while (!stopping.get()) {
                Object message;
                try {
                    message = Ipc.readFrame(in, Ipc.DEFAULT_MAX_FRAME_BYTES);
                } catch (Ipc.ProtocolException error) {
                    Ipc.log("协议错误，终止运行时：" + error.getMessage());
                    return 2;
                } catch (java.io.IOException error) {
                    Ipc.log("读取 stdin 失败：" + error.getMessage());
                    return 2;
                }
                if (message == null) {
                    break;
                }
                if (!(message instanceof Map<?, ?> raw)) {
                    Ipc.log("丢弃非法消息：不是对象");
                    continue;
                }
                @SuppressWarnings("unchecked")
                Map<String, Object> envelope = (Map<String, Object>) raw;
                String method = str(envelope.get("method"));
                if (Ipc.CANCEL_METHODS.contains(method)) {
                    onCancel(envelope);
                    continue;
                }
                if (str(envelope.get("id")).isEmpty()) {
                    Ipc.log("丢弃非法消息：缺少 id");
                    continue;
                }
                dispatch(envelope);
            }
        } finally {
            stopping.set(true);
            // stdin EOF 不等于「可以立刻退出」：可能还有已派发但未完成（或未及写回
            // 响应）的请求。先等在途请求结束（上限 2s，与池关闭预算一致），
            // 否则管道一次性喂帧的场景会丢掉响应（§9.3.1 每个请求必须有应答）。
            awaitPending(2_000);
            pool.shutdownNow();
            try {
                pool.awaitTermination(2, TimeUnit.SECONDS);
            } catch (InterruptedException error) {
                Thread.currentThread().interrupt();
            }
            callQuietly();
            finished.countDown();
        }
        return 0;
    }

    /** 等待服务结束（供测试或宿主显式关闭使用）。 */
    public boolean awaitTermination(long millis) throws InterruptedException {
        return finished.await(millis, TimeUnit.MILLISECONDS);
    }

    public void requestStop() {
        stopping.set(true);
    }

    // ---------------------------------------------------------------- 派发

    private void dispatch(Map<String, Object> envelope) {
        String requestId = str(envelope.get("id"));
        String method = str(envelope.get("method"));
        Map<String, Object> params = asMap(envelope.get("params"));
        long deadlineNanos = 0;
        Object deadlineMs = envelope.get("deadlineMs");
        if (deadlineMs instanceof Number number && number.longValue() > 0) {
            deadlineNanos = System.nanoTime() + number.longValue() * 1_000_000L;
        }
        CallContext context = new CallContext(requestId, deadlineNanos);
        synchronized (stateLock) {
            inflight.put(requestId, context);
        }
        // 在途计数在**提交前**递增：否则主循环可能在 `pool.execute` 之后、
        // 工作线程尚未启动时看到计数为 0，导致 stdin EOF 后立即返回、
        // 把已派发的请求连响应一起丢掉（实测：单帧 initialize 后 stdout 为空）。
        pendingTasks.incrementAndGet();
        pool.execute(() -> {
            try {
                concurrency.acquire();
            } catch (InterruptedException error) {
                Thread.currentThread().interrupt();
                return;
            }
            try {
                handle(method, params, context, requestId);
            } finally {
                concurrency.release();
                synchronized (stateLock) {
                    inflight.remove(requestId);
                }
                if (pendingTasks.decrementAndGet() == 0) {
                    synchronized (pendingTasks) {
                        pendingTasks.notifyAll();
                    }
                }
            }
        });
    }

    /** 等待在途请求结束（上限 [timeoutMillis]）；返回是否已全部结束。 */
    private boolean awaitPending(long timeoutMillis) {
        long deadline = System.currentTimeMillis() + Math.max(0, timeoutMillis);
        synchronized (pendingTasks) {
            while (pendingTasks.get() > 0) {
                long remaining = deadline - System.currentTimeMillis();
                if (remaining <= 0) {
                    return false;
                }
                try {
                    pendingTasks.wait(remaining);
                } catch (InterruptedException error) {
                    Thread.currentThread().interrupt();
                    return false;
                }
            }
        }
        return true;
    }

    private void handle(
            String method, Map<String, Object> params, CallContext context, String requestId) {
        try {
            Object result = invoke(method, params, context);
            if (result == NO_RESPONSE) {
                return;
            }
            respondSuccess(requestId, result);
        } catch (CancellationException error) {
            respondError(requestId, Ipc.ERROR_CANCELLED, "调用方已取消该请求", null);
        } catch (UnsupportedMethodException error) {
            Map<String, Object> details = new LinkedHashMap<>();
            details.put("capabilities", sortedCapabilities());
            respondError(requestId, Ipc.ERROR_UNSUPPORTED, error.getMessage(), details);
        } catch (IllegalArgumentException | IllegalStateException error) {
            respondError(requestId, Ipc.ERROR_BAD_REQUEST, error.getMessage(), null);
        } catch (UnsupportedOperationException error) {
            Map<String, Object> details = new LinkedHashMap<>();
            details.put("capabilities", sortedCapabilities());
            respondError(requestId, Ipc.ERROR_UNSUPPORTED, error.getMessage(), details);
        } catch (Throwable error) {
            Ipc.log("方法 " + method + " 失败：" + error + "\n" + stackTrace(error));
            respondError(
                    requestId,
                    Ipc.ERROR_PARSE_ERROR,
                    error.getClass().getSimpleName() + ": " + error.getMessage(),
                    null);
        }
    }

    private static final Object NO_RESPONSE = new Object();

    private Object invoke(String method, Map<String, Object> params, CallContext context) {
        return switch (method) {
            case "initialize" -> initialize(params);
            case "home" -> call("home", params, context);
            case "homeVod" -> call("homeVod", params, context);
            case "category" -> call("category", params, context);
            case "detail" -> call("detail", params, context);
            case "search" -> call("search", params, context);
            case "play" -> call("play", params, context);
            case "live" -> call("live", params, context);
            case "proxy" -> call("proxy", params, context);
            case "action" -> call("action", params, context);
            case "destroy", "shutdown" -> destroy();
            case "heartbeat" -> heartbeat();
            default -> throw new UnsupportedMethodException("未实现方法：" + method);
        };
    }

    private Map<String, Object> heartbeat() {
        Map<String, Object> result = new LinkedHashMap<>();
        result.put("ok", true);
        return result;
    }

    private Object destroy() {
        stopping.set(true);
        callQuietly();
        return heartbeat();
    }

    private Map<String, Object> initialize(Map<String, Object> params) {
        String declared = str(params.get("abi"));
        if (!declared.isEmpty() && !Ipc.ABI_NAME.equals(declared)) {
            throw new IllegalArgumentException(
                    "ABI 不兼容：宿主声明 " + declared + "，sidecar 为 " + Ipc.ABI_NAME);
        }
        String extend = str(params.get("extend"));
        if (extend.isEmpty()) {
            Object manifestExtend = manifest.get("extend");
            extend = manifestExtend == null ? "" : String.valueOf(manifestExtend);
        }
        spider.init(extend);

        Map<String, Object> result = new LinkedHashMap<>();
        result.put("abi", Ipc.ABI_NAME);
        result.put("abiMinor", Ipc.ABI_MINOR);
        result.put("key", siteKey);
        result.put("runtime", str(manifest.get("runtime"), "jvm"));
        result.put("capabilities", sortedCapabilities());
        result.put("permissions", manifest.get("permissions") != null
                ? manifest.get("permissions")
                : defaultPermissions());
        result.put("limits", manifest.get("limits") != null
                ? manifest.get("limits")
                : new LinkedHashMap<String, Object>());
        return result;
    }

    private Object call(String method, Map<String, Object> params, CallContext context) {
        if (Ipc.KNOWN_CAPABILITIES.contains(method) && !capabilities.contains(method)) {
            throw new UnsupportedMethodException("未声明 capability：" + method);
        }
        return switch (method) {
            case "home" -> spider.home(params, context);
            case "homeVod" -> spider.homeVod(params, context);
            case "category" -> spider.category(params, context);
            case "detail" -> spider.detail(params, context);
            case "search" -> spider.search(params, context);
            case "play" -> spider.play(params, context);
            default -> throw new UnsupportedMethodException("未声明 capability：" + method);
        };
    }

    private void callQuietly() {
        try {
            spider.close();
        } catch (Throwable error) {
            Ipc.log("close() 失败：" + error);
        }
    }

    // ---------------------------------------------------------------- 取消

    private void onCancel(Map<String, Object> envelope) {
        Map<String, Object> params = asMap(envelope.get("params"));
        String target = str(params.get("id"));
        if (target.isEmpty()) {
            Ipc.log("取消消息缺少 id，已忽略");
            return;
        }
        CallContext context;
        synchronized (stateLock) {
            context = inflight.get(target);
        }
        if (context == null) {
            Ipc.log("取消未知请求 id=" + target + "（可能已完成）");
            return;
        }
        context.markCancelled();
    }

    // ---------------------------------------------------------------- 输出

    private void respondSuccess(String requestId, Object result) {
        Map<String, Object> envelope = new LinkedHashMap<>();
        envelope.put("jsonrpc", "2.0");
        envelope.put("id", requestId);
        envelope.put("result", result);
        write(envelope);
    }

    private void respondError(
            String requestId, String code, String message, Map<String, Object> details) {
        Map<String, Object> envelope = new LinkedHashMap<>();
        envelope.put("jsonrpc", "2.0");
        envelope.put("id", requestId);
        envelope.put(
                "error",
                Ipc.errorObject(
                        code, message, null, null, null, siteKey, requestId, details, "diag-jvm"));
        write(envelope);
    }

    private void write(Map<String, Object> envelope) {
        try {
            synchronized (writeLock) {
                Ipc.writeFrame(out, envelope);
            }
        } catch (java.io.IOException error) {
            Ipc.log("写 stdout 失败：" + error.getMessage());
        }
    }

    // ---------------------------------------------------------------- 工具

    private List<String> sortedCapabilities() {
        List<String> values = new ArrayList<>(capabilities);
        values.sort(String::compareTo);
        return values;
    }

    private static Map<String, Object> defaultPermissions() {
        Map<String, Object> permissions = new LinkedHashMap<>();
        permissions.put("network", true);
        permissions.put("localProxy", false);
        permissions.put("ui", false);
        permissions.put("storage", "cache-only");
        permissions.put("process", false);
        permissions.put("clipboard", false);
        permissions.put("browser", false);
        return permissions;
    }

    private static String stackTrace(Throwable error) {
        java.io.StringWriter writer = new java.io.StringWriter();
        error.printStackTrace(new java.io.PrintWriter(writer));
        return writer.toString();
    }

    @SuppressWarnings("unchecked")
    private static Map<String, Object> asMap(Object value) {
        if (value instanceof Map<?, ?> map) {
            return (Map<String, Object>) map;
        }
        return new LinkedHashMap<>();
    }

    private static String str(Object value) {
        return value == null ? "" : String.valueOf(value);
    }

    private static String str(Object value, String fallback) {
        String text = str(value);
        return text.isEmpty() ? fallback : text;
    }

    /** sidecar 未声明该 capability（§9.7）。 */
    private static final class UnsupportedMethodException extends RuntimeException {
        private static final long serialVersionUID = 1L;

        UnsupportedMethodException(String message) {
            super(message);
        }
    }
}
