package com.github.catvod.crawler;

/**
 * CatVod 调试日志垫片：宿主是 JVM 侧，日志统一走 stderr，避免污染 stdout 的数据通道。
 */
public class SpiderDebug {

    public static void log(String msg) {
        System.err.println("[catvod] " + msg);
    }

    public static void log(Throwable tr) {
        System.err.println("[catvod] " + (tr == null ? "null" : tr.toString()));
        if (tr != null) {
            tr.printStackTrace(System.err);
        }
    }
}
