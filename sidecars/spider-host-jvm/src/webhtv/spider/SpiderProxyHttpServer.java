package webhtv.spider;

import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpServer;
import java.io.*;
import java.net.*;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.*;
import java.util.concurrent.*;
import java.util.function.LongSupplier;

/** Authenticated per-process HTTP data plane; IPC only creates and revokes sessions. */
public final class SpiderProxyHttpServer implements AutoCloseable {
    private static final long TTL_MS = 120_000;
    private static final Set<String> RESPONSE_HEADERS = Set.of("content-type", "content-length",
            "content-range", "accept-ranges", "content-encoding", "cache-control", "etag", "last-modified");
    private final Spider spider;
    private final HttpServer server;
    private final ExecutorService workers;
    private final ScheduledExecutorService expiry;
    private final Semaphore permits;
    private final LongSupplier clock;
    private final Object lock = new Object();
    private final Set<Transfer> transfers = ConcurrentHashMap.newKeySet();
    private final InheritableThreadLocal<Session> requestSession = new InheritableThreadLocal<>();
    private Session active;
    private boolean closed;
    private volatile boolean ready;

    private static synchronized void installLogFilter() {
        if (!(System.err instanceof SafeErrorStream)) System.setErr(new SafeErrorStream(System.err));
    }

    private static final class SafeErrorStream extends PrintStream {
        SafeErrorStream(PrintStream sink) { super(new SafeErrorOutput(sink), true, StandardCharsets.UTF_8); }
    }

    private static final class SafeErrorOutput extends OutputStream {
        final PrintStream sink;
        final ByteArrayOutputStream line=new ByteArrayOutputStream();
        boolean oversized;
        SafeErrorOutput(PrintStream sink){this.sink=sink;}
        public synchronized void write(int value) {
            if(value=='\n') {
                if(oversized)sink.println("[webhtv] oversized stderr line suppressed");
                else {
                    String safe=line.toString(StandardCharsets.UTF_8)
                            .replaceAll("/s/[A-Za-z0-9_-]+/proxy", "/s/[redacted]/proxy")
                            .replaceAll("(https?://[^\\s?\\\"<>]+)\\?[^\\s\\\"<>]*", "$1?[redacted]");
                    safe=safe.replaceAll("(/s/[^\\s?\\\"<>]+/proxy)\\?[^\\s\\\"<>]*", "$1?[redacted]")
                            .replaceAll("(?i)([\\\"']?(?:token|session[-_]?id|sessionToken)[\\\"']?\\s*[:=]\\s*)([\\\"']?)[^\\s,;}&\\\"']+\\2", "$1$2[redacted]$2");
                    sink.println(safe.stripTrailing());
                }
                line.reset();oversized=false;
            } else if(!oversized) {
                if(line.size()>=16_384){line.reset();oversized=true;}
                else line.write(value);
            }
        }
        public synchronized void write(byte[] bytes,int offset,int length){for(int i=offset;i<offset+length;i++)write(bytes[i]&255);}
        public synchronized void flush(){sink.flush();}
    }

    private static final class Session {
        final String id;
        final String token;
        volatile long deadline;
        volatile boolean revoked;
        Session(String id, String token, long deadline) { this.id=id;this.token=token;this.deadline=deadline; }
    }

    private static final class ResponseOutput extends FilterOutputStream {
        volatile boolean failed;
        ResponseOutput(OutputStream out){super(out);}
        public void write(byte[] bytes,int offset,int length)throws IOException{out.write(bytes,offset,length);}
        public void close()throws IOException{
            if(failed)throw new IOException("代理响应流未完成");
            failed=true;
            out.close();
            failed=false;
        }
    }

    private static final class Transfer implements AutoCloseable {
        final Session session;
        final HttpExchange exchange;
        final ResponseOutput output;
        volatile InputStream body;
        volatile boolean closed;
        Transfer(Session session, HttpExchange exchange) {
            this.session=session;this.exchange=exchange;
            output=new ResponseOutput(exchange.getResponseBody());
            exchange.getRequestBody();
            exchange.setStreams(null,output);
        }
        synchronized void setBody(InputStream value) throws IOException {
            if (closed) { value.close(); throw new IOException("代理会话已结束"); }
            body=value;
        }
        public void close() {
            InputStream acquired;
            synchronized(this){if(closed)return;closed=true;acquired=body;output.failed=true;}
            // Throwing from the installed response close aborts TCP without flushing chunked buffers.
            exchange.close();
            if(acquired!=null)try{acquired.close();}catch(IOException ignored){}
        }
    }

    public SpiderProxyHttpServer(Spider spider, int concurrency) throws IOException {
        this(spider, concurrency, System::nanoTime);
    }

