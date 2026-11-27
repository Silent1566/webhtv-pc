package webhtv.spider;

import java.io.*;
import java.net.*;
import java.net.http.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.lang.reflect.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.*;
import javax.tools.ToolProvider;

@SuppressWarnings("unchecked")
public final class ProxyHttpContractTest {
    static final String TOKEN = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    static final HttpClient HTTP = HttpClient.newBuilder().connectTimeout(java.time.Duration.ofSeconds(3)).build();
    static final AtomicInteger closed = new AtomicInteger();
    static final AtomicInteger opened = new AtomicInteger();
    static int assertions;
    static volatile CountDownLatch playEntered;
    static volatile CountDownLatch playRelease;
    static void check(boolean value, String reason) {
        assertions++; if (!value) throw new AssertionError(reason);
    }
    static Map<String,Object> map(Object value) { return (Map<String,Object>) value; }
    static Object hostHook(String method, Class<?>[] types, Object... args) {
        try { return Class.forName("com.github.catvod.Proxy").getMethod(method, types).invoke(null,args); }
        catch (ClassNotFoundException e) { return method.equals("getPort") ? 0 : "missing"; }
        catch (ReflectiveOperationException e) { throw new IllegalStateException(e); }
    }
    public static class Fixture extends Spider {
        int initPort;
        public void init(String extend) { initPort = (Integer) hostHook("getPort", new Class<?>[0]); }
        public Map<String,Object> play(Map<String,Object> params, CallContext context) {
            if(params.containsKey("block")) {
                playEntered.countDown();
                try{playRelease.await(5,TimeUnit.SECONDS);}catch(InterruptedException error){throw new IllegalStateException(error);}
            }
            return Map.of("url",hostHook("getUrl",new Class<?>[]{boolean.class},false));
        }
        public Object[] proxy(Map<String,String> p, CallContext context) {
            if (p.containsKey("short")) return new Object[]{200,"video/mp2t",new Tracked(2),Map.of("Content-Length","10")};
            if (p.containsKey("oversized")) return new Object[]{200,"text/plain","x".repeat(65537)};
            if (p.containsKey("bad")) return new Object[]{200,"text/plain",new Tracked(10),Map.of("Content-Length","bad")};
            if (p.containsKey("malformed")) return new Object[]{200,"text/plain",new Object()};
            if (p.containsKey("duplicate")) throw new AssertionError("duplicates reached source");
            String range = p.get("range");
            if ("bytes=999-".equals(range)) return new Object[]{416,"video/mp2t",new Tracked(0),Map.of("Content-Range","bytes */16","Content-Length","0")};
            long count = p.containsKey("large") ? 70L*1024*1024 : p.containsKey("endless") ? Long.MAX_VALUE : 16;
            int status=200; Map<String,String> headers=new HashMap<>();
            if (range != null) {
                check(range.equals(p.get("Range")),"Range canonical aliases");
                status=206;count=4;headers.put("Content-Range","bytes 0-3/16");headers.put("Accept-Ranges","bytes");
            }
            if (!p.containsKey("endless")) headers.put("Content-Length",Long.toString(count));
            headers.put("Content-Type","video/mp2t");headers.put("Set-Cookie","do-not-leak");
            headers.put("Connection",p.containsKey("hop")?"eTaG, LAST-modified":"keep-alive");headers.put("ETag","fixture");
            headers.put("Last-Modified","Wed, 21 Oct 2015 07:28:00 GMT");headers.put("Cache-Control","no-cache");
            return new Object[]{status,"application/octet-stream",new Tracked(count),headers};
        }
    }
    static final class Tracked extends InputStream {
        long remaining; volatile boolean done;
        Tracked(long count) { remaining=count;opened.incrementAndGet(); }
        public int read() throws IOException { byte[] b=new byte[1];return read(b,0,1)<0?-1:b[0]&255; }
        public int read(byte[] b,int o,int n) throws IOException {
            if(done)throw new IOException("closed");if(remaining==0)return -1;
            n=(int)Math.min(n,remaining);Arrays.fill(b,o,o+n,(byte)0x47);remaining-=n;return n;
        }
        public void close() { if(!done){done=true;closed.incrementAndGet();} }
    }
    static final class Client implements AutoCloseable {
        final PipedOutputStream requests=new PipedOutputStream();
        final PipedInputStream stdin;
        final PipedInputStream responses=new PipedInputStream(65536);
        final PipedOutputStream stdout;
        final ConcurrentMap<String,CompletableFuture<Map<String,Object>>> pending=new ConcurrentHashMap<>();
        final SidecarServer server; final Thread serving; final AtomicInteger ids=new AtomicInteger();
        final AtomicLong ipcBytes=new AtomicLong();
        final AtomicBoolean ended=new AtomicBoolean();
        Client(Spider spider, boolean authorized, boolean capability) throws Exception { this(spider,authorized,capability,2); }
        Client(Spider spider, boolean authorized, boolean capability, int declaredConcurrency) throws Exception {
            stdin=new PipedInputStream(requests,65536);stdout=new PipedOutputStream(responses);
            server=new SidecarServer(spider,Map.of("key","proxy-fixture","capabilities",capability?List.of("play","proxy"):List.of("play"),
                    "permissions",Map.of("localProxy",authorized),"limits",Map.of("concurrency",declaredConcurrency)),stdin,stdout);
            serving=new Thread(()->server.serve(),"fixture-ipc-server");serving.setDaemon(true);serving.start();
            Thread reader=new Thread(()->{try{Object frame;while((frame=Ipc.readFrame(responses,Ipc.DEFAULT_MAX_FRAME_BYTES))!=null){
                ipcBytes.addAndGet(Json.write(frame).length());Map<String,Object> value=map(frame);
                CompletableFuture<Map<String,Object>> future=pending.remove(String.valueOf(value.get("id")));if(future!=null)future.complete(value);
            }}catch(Exception e){pending.values().forEach(f->f.completeExceptionally(e));}},"fixture-ipc-reader");reader.setDaemon(true);reader.start();
        }
        Map<String,Object> frame(String method,Map<String,Object> params) throws Exception {
            String id="f-"+ids.incrementAndGet();CompletableFuture<Map<String,Object>> future=new CompletableFuture<>();pending.put(id,future);
            synchronized(requests){Ipc.writeFrame(requests,Map.of("jsonrpc","2.0","id",id,"method",method,"params",params,"deadlineMs",30000));requests.flush();}
            return future.get(15,TimeUnit.SECONDS);
        }
        Map<String,Object> call(String method,Map<String,Object> params) throws Exception {
            Map<String,Object> frame=frame(method,params);check(!frame.containsKey("error"),"IPC "+method+" error "+frame.get("error"));return map(frame.get("result"));
        }
        Map<String,Object> init() throws Exception { return call("initialize",Map.of("abi",Ipc.ABI_NAME)); }
        Map<String,Object> control(String op,String id,String token) throws Exception {
            Map<String,Object> p=new HashMap<>();p.put("op",op);p.put("sessionId",id);if(token!=null)p.put("token",token);if(!op.equals("session.close"))p.put("ttlMs",120000);
            return call("proxy",p);
        }
        public void close() throws Exception { if(!ended.compareAndSet(false,true))return; try {call("destroy",Map.of());}finally{requests.close();serving.join(5000);responses.close();check(!serving.isAlive(),"destroy closes server");} }
    }
    static HttpResponse<InputStream> request(String url,String method,String range,String origin) throws Exception {
        HttpRequest.Builder b=HttpRequest.newBuilder(URI.create(url)).timeout(java.time.Duration.ofSeconds(15));
        if(range!=null)b.header("Range",range);if(origin!=null)b.header("Origin",origin);
        return HTTP.send(b.method(method,HttpRequest.BodyPublishers.noBody()).build(),HttpResponse.BodyHandlers.ofInputStream());
    }
    static String body(HttpResponse<InputStream> response) throws Exception { try(InputStream in=response.body()){return new String(in.readNBytes(1024),StandardCharsets.UTF_8);} }
    static void status(String url,int want) throws Exception {HttpResponse<InputStream> r=request(url,"GET",null,null);try(InputStream ignored=r.body()){check(r.statusCode()==want,"HTTP status expected "+want+" actual "+r.statusCode());}}
    static void awaitClosed(int previous) throws Exception {long end=System.nanoTime()+TimeUnit.SECONDS.toNanos(5);while(closed.get()<=previous&&System.nanoTime()<end)Thread.onSpinWait();check(closed.get()>previous,"source stream closed");}
    static void mainContract() throws Exception {
        Fixture source=new Fixture();
        try(Client client=new Client(source,true,true)) {
            Map<String,Object> init=client.init();
            check(init.get("extensions") instanceof Map,"RED: authorized initialize must negotiate extensions.proxyHttp");
            Map<String,Object> ext=map(map(init.get("extensions")).get("proxyHttp"));
            check(ext.get("version").equals(1L)||ext.get("version").equals(1),"proxyHttp v1");
            check(Boolean.TRUE.equals(ext.get("sessionControl")),"session control flag");
            String base=String.valueOf(ext.get("baseUrl"));check(URI.create(base).getHost().equals("127.0.0.1"),"loopback IPv4");
            check(source.initPort==URI.create(base).getPort(),"server bound and hook ready before spider init");
            HttpResponse<InputStream> health=request(base+"/proxy?do=ck","GET",null,null);check(health.statusCode()==200&&body(health).equals("ok"),"health exact ok");
            status(base+"/proxy?do=hxq",403);status(base+"/s/"+TOKEN+"/proxy",403);
            check(!client.frame("proxy",Map.of("op","session.open","sessionId","bad","token","short","ttlMs",120000)).containsKey("result"),"short token denied");
            Map<String,Object> open=client.control("session.open","p1",TOKEN);
            String entry=String.valueOf(open.get("entryUrl"));check(entry.equals(base+"/s/"+TOKEN+"/proxy"),"frozen scoped path");
            check(((Number)open.get("expiresInMs")).intValue()==120000,"frozen TTL");
            check(client.call("play",Map.of()).get("url").equals(entry),"host hook scoped playback entry");

            status(entry.replace(TOKEN,TOKEN.substring(1)+"x"),403);status(entry+"?duplicate=1&duplicate=2",400);
            status(entry+"?x=%0d%0a",400);status(entry+"?malformed=1",502);
            status(entry+"?oversized=1",502);
            int eofClosed=closed.get();HttpResponse<InputStream> truncated=request(entry+"?short=1","GET",null,null);
            boolean eof=false;try(InputStream in=truncated.body()){while(in.read()!=-1){} }catch(IOException expected){eof=true;}
            check(eof,"declared length early EOF fails HTTP body");awaitClosed(eofClosed);
            int before=closed.get();status(entry+"?bad=1",502);awaitClosed(before);
            HttpResponse<InputStream> origin=request(entry,"GET",null,"https://untrusted.invalid");check(origin.statusCode()==403,"browser Origin denied");origin.body().close();
            // 复用连接的客户端会把 RST 当成本次请求失败（实测 5 次里 2 次 ECONNRESET）：
            // 代理响应必须显式声明不可复用，而不是让对端凭 HTTP/1.1 默认值去猜。
            try(Socket raw=new Socket("127.0.0.1",URI.create(base).getPort())) {
                raw.setSoTimeout(5000);
                String path=URI.create(entry).getRawPath();
                raw.getOutputStream().write(("GET "+path+" HTTP/1.1\r\nHost: 127.0.0.1:"+URI.create(base).getPort()+"\r\n\r\n").getBytes(StandardCharsets.US_ASCII));
                ByteArrayOutputStream seen=new ByteArrayOutputStream();
                try{int b;while((b=raw.getInputStream().read())!=-1)seen.write(b);}
                catch(SocketTimeoutException blocked){check(false,"proxy must not leave the connection open after a response");}
                catch(IOException reset){}
                String head=seen.toString(StandardCharsets.US_ASCII).toLowerCase(Locale.ROOT);
                check(head.startsWith("http/1.1 200"),"raw entry response served");
                check(head.contains("\r\nconnection: close"),"proxy advertises Connection: close so clients never reuse");
            }
            HttpResponse<InputStream> ranged=request(entry+"?range=ignored","GET","bytes=0-3",null);
            check(ranged.statusCode()==206,"206 preserved");check(ranged.headers().firstValue("Content-Type").orElse("").equals("video/mp2t"),"fourth MIME wins");
            check(ranged.headers().firstValue("Content-Range").orElse("").equals("bytes 0-3/16"),"Content-Range preserved");
            check(ranged.headers().firstValue("Set-Cookie").isEmpty()&&ranged.headers().firstValue("Access-Control-Allow-Origin").isEmpty(),"no cookie or permissive CORS");
            check(body(ranged).length()==4,"range bytes");
            HttpResponse<InputStream> hop=request(entry+"?hop=1","GET",null,null);
            check(hop.headers().firstValue("ETag").isEmpty()&&hop.headers().firstValue("Last-Modified").isEmpty(),"Connection-nominated entity headers stripped case-insensitively");
            check(hop.headers().firstValue("Cache-Control").orElse("").equals("no-cache"),"unnominated entity header retained");
            hop.body().close();
            HttpResponse<InputStream> unsat=request(entry,"GET","bytes=999-",null);check(unsat.statusCode()==416,"416 preserved");unsat.body().close();
            HttpResponse<InputStream> head=request(entry,"HEAD",null,null);check(head.statusCode()==200&&head.body().read()==-1,"HEAD no body");head.body().close();
            try(Socket badHost=new Socket("127.0.0.1",URI.create(base).getPort())) {
                badHost.getOutputStream().write(("GET /proxy?do=ck HTTP/1.1\r\nHost: evil.invalid\r\nConnection: close\r\n\r\n").getBytes(StandardCharsets.US_ASCII));
                check(new BufferedReader(new InputStreamReader(badHost.getInputStream())).readLine().contains("403"),"invalid Host denied");
            }
            HttpResponse<InputStream> large=request(entry+"?large=1","GET",null,null);
            check(client.call("heartbeat",Map.of()).get("ok").equals(true),"IPC usable during HTTP stream");
            long bytes=0;byte[] buffer=new byte[65536];try(InputStream in=large.body()){int n;while((n=in.read(buffer))!=-1)bytes+=n;}
            check(bytes==70L*1024*1024,"stream >64MiB");check(client.ipcBytes.get()<16384,"media not in IPC");
            before=closed.get();HttpResponse<InputStream> endless=request(entry+"?endless=1","GET",null,null);endless.body().readNBytes(1024);endless.body().close();awaitClosed(before);
            before=closed.get();HttpResponse<InputStream> active=request(entry+"?endless=1","GET",null,null);
            client.control("session.open","p2",TOKEN+"a");awaitClosed(before);active.body().close();status(entry,403);
            String entry2=base+"/s/"+TOKEN+"a/proxy";
            client.control("session.close","p1",null);status(entry2,200);
            status(entry2+"?url="+URLEncoder.encode(entry2,StandardCharsets.UTF_8),400);
            HttpResponse<InputStream> busy1=request(entry2+"?endless=1","GET",null,null);
            HttpResponse<InputStream> busy2=request(entry2+"?endless=1","GET",null,null);
            // 数据面预算 = proxyPlaneConcurrency(2) = 4：两条流占不满，第三条应当照常服务。
            // 「有界」由 planeConcurrencyContract 里的 clamp 断言负责，不再是这里的一刀切 503。
            status(entry2,200);
            check(client.call("heartbeat",Map.of()).get("ok").equals(true),"bounded HTTP work does not starve IPC");
            busy1.body().close();busy2.body().close();
            playEntered=new CountDownLatch(1);playRelease=new CountDownLatch(1);
            CompletableFuture<Map<String,Object>> stale=CompletableFuture.supplyAsync(()->{
                try{return client.frame("play",Map.of("block",true));}catch(Exception error){throw new CompletionException(error);}
            });
            check(playEntered.await(5,TimeUnit.SECONDS),"stale play started");
            client.control("session.open","p3",TOKEN+"b");
            playRelease.countDown();
            check(stale.get(5,TimeUnit.SECONDS).containsKey("error"),"old in-flight play must not inherit replacement token");
            client.control("session.close","p3",null);
            client.control("session.open","p2",TOKEN+"a");
            client.control("session.renew","p2",null);client.control("session.close","p2",null);client.control("session.close","p2",null);status(entry2,403);
            check(client.frame("proxy",Map.of("op","session.renew","sessionId","p2","ttlMs",120000)).containsKey("error"),"closed renew fails");
            client.control("session.open","p3",TOKEN+"b");before=closed.get();HttpResponse<InputStream> dying=request(base+"/s/"+TOKEN+"b/proxy?endless=1","GET",null,null);
            client.call("destroy",Map.of());awaitClosed(before);dying.body().close();
        }
        try(Client denied=new Client(new Fixture(),false,true)){check(!denied.init().containsKey("extensions"),"permission required");}
        try(Client denied=new Client(new Fixture(),true,false)){check(!denied.init().containsKey("extensions"),"capability required");}
        try(Client denied=new Client(new Spider(){},true,true)){check(!denied.init().containsKey("extensions"),"genuine router required");}
    }
    // 数据面并发不能等于 IPC 并发：站点 manifest 的 limits.concurrency=1 是「站源方法同时跑几个」，
    // 不是「本机代理能同时服务几个 HTTP」。实测站点 concurrency=1 时，第二个重叠请求直接
    // 503「代理并发已达上限」——弹幕请求就是这样被拒的。
    static void planeConcurrencyContract() throws Exception {
        try(Client client=new Client(new Fixture(),true,true,1)) {
            client.init();
            String entry=String.valueOf(client.control("session.open","plane",TOKEN).get("entryUrl"));
            List<HttpResponse<InputStream>> streams=new ArrayList<>();
            try {
                for(int i=0;i<3;i++) streams.add(request(entry+"?endless=1","GET",null,null));
                for(int i=0;i<streams.size();i++) check(streams.get(i).statusCode()==200,"concurrent plane request "+(i+1)+" served, not rejected");
                check(SidecarServer.proxyPlaneConcurrency(1)>=3,"plane budget independent of declared IPC concurrency");
                check(SidecarServer.proxyPlaneConcurrency(64)<=32,"plane budget stays bounded");
            } finally { for(HttpResponse<InputStream> stream:streams) try{stream.body().close();}catch(IOException ignored){} }
        }
    }

