package com.github.catvod;

import webhtv.spider.SpiderProxyHttpServer;

/** Host ABI used by payload ProxyOrigin; no server starts from this hook. */
public final class Proxy {
    private static volatile SpiderProxyHttpServer owner;
    private Proxy() {}

    public static synchronized void bind(SpiderProxyHttpServer server) {
        if (owner != null && owner != server) throw new IllegalStateException("代理宿主已绑定");
        owner = server;
    }

    public static synchronized void unbind(SpiderProxyHttpServer server) {
        if (owner == server) owner = null;
    }

    public static int getPort() {
        SpiderProxyHttpServer server = owner;
        return server == null ? 0 : server.port();
    }

    public static String getUrl() { return getUrl(false); }

    public static String getUrl(boolean ignored) {
        SpiderProxyHttpServer server = owner;
        if (server == null) throw new IllegalStateException("代理宿主尚未就绪");
        return server.entryUrl();
    }
}