    SpiderProxyHttpServer(Spider spider, int concurrency, LongSupplier clock) throws IOException {
        this.spider=spider;this.clock=clock;
        installLogFilter();
        int limit=Math.max(1,concurrency);
        permits=new Semaphore(limit);
        workers=Executors.newFixedThreadPool(limit, task->{Thread t=new Thread(task,"webhtv-proxy-http");t.setDaemon(true);return t;});
        // Dispatch/reject on the JDK HTTP dispatcher: only accepted transfers enter the bounded pool.
        server=HttpServer.create(new InetSocketAddress(InetAddress.getByName("127.0.0.1"),0),limit);
        server.setExecutor(Runnable::run);
        server.createContext("/", exchange->{
            if(!permits.tryAcquire()){simple(exchange,503,"代理并发已达上限");return;}
            try{workers.execute(()->{try{handle(exchange);}finally{permits.release();}});}
            catch(RejectedExecutionException stopped){permits.release();exchange.close();}
        });
        expiry=Executors.newSingleThreadScheduledExecutor(task->{Thread t=new Thread(task,"webhtv-proxy-expiry");t.setDaemon(true);return t;});
        expiry.scheduleWithFixedDelay(this::expire,1,1,TimeUnit.SECONDS);
        server.start();
    }

    public void markReady() {
        synchronized(lock){if(closed)throw new IllegalStateException("代理宿主已停止");ready=true;}
    }

    public int port() { return server.getAddress().getPort(); }
    public String baseUrl() { return "http://127.0.0.1:"+port(); }

    public String entryUrl() {
        Session session=requestSession.get();
        synchronized(lock) {
            if(session==null)session=active;
            if(!valid(session))throw new IllegalStateException("没有有效的代理播放会话");
            return baseUrl()+"/s/"+session.token+"/proxy";
        }
    }

    public Object playback(java.util.function.Supplier<Object> invocation) {
        Session session;
        synchronized(lock) {
            session=active;
            if(!valid(session))throw new IllegalStateException("没有有效的代理播放会话");
        }
        requestSession.set(session);
        try{return invocation.get();}finally{requestSession.remove();}
    }

    public Map<String,Object> descriptor() {
        return Map.of("version",1,"baseUrl",baseUrl(),"sessionControl",true);
    }

    public Map<String,Object> control(Map<String,Object> params) {
        String op=text(params.get("op"));
        String id=text(params.get("sessionId"));
        if(!id.matches("[A-Za-z0-9_.:-]{1,128}"))throw new IllegalArgumentException("代理会话标识非法");
        Session revoked=null;
        Map<String,Object> result;
        synchronized(lock) {
            if(closed||!ready)throw new IllegalStateException("代理宿主尚未就绪");
            if(op.equals("session.close")) {
                if(active!=null&&active.id.equals(id)){revoked=active;invalidate(active);}
                result=Map.of("sessionId",id,"closed",true);
            } else {
                Object ttl=params.get("ttlMs");
                if(!(ttl instanceof Number number)||number.longValue()!=TTL_MS||number.doubleValue()!=TTL_MS)
                    throw new IllegalArgumentException("代理会话 TTL 必须是 120000ms");
                if(op.equals("session.open")) {
                    String token=text(params.get("token"));
                    if(!token.matches("[A-Za-z0-9_-]{32,256}"))throw new IllegalArgumentException("代理会话令牌非法");
                    if(active!=null){revoked=active;invalidate(active);}
                    active=new Session(id,token,clock.getAsLong()+TimeUnit.MILLISECONDS.toNanos(TTL_MS));
                    result=Map.of("sessionId",id,"entryUrl",entryUrl(),"expiresInMs",TTL_MS);
                } else if(op.equals("session.renew")) {
                    if(active==null||!active.id.equals(id)||!valid(active))throw new IllegalStateException("代理会话已失效");
                    active.deadline=clock.getAsLong()+TimeUnit.MILLISECONDS.toNanos(TTL_MS);
                    result=Map.of("sessionId",id,"expiresInMs",TTL_MS);
                } else throw new IllegalArgumentException("代理控制操作非法");
            }
        }
        closeTransfers(revoked);
        return result;
    }

    private boolean valid(Session session) {
        return !closed&&session!=null&&!session.revoked&&clock.getAsLong()<session.deadline;
    }

    private void expire() {
        Session revoked=null;
        synchronized(lock){if(active!=null&&!valid(active)){revoked=active;invalidate(active);}}
        closeTransfers(revoked);
    }

    private void invalidate(Session session) {
        session.revoked=true;if(active==session)active=null;
    }

    private void closeTransfers(Session session) {
        if(session==null)return;
        for(Transfer transfer:transfers)if(transfer.session==session)transfer.close();
    }