    static void stalledConsumerContract() throws Exception {
        for(String operation:List.of("close","replace","stop","expire")) {
            AtomicLong clock=new AtomicLong(System.nanoTime());
            SpiderProxyHttpServer server=new SpiderProxyHttpServer(new Fixture(),1,clock::get);server.markReady();
            String entry=String.valueOf(server.control(Map.of("op","session.open","sessionId","stalled","token",TOKEN,"ttlMs",120000)).get("entryUrl"));
            Socket peer=new Socket();CompletableFuture<Void> action=null;int before=closed.get();
            try {
                peer.setReceiveBufferSize(1024);peer.connect(new InetSocketAddress("127.0.0.1",server.port()));peer.setSoTimeout(3000);
                String target=URI.create(entry).getRawPath()+"?endless=1";
                peer.getOutputStream().write(("GET "+target+" HTTP/1.1\r\nHost: 127.0.0.1:"+server.port()+"\r\nConnection: close\r\n\r\n").getBytes(StandardCharsets.US_ASCII));
                int matched=0;while(matched<4){int value=peer.getInputStream().read();check(value>=0,"stalled response header received");matched=value=="\r\n\r\n".charAt(matched)?matched+1:value=='\r'?1:0;}
                long until=System.nanoTime()+TimeUnit.SECONDS.toNanos(5);boolean blocked=false;
                while(!blocked&&System.nanoTime()<until) {
                    blocked=Thread.getAllStackTraces().entrySet().stream().anyMatch(e->e.getKey().getName().equals("webhtv-proxy-http")
                            &&Arrays.stream(e.getValue()).anyMatch(f->f.getClassName().endsWith("SocketDispatcher")&&f.getMethodName().startsWith("write")));
                    if(!blocked)Thread.onSpinWait();
                }
                check(blocked,"fixture established socket write backpressure before "+operation);
                action=CompletableFuture.runAsync(()->{
                    if(operation.equals("close"))server.control(Map.of("op","session.close","sessionId","stalled"));
                    else if(operation.equals("replace"))server.control(Map.of("op","session.open","sessionId","replacement","token",TOKEN+"x","ttlMs",120000));
                    else if(operation.equals("stop"))server.close();
                    else {clock.addAndGet(TimeUnit.SECONDS.toNanos(121));try{Method expire=SpiderProxyHttpServer.class.getDeclaredMethod("expire");expire.setAccessible(true);expire.invoke(server);}catch(ReflectiveOperationException error){throw new CompletionException(error);}}
                });
                try{action.get(1200,TimeUnit.MILLISECONDS);}catch(TimeoutException hung){throw new AssertionError(operation+" must not wait for stalled chunked client cooperation",hung);}
                awaitClosed(before);
            } finally {
                peer.close();if(action!=null)action.get(5,TimeUnit.SECONDS);server.close();
            }
        }
    }
    static final class InitFailsOnce extends Fixture {
        int attempts;
        public void init(String extend) {
            super.init(extend);
            if(++attempts==1)throw new IllegalStateException("EXPECTED_INIT_FAILURE");
        }
    }
    static void initializationFailureContract() throws Exception {
        InitFailsOnce source=new InitFailsOnce();
        try(Client client=new Client(source,true,true)) {
            check(client.frame("initialize",Map.of("abi",Ipc.ABI_NAME)).containsKey("error"),"source init failure reported");
            int failedPort=source.initPort;
            check((Integer)hostHook("getPort",new Class<?>[0])==0,"failed initializer unbinds host proxy hook");
            check(client.frame("proxy",Map.of("op","session.open","sessionId","failed","token",TOKEN,"ttlMs",120000)).containsKey("error"),"failed initializer denies session control");
            boolean unavailable=false;
            try{HttpResponse<InputStream> health=request("http://127.0.0.1:"+failedPort+"/proxy?do=ck","GET",null,null);unavailable=health.statusCode()!=200;health.body().close();}
            catch(IOException expected){unavailable=true;}
            check(unavailable,"failed initializer endpoint cannot return healthy ok");
            try(ServerSocket released=new ServerSocket()){released.bind(new InetSocketAddress("127.0.0.1",failedPort));check(released.isBound(),"failed initialization releases listener port");}
            Map<String,Object> init=client.init();check(init.containsKey("extensions"),"explicit successful initialize retry negotiates new endpoint");
            String entry=String.valueOf(client.control("session.open","retry",TOKEN).get("entryUrl"));status(entry,200);
        }
    }
    @SuppressWarnings("unchecked")
    static void logContract() throws Exception {
        PrintStream previous=System.err;ByteArrayOutputStream captured=new ByteArrayOutputStream();
        System.setErr(new PrintStream(captured,true,StandardCharsets.UTF_8));
        try(Client client=new Client(new Fixture(),true,true)) {
            client.init();String entry=String.valueOf(client.control("session.open","log",TOKEN).get("entryUrl"));
            PrintStream installed=System.err;
            System.err.write(("split "+entry.substring(0,entry.indexOf(TOKEN)+9)).getBytes(StandardCharsets.UTF_8));
            System.err.write((entry.substring(entry.indexOf(TOKEN)+9)+"?token=late-secret\n").getBytes(StandardCharsets.UTF_8));
            System.err.println("x".repeat(20000)+entry+"?token=oversized-secret");
            new IllegalStateException("trace "+entry+"?token=stack-secret").printStackTrace(System.err);
            client.control("session.close","log",null);
            System.err.println("late "+entry+"?token=after-close-secret");
            System.err.println("source url="+entry+"?url=https://upstream.invalid/stream?token=private");
            System.err.println("GET /s/"+TOKEN+"/proxy?url=REVIEW_QUERY_SECRET HTTP/1.1");
            System.err.println("params={token="+TOKEN+", id=not-claimed-opaque}");
            System.err.println("token=REVIEW_BARE_TOKEN session-id: REVIEW_SESSION_SECRET sessionId=REVIEW_CAMEL_SESSION");
            System.err.println("{\"token\":\"REVIEW_JSON_TOKEN\",\"sessionId\":\"REVIEW_JSON_SESSION\"}");
            System.err.flush();
            String text=captured.toString(StandardCharsets.UTF_8);
            check(!text.contains(TOKEN)&&!text.contains("private")&&!text.contains("late-secret")
                    &&!text.contains("stack-secret")&&!text.contains("after-close-secret"),"source stderr split/late/query tokens redacted");
            check(!text.contains("REVIEW_QUERY_SECRET"),"relative scoped request-target query redacted");
            check(!text.contains("REVIEW_BARE_TOKEN")&&!text.contains("REVIEW_SESSION_SECRET")
                    &&!text.contains("REVIEW_CAMEL_SESSION")&&!text.contains("REVIEW_JSON_TOKEN")
                    &&!text.contains("REVIEW_JSON_SESSION"),"common labeled token and session id redacted");
            check(text.contains("java.lang.IllegalStateException")&&text.contains("ProxyHttpContractTest.logContract"),"Throwable class and stack preserved");
            check(text.contains("oversized stderr line suppressed")&&text.length()<16384,"overlong stderr line bounded");
            client.close();
            try(Client next=new Client(new Fixture(),true,true)) {
                next.init();check(System.err==installed,"multiple servers do not layer stderr wrappers");
            }
            System.err.println("sink-still-open");
            check(captured.toString(StandardCharsets.UTF_8).contains("sink-still-open"),"server close does not close original stderr sink");
        }finally{System.setErr(previous);}
    }
    static void expiryContract() throws Exception {
        Class<?> type=Class.forName("webhtv.spider.SpiderProxyHttpServer");
        AtomicLong clock=new AtomicLong(System.nanoTime());
        Constructor<?> c=type.getDeclaredConstructor(Spider.class,int.class,java.util.function.LongSupplier.class);c.setAccessible(true);
        Object server=c.newInstance(new Fixture(),1,(java.util.function.LongSupplier)clock::get);
        type.getMethod("markReady").invoke(server);
        Method control=type.getDeclaredMethod("control",Map.class);control.setAccessible(true);
        String entry=String.valueOf(map(control.invoke(server,Map.of("op","session.open","sessionId","expiry","token",TOKEN,"ttlMs",120000))).get("entryUrl"));
        try{
            status(entry,200);int before=closed.get();HttpResponse<InputStream> active=request(entry+"?endless=1","GET",null,null);
            clock.addAndGet(TimeUnit.SECONDS.toNanos(121));status(entry,403);awaitClosed(before);active.body().close();
        }
        finally{((AutoCloseable)server).close();}
    }
    static void shellRouterContract() throws Exception {
        Path root=Path.of(".probe/proxy-bridge/jvm/generated-shell").toAbsolutePath();Files.createDirectories(root);
        Path router=root.resolve("ProxyOrigin.java"),target=root.resolve("PayloadFixture.java"),shell=root.resolve("Proxy.java"),nativeInit=root.resolve("InitOrigin.java");
        Files.writeString(router,"package com.github.catvod.spider; public class ProxyOrigin { public static int attached; public static void init(){if(com.github.catvod.Proxy.getPort()<=0)throw new AssertionError(\"scan fallback\");attached++;} public static Object[] proxy(java.util.Map<String,String> p){return new Object[]{200,\"text/plain\",new java.io.ByteArrayInputStream(\"payload-router\".getBytes())};} }");
        Files.writeString(target,"package com.github.catvod.spider; public class PayloadFixture extends com.github.catvod.crawler.Spider { public static Object[] proxy(java.util.Map<String,String> p){throw new AssertionError(\"direct payload fallback\");} }");
        Files.writeString(shell,"package com.github.catvod.spider; public class Proxy { public static Object[] proxy(java.util.Map<String,String> p){throw new AssertionError(\"shell recursion\");} }");
        Files.writeString(nativeInit,"package com.github.catvod.spider; public class InitOrigin { public static void init(android.content.Context c){throw new AssertionError(\"native init forbidden\");} }");
        check(ToolProvider.getSystemJavaCompiler().run(null,null,null,"-classpath",System.getProperty("java.class.path"),"-d",root.toString(),router.toString(),target.toString(),shell.toString(),nativeInit.toString())==0,"compile payload routing fixture");
        Path jar=root.resolve("payload.jar");
        try(java.util.jar.JarOutputStream out=new java.util.jar.JarOutputStream(Files.newOutputStream(jar));var files=Files.walk(root)) {
            for(Path file:files.filter(f->f.toString().endsWith(".class")).toList()) {
                out.putNextEntry(new java.util.jar.JarEntry(root.relativize(file).toString().replace('\\','/')));Files.copy(file,out);out.closeEntry();
            }
        }
        String previous=System.getProperty("webhtv.shellPayload");System.setProperty("webhtv.shellPayload",jar.toString());
        try {
            ClassLoader loader=(ClassLoader)com.github.catvod.spider.DexNative.getLoader(null);
            Object instance=com.github.catvod.spider.DexNative.getSpider(loader,"com.github.catvod.spider.PayloadFixture");
            try(Client client=new Client(new CatVodSpiderAdapter(instance,null),true,true)) {
                client.init();client.control("session.open","payload",TOKEN);
                Object[] response=com.github.catvod.spider.DexNative.proxyInvoke(loader,Map.of("do","hxq"));
                try(InputStream body=(InputStream)response[2]){check(new String(body.readNBytes(64),StandardCharsets.UTF_8).equals("payload-router"),"actual DexNative loader ABI selects payload router without shell recursion");}
                check(loader.loadClass("com.github.catvod.spider.ProxyOrigin").getField("attached").getInt(null)==1,"payload discovery attached without native InitOrigin");
            }
        } finally {if(previous==null)System.clearProperty("webhtv.shellPayload");else System.setProperty("webhtv.shellPayload",previous);}
    }
    static void routerContract() throws Exception {
        Path root=Path.of(".probe/proxy-bridge/jvm/generated").toAbsolutePath();Files.createDirectories(root);
        Path router=root.resolve("ProxyOrigin.java");Path target=root.resolve("FixtureCat.java");
        Files.writeString(router,"package com.github.catvod.spider; public class ProxyOrigin { public static int attached; public static void init(){ if(com.github.catvod.Proxy.getPort()<=0)throw new AssertionError(\"port\"); attached++; } public static Object[] proxy(java.util.Map<String,String> p){if(p.containsKey(\"throw\"))throw new IllegalStateException(\"router-failed\");return new Object[]{200,\"text/plain\",new java.io.ByteArrayInputStream(\"router\".getBytes())};}} ");
        Files.writeString(target,"package fixture; public class FixtureCat extends com.github.catvod.crawler.Spider { public static int fallbackCalls; public static Object[] proxy(java.util.Map<String,String> p){fallbackCalls++;throw new AssertionError(\"wrong direct fallback\");} public String playerContent(String f,String id,java.util.List<String> v){return \"{\\\"url\\\":\\\"\"+com.github.catvod.Proxy.getUrl(false)+\"\\\"}\";} }");
        check(ToolProvider.getSystemJavaCompiler().run(null,null,null,"-classpath",System.getProperty("java.class.path"),"-d",root.toString(),router.toString(),target.toString())==0,"compile router fixture");
        try(URLClassLoader loader=new URLClassLoader(new URL[]{root.toUri().toURL()},ProxyHttpContractTest.class.getClassLoader())){
            Object targetObject=Class.forName("fixture.FixtureCat",true,loader).getConstructor().newInstance();
            try(Client client=new Client(new CatVodSpiderAdapter(targetObject,null),true,true)){
                Map<String,Object> init=client.init();check(init.containsKey("extensions"),"CatVod router negotiated");
                check(Class.forName("com.github.catvod.spider.ProxyOrigin",false,loader).getField("attached").getInt(null)==1,"explicit ProxyOrigin attach");
                String entry=String.valueOf(client.control("session.open","router",TOKEN).get("entryUrl"));
                check(body(request(entry,"GET",null,null)).equals("router"),"router preferred to direct spider");
                status(entry+"?throw=1",502);
                check(targetObject.getClass().getField("fallbackCalls").getInt(null)==0,"router invocation error never falls back");
                check(client.call("play",Map.of("id","full-fixture-id")).get("url").equals(entry),"CatVod hook bypasses scan");
            }
        }
    }
    public static void main(String[] args) throws Exception {
        Thread watchdog=new Thread(()->{try{Thread.sleep(45000);System.err.println("FAIL native fixture exceeded45s");System.exit(9);}catch(InterruptedException done){}},"fixture-deadline");watchdog.setDaemon(true);watchdog.start();
        mainContract();planeConcurrencyContract();stalledConsumerContract();initializationFailureContract();expiryContract();routerContract();logContract();shellRouterContract();
        check(closed.get()==opened.get(),"all acquired source streams closed");
        watchdog.interrupt();
        System.out.println("PASS ProxyHttpContractTest assertions="+assertions+" streamed=73400320 bytes IPC=small closed="+closed.get());
    }
}
