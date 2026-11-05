package com.github.catvod.crawler;

import android.content.Context;

import java.util.HashMap;
import java.util.List;

/**
 * CatVod Spider 基类的 JVM 垫片。
 * 该类不在 android.jar 中，签名按转译产物实际调用解析需求固定，方法体全部为空实现。
 */
public class Spider {

    public Spider() {
    }

    public void init(Context context) {
    }

    public void init(Context context, String extend) {
    }

    public String homeContent(boolean filter) {
        return null;
    }

    public String homeVideoContent() {
        return null;
    }

    // 第 4 参必须是 HashMap 而非 Map：转译产物按该精确签名做反射/绑定解析
    public String categoryContent(String tid, String pg, boolean filter, HashMap<String, String> extend) {
        return null;
    }

    public String detailContent(List<String> ids) {
        return null;
    }

    public String searchContent(String key, boolean quick) {
        return null;
    }

    public String playerContent(String flag, String id, List<String> vipFlags) {
        return null;
    }

    public String liveContent(String url) {
        return null;
    }

    public String action(String action) {
        return null;
    }

    public void destroy() {
    }
}