    private void handle(HttpExchange exchange) {
        Transfer transfer=null;
        boolean committed=false;
        try {
            String method=exchange.getRequestMethod();
            if(!method.equals("GET")&&!method.equals("HEAD")){simple(exchange,405,"仅支持 GET/HEAD");return;}
            String expected="127.0.0.1:"+port();
            if(!exchange.getRemoteAddress().getAddress().isLoopbackAddress()
                    ||exchange.getRequestHeaders().containsKey("Origin")
                    ||exchange.getRequestHeaders().getOrDefault("Host",List.of()).size()!=1
                    ||!expected.equals(exchange.getRequestHeaders().getFirst("Host"))) {
                simple(exchange,403,"代理访问被拒绝");return;
            }
            Map<String,String> query=parseQuery(exchange.getRequestURI().getRawQuery());
            String path=exchange.getRequestURI().getRawPath();
            if(path.equals("/proxy")&&"ck".equals(query.get("do"))){simple(exchange,ready?200:503,ready?"ok":"代理宿主尚未就绪");return;}
            Session session;
            synchronized(lock) {
                session=active;
                if(valid(session)&&samePath(path,session.token)){
                    transfer=new Transfer(session,exchange);transfers.add(transfer);
                }
            }
            if(transfer==null){simple(exchange,403,"代理会话无效");return;}
            requestSession.set(session);
            for(String name:List.of("Range","User-Agent","Referer","Accept")) {
                List<String> values=exchange.getRequestHeaders().get(name);
                if(values!=null) {
                    if(values.size()!=1||!safe(values.get(0)))throw new IllegalArgumentException("请求头非法");
                    query.put(name,values.get(0));
                    if(name.equals("Range"))query.put("range",values.get(0));
                }
            }
            rejectSelfReference(query);
            Object[] raw=spider.proxy(Collections.unmodifiableMap(query),new CallContext("proxy-http",0));
            Response response=Response.parse(raw);
            transfer.setBody(response.body);
            if(!valid(session))throw new IOException("代理会话已结束");
            // Retain a failing close so HttpExchange.close also closes the TCP connection after early EOF.
            ResponseOutput responseOutput=transfer.output;
            response.headers.forEach((name,value)->exchange.getResponseHeaders().set(name,value));
            if(response.mime!=null)exchange.getResponseHeaders().set("Content-Type",response.mime);
            long length=response.length;
            if(method.equals("HEAD")) {
                if(length>=0)exchange.getResponseHeaders().set("Content-Length",Long.toString(length));
                exchange.sendResponseHeaders(response.status,-1);committed=true;return;
            }
            exchange.sendResponseHeaders(response.status,length==0?-1:length<0?0:length);committed=true;
            if(length==0)return;
            byte[] buffer=new byte[65_536];
            long remaining=length;
            try(OutputStream out=responseOutput) {
                while(remaining!=0) {
                    if(!valid(session))throw new IOException("代理会话已结束");
                    int n=response.body.read(buffer,0,remaining<0?buffer.length:(int)Math.min(buffer.length,remaining));
                    if(n<0) {if(remaining>0)throw new EOFException("代理数据流提前结束");break;}
                    if(n==0)continue;
                    out.write(buffer,0,n);
                    if(remaining>0)remaining-=n;
                }
            }
        } catch(IllegalArgumentException invalid) {
            if(!committed)simple(exchange,400,"代理请求非法");
        } catch(Throwable error) {
            if(!committed)simple(exchange,502,"站源代理失败");
        } finally {
            requestSession.remove();
            if(transfer!=null){transfers.remove(transfer);transfer.close();}else exchange.close();
        }
    }

    private boolean samePath(String path,String token) {
        return MessageDigest.isEqual(path.getBytes(StandardCharsets.US_ASCII),
                ("/s/"+token+"/proxy").getBytes(StandardCharsets.US_ASCII));
    }

    private void rejectSelfReference(Map<String,String> query) {
        for(String name:List.of("url","u","target")) {
            String value=query.get(name);if(value==null)continue;
            try {
                URI uri=URI.create(value);
                if(uri.getHost()!=null&&(uri.getHost().equals("127.0.0.1")||uri.getHost().equals("localhost"))
                        &&uri.getPort()==port())throw new IllegalArgumentException("代理请求不能回指自身");
            } catch(IllegalArgumentException invalid){throw invalid;}
        }
    }

    private static Map<String,String> parseQuery(String raw) {
        Map<String,String> result=new LinkedHashMap<>();
        if(raw==null||raw.isEmpty())return result;
        if(raw.length()>65536)throw new IllegalArgumentException("查询参数过长");
        for(String pair:raw.split("&",-1)) {
            int at=pair.indexOf('=');
            String key=URLDecoder.decode(at<0?pair:pair.substring(0,at),StandardCharsets.UTF_8);
            String value=URLDecoder.decode(at<0?"":pair.substring(at+1),StandardCharsets.UTF_8);
            if(!safe(key)||!safe(value))throw new IllegalArgumentException("查询参数非法");
            String previous=result.putIfAbsent(key,value);
            if(previous!=null&&!previous.equals(value))throw new IllegalArgumentException("查询参数有歧义");
        }
        return result;
    }

    private static boolean safe(String value) {
        return value!=null&&value.length()<=65536&&value.chars().noneMatch(c->c<32||c==127);
    }
    private static String text(Object value){return value instanceof String s?s:"";}

    private static final class Response {
        int status;String mime;InputStream body;Map<String,String> headers=new LinkedHashMap<>();long length=-1;
        static Response parse(Object[] raw) throws IOException {
            InputStream acquired=raw!=null&&raw.length>2&&raw[2] instanceof InputStream in?in:null;
            try {
                if(raw==null||(raw.length!=3&&raw.length!=4)||!(raw[0] instanceof Number number)
                        ||number.intValue()<200||number.intValue()>599||number.doubleValue()!=number.intValue()
                        ||!(raw[1] instanceof String type)||!safe(type)||type.isBlank())throw new IOException("站源代理返回形态非法");
                Response response=new Response();response.status=number.intValue();response.mime=type;
                if(acquired!=null)response.body=acquired;
                else if(raw[2] instanceof byte[] bytes && bytes.length<=65_536)response.body=new ByteArrayInputStream(bytes);
                else if(raw[2] instanceof String text && text.length()<=16_384)response.body=new ByteArrayInputStream(text.getBytes(StandardCharsets.UTF_8));
                else throw new IOException("站源代理未返回数据流");
                if(raw.length==4) {
                    if(!(raw[3] instanceof Map<?,?> map))throw new IOException("站源代理响应头非法");
                    Set<String> connectionFields=new HashSet<>();
                    for(Map.Entry<?,?> e:map.entrySet()) {
                        if(e.getKey() instanceof String key && key.equalsIgnoreCase("connection")) {
                            if(!(e.getValue() instanceof String value)||!safe(value))throw new IOException("站源代理 Connection 非法");
                            for(String field:value.split(",",-1)) {
                                String name=field.trim().toLowerCase(Locale.ROOT);
                                if(!name.matches("[!#$%&'*+.^_`|~a-z0-9-]+"))throw new IOException("站源代理 Connection 非法");
                                connectionFields.add(name);
                            }
                        }
                    }
                    if(connectionFields.contains("content-type"))response.mime=null;
                    for(Map.Entry<?,?> e:map.entrySet()) {
                        if(!(e.getKey() instanceof String key)||!(e.getValue() instanceof String value)||!safe(key)||!safe(value))throw new IOException("站源代理响应头非法");
                        String lower=key.toLowerCase(Locale.ROOT);
                        if(RESPONSE_HEADERS.contains(lower)&&!connectionFields.contains(lower)) {
                            if(response.headers.putIfAbsent(lower,value)!=null)throw new IOException("站源代理重复响应头");
                        }
                    }
                }
                if(response.headers.containsKey("content-type"))response.mime=response.headers.get("content-type");
                String length=response.headers.remove("content-length");
                if(length!=null){if(!length.matches("[0-9]{1,19}"))throw new IOException("站源代理长度非法");try{response.length=Long.parseLong(length);}catch(NumberFormatException e){throw new IOException("站源代理长度非法");}}
                return response;
            } catch(Throwable error) {
                if(acquired!=null)try{acquired.close();}catch(IOException ignored){}
                if(error instanceof IOException io)throw io;
                throw new IOException("站源代理响应非法");
            }
        }
    }

    private static void simple(HttpExchange exchange,int status,String text) {
        try {
            byte[] bytes=text.getBytes(StandardCharsets.UTF_8);
            exchange.getResponseHeaders().set("Content-Type","text/plain; charset=utf-8");
            if(exchange.getRequestMethod().equals("HEAD")){exchange.sendResponseHeaders(status,-1);}
            else {exchange.sendResponseHeaders(status,bytes.length);exchange.getResponseBody().write(bytes);}
        } catch(IOException ignored){}finally{exchange.close();}
    }

    public void close() {
        synchronized(lock){if(closed)return;closed=true;ready=false;if(active!=null)invalidate(active);}
        for(Transfer transfer:transfers)transfer.close();
        expiry.shutdownNow();server.stop(0);workers.shutdownNow();
        com.github.catvod.Proxy.unbind(this);
    }
}
