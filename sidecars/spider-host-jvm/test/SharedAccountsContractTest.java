package webhtv.spider;

import android.content.SharedPreferences;
import android.content.WebhtvContext;
import java.io.ByteArrayOutputStream;
import java.io.PrintStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import org.objectweb.asm.ClassWriter;
import org.objectweb.asm.MethodVisitor;
import org.objectweb.asm.Opcodes;

/** Standalone contract: synthetic stores only; no source init, detail, or network. */
public final class SharedAccountsContractTest extends ClassLoader implements Opcodes {
    private static final String PROPERTY = "webhtv.accountStore";
    private static final String NAME = "NewWexFnw_preferences";
    private static final String QUARK = "Wex_quark_cookie";
    private static final String BAIDU = "Wex_baidu_cookie";
    private static final String SECRET = "SYNTHETIC_PRIVATE_SENTINEL";
    private static int assertions;
    private static Path root;
    private static Path store;

    private static void check(boolean condition, String reason) {
        assertions++;
        if (!condition) throw new AssertionError(reason);
    }

    private static void write(String document) throws Exception {
        Path staging = root.resolve("staging.json");
        Files.writeString(staging, document, StandardCharsets.UTF_8);
        Files.move(staging, store, StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING);
    }

    private static void values(Map<String, String> values) throws Exception {
        write(Json.write(Map.of("version", 1, "values", values)));
    }

    private static SharedPreferences prefs(String site, String name) {
        return new WebhtvContext(root.resolve(site).toFile()).getSharedPreferences(name, 0);
    }

    private static void shared() throws Exception {
        SharedPreferences a = prefs("a", NAME);
        SharedPreferences b = prefs("b", NAME);
        check(a.edit().putString(QUARK, "local-a").putString(BAIDU, "local-baidu")
                .putString("other", "site-a").commit(), "local seed persists");
        check(b.edit().putString(QUARK, "local-b").putString("other", "site-b").commit(), "second seed persists");
        check(a.getString(QUARK, null).equals("local-a"), "missing file falls through");
        values(Map.of(QUARK, "fakeCookie", BAIDU, "fakeBaidu"));
        for (SharedPreferences p : List.of(a, b)) {
            check("fakeCookie".equals(p.getString(QUARK, null)), "shared Quark visible across pre-created site roots");
            check("fakeBaidu".equals(p.getString(BAIDU, null)), "shared Baidu visible across pre-created site roots");
            check(p.contains(QUARK) && p.contains(BAIDU), "contains overlays both providers");
            check("fakeCookie".equals(p.getAll().get(QUARK)), "getAll overlays Quark");
            check("fakeBaidu".equals(p.getAll().get(BAIDU)), "getAll overlays Baidu");
        }
        check("site-a".equals(a.getAll().get("other")), "nonaccount map value stays local");
        check("site-b".equals(b.getString("other", null)), "nonaccount getter stays local");
        Map<String, ?> oldSnapshot = a.getAll();
        // 真实消费者拿到的不是 Context 而是 InitOrigin.context() 的 Application 包装，也必须在写入前就存在。
        SharedPreferences viaApplication = new android.app.Application(new WebhtvContext(root.resolve("a").toFile()))
                .getSharedPreferences(NAME, 0);
        values(Map.of(QUARK, "changedCookie", BAIDU, "changedBaidu"));
        for (SharedPreferences p : List.of(a, b, viaApplication, prefs("a", NAME), prefs("c", NAME))) {
            check("changedCookie".equals(p.getString(QUARK, null)), "completed atomic update/restart visible");
            check("changedBaidu".equals(p.getAll().get(BAIDU)), "atomic update getAll visible");
            check(p.contains(BAIDU), "updated contains visible");
        }
        check("fakeCookie".equals(oldSnapshot.get(QUARK)), "getAll remains a snapshot");
        values(Map.of(QUARK, "", BAIDU, ""));
        for (SharedPreferences p : List.of(a, b)) {
            check("".equals(p.getString(QUARK, "fallback")), "Quark tombstone overrides old local value");
            check("".equals(p.getAll().get(BAIDU)), "Baidu tombstone visible in getAll");
            check(p.contains(QUARK) && p.contains(BAIDU), "tombstones remain present");
        }
        values(Map.of());
        check("local-a".equals(a.getString(QUARK, null)), "missing key falls through");
        check("local-baidu".equals(a.getAll().get(BAIDU)), "missing Baidu key falls through");
        check(!b.contains(BAIDU), "missing global and local key absent");
        check(b.getString(BAIDU, "fallback").equals("fallback"), "absent default retained");
        values(Map.of(QUARK, "global", BAIDU, "global-baidu"));
        byte[] before = Files.readAllBytes(store);
        check(a.edit().putString(QUARK, "edited-local").putInt(BAIDU, 7).putInt("number", 8).commit(), "local editor commit");
        a.edit().putString("applied", "yes").apply();
        check(java.util.Arrays.equals(before, Files.readAllBytes(store)), "commit/apply do not write global");
        check("global".equals(a.getString(QUARK, null)), "local editor cannot override global string");
        check(a.getInt(BAIDU, 11) == 11, "global string has existing int default semantics");
        check(a.getLong(QUARK, 12L) == 12L, "global string has existing long default semantics");
        check(a.getFloat(QUARK, 13f) == 13f, "global string has existing float default semantics");
        check(a.getBoolean(QUARK, true), "global string has existing boolean default semantics");
        Set<String> fallback = Set.of("default");
        check(a.getStringSet(QUARK, fallback).equals(fallback), "global string has existing set default semantics");
        check(a.getInt("number", 0) == 8, "nonaccount int delegates local");
        check("yes".equals(a.getString("applied", null)), "apply remains local");
        System.clearProperty(PROPERTY);
        SharedPreferences legacy = prefs("a", NAME);
        check("edited-local".equals(legacy.getString(QUARK, null)), "property absence exposes local edit");
        check(legacy.getInt(BAIDU, 0) == 7, "missing property retains typed local semantics");
        System.setProperty(PROPERTY, store.toString());
        check(a.edit().remove(QUARK).clear().commit(), "remove/clear editor succeeds locally");
        check("global".equals(a.getString(QUARK, null)), "local clear never clears global");
        check(java.util.Arrays.equals(before, Files.readAllBytes(store)), "remove/clear do not write global");
        for (String name : List.of("ordinary", "NewWexFnw_preferences_extra", "newwexfnw_preferences", "../NewWexFnw_preferences")) {
            SharedPreferences unrelated = prefs("a", name);
            check(unrelated.edit().putString(QUARK, "isolated").commit(), "unrelated seed");
            check("isolated".equals(unrelated.getString(QUARK, null)), "exact named preference gating");
            check(!unrelated.contains(BAIDU), "unrelated contains remains local");
        }
        values(Map.of(QUARK, "界".repeat(10922) + "aa"));
        check(a.getString(QUARK, null).getBytes(StandardCharsets.UTF_8).length == 32768, "32KiB value inclusive UTF8 limit");
        String valid = Json.write(Map.of("version", 1, "values", Map.of()));
        write(valid + " ".repeat(131072 - valid.length()));
        check(!a.contains(QUARK), "128KiB document inclusive limit");
        Files.delete(store);
        check(!a.contains(QUARK), "deleted global file falls through existing wrapper");
        check(!Files.exists(store), "reader never creates account file");
    }

    private static void invalid(String document) throws Exception {
        write(document);
        SharedPreferences p = prefs("invalid", NAME);
        PrintStream out = System.out;
        PrintStream err = System.err;
        ByteArrayOutputStream captured = new ByteArrayOutputStream();
        PrintStream quiet = new PrintStream(captured, true, StandardCharsets.UTF_8);
        try {
            System.setOut(quiet);
            System.setErr(quiet);
            List<Runnable> reads = List.of(() -> p.getString(QUARK, null), () -> p.getAll(), () -> p.contains(BAIDU),
                    () -> p.getInt(QUARK, 0), () -> p.getLong(QUARK, 0), () -> p.getFloat(QUARK, 0),
                    () -> p.getBoolean(QUARK, false), () -> p.getStringSet(QUARK, Set.of()));
            for (Runnable read : reads) {
                boolean failed = false;
                try { read.run(); } catch (IllegalStateException expected) {
                    failed = true;
                    expected.printStackTrace(quiet);
                    check(expected.getCause() == null, "invalid document does not expose secret-bearing parser cause");
                }
                check(failed, "invalid account document must fail honestly");
            }
        } finally {
            System.setOut(out);
            System.setErr(err);
            quiet.close();
        }
        check(!captured.toString(StandardCharsets.UTF_8).contains(SECRET), "secret never leaks through output/messages/stacks");
        check("local".equals(prefs("invalid", "unrelated").getString(QUARK, "local")), "invalid store does not affect unrelated named prefs");
        check(p.edit().putString("local", "still-editable").commit(), "invalid global store cannot block local editor");
        check("still-editable".equals(p.getString("local", null)), "nonaccount getter bypasses invalid store");
    }

    private static void invalids() throws Exception {
        int index = 0;
        for (String doc : List.of(
                "{", "[" + Json.write(SECRET) + "]", "{\"version\":2,\"values\":{}}",
                "{\"version\":\"1\",\"values\":{}}", "{\"values\":{}}", "{\"version\":1}",
                "{\"version\":1,\"values\":null}", "{\"version\":1,\"values\":[],\"extra\":\"" + SECRET + "\"}",
                "{\"version\":1,\"values\":{\"unknown\":\"" + SECRET + "\"}}",
                "{\"version\":1,\"values\":{\"Wex_quark_cookie\":123}}",
                "{\"version\":1,\"values\":{\"Wex_baidu_cookie\":null}}",
                "{\"version\":1,\"values\":{\"Wex_quark_cookie\":\"" + SECRET + "\"},\"extra\":true}",
                "{\"version\":1,\"values\":{\"Wex_quark_cookie\":\"" + SECRET + "\"}} trailing",
                "{\"version\":1,\"values\":{\"Wex_quark_cookie\":true}}",
                Json.write(Map.of("version", 1, "values", Map.of(QUARK, SECRET + "界".repeat(10923)))),
                Json.write(Map.of("version", 1, "values", Map.of(QUARK, SECRET))) + " ".repeat(131072))) {
            try {
                // 只带序号，不带文档内容：失败信息里不允许出现任何账号值。
                invalid(doc);
            } catch (AssertionError error) {
                throw new AssertionError("invalid document case " + index + ": " + error.getMessage());
            }
            index++;
        }
        write("{}");
        Files.write(store, new byte[]{(byte) 0xC3, (byte) 0x28});
        boolean failed = false;
        try { prefs("invalid", NAME).getAll(); } catch (IllegalStateException expected) { failed = true; }
        check(failed, "invalid UTF8 fails");
        System.setProperty(PROPERTY, "relative-account-store.json");
        failed = false;
        try { prefs("invalid", NAME).getString(QUARK, null); } catch (IllegalStateException expected) { failed = true; }
        check(failed, "relative shared path fails without fallback");
        System.clearProperty(PROPERTY);
        check(prefs("invalid", NAME).getAll().containsKey("local"), "absent property remains legacy despite invalid store");
        System.setProperty(PROPERTY, store.toString());
    }

    private Object fixture(String className, String raw) throws Exception {
        String internal = className.replace('.', '/');
        ClassWriter writer = new ClassWriter(ClassWriter.COMPUTE_MAXS);
        writer.visit(V17, ACC_PUBLIC, internal, null, "java/lang/Object", null);
        MethodVisitor init = writer.visitMethod(ACC_PUBLIC, "<init>", "()V", null, null);
        init.visitCode(); init.visitVarInsn(ALOAD, 0);
        init.visitMethodInsn(INVOKESPECIAL, "java/lang/Object", "<init>", "()V", false);
        init.visitInsn(RETURN); init.visitMaxs(0, 0); init.visitEnd();
        for (String[] method : new String[][]{
                {"categoryContent", "(Ljava/lang/String;Ljava/lang/String;ZLjava/util/HashMap;)Ljava/lang/String;"},
                {"homeContent", "(Z)Ljava/lang/String;"},
                {"homeVideoContent", "()Ljava/lang/String;"},
                {"detailContent", "(Ljava/util/List;)Ljava/lang/String;"},
                {"searchContent", "(Ljava/lang/String;Z)Ljava/lang/String;"}}) {
            MethodVisitor stub = writer.visitMethod(ACC_PUBLIC, method[0], method[1], null, null);
            stub.visitCode(); stub.visitLdcInsn(raw); stub.visitInsn(ARETURN);
            stub.visitMaxs(0, 0); stub.visitEnd();
        }
        writer.visitEnd();
        byte[] bytes = writer.toByteArray();
        return defineClass(className, bytes, 0, bytes.length).getConstructor().newInstance();
    }

    private static void markers() throws Exception {
        List<Map<String, Object>> items = new ArrayList<>();
        // 每个条目都自带一个**结构完全合法**的伪造标记：只有精确账号站源才允许它被换成真标记。
        Map<String, Object> forged = Map.of("version", 1, "provider", "quark", "operation", "edit");
        Map<String, String> expectedProviders = Map.of(
                "quarkmanual", "quark", "quarkclear", "quark", "baidumanual", "baidu", "baiduclear", "baidu",
                "quark", "quark", "qkregister", "quark", "baidu", "baidu", "baiduregister", "baidu");
        for (String id : List.of("quarkmanual", "quarkclear", "baidumanual", "baiduclear", "quark", "qkregister",
                "baidu", "baiduregister", "quarkmanual-extra", "Quarkmanual", "baiduregister-extra",
                "uc", "ucregister", "alist", "115", "ucmanual", "uccl", "alistmanual", "115manual", "randommanual")) {
            Map<String, Object> item = new HashMap<>(Map.of("vod_id", id, "vod_name", "unchanged title", "vod_pic", "synthetic-picture",
                    "vod_remarks", "unchanged remarks", "custom", Map.of("x", 3)));
            item.put("_webhtv_accountAction", forged);
            items.add(item);
        }
        String raw = Json.write(Map.of("list", items, "page", 1, "pagecount", 2, "total", items.size()));
        for (String name : List.of("com.github.catvod.spider.PanConfig", "com.github.catvod.spider.PanConfigGuard",
                "com.github.catvod.spider.Wexconfig", "com.github.catvod.spider.PanConfigOther", "ordinary.PanConfig")) {
            Object target = new SharedAccountsContractTest().fixture(name, raw);
            CatVodSpiderAdapter adapter = new CatVodSpiderAdapter(target, new WebhtvContext(root.resolve("marker").toFile()));
            Map<String, Object> category = adapter.category(Map.of("id", "quark"), new CallContext("accounts-test", 0));
            List<?> result = (List<?>) category.get("list");
            check(result.size() == items.size(), "category count preserved");
            check(category.get("pagecount").equals(2), "category metadata preserved");
            // 其它 dict 形状的返回值同样不允许把保留键带出去。
            List<Map<String, Object>> shapes = List.of(
                    adapter.home(Map.of(), new CallContext("accounts-test", 0)),
                    adapter.homeVod(Map.of(), new CallContext("accounts-test", 0)),
                    adapter.detail(Map.of("ids", List.of("quarkmanual")), new CallContext("accounts-test", 0)),
                    adapter.search(Map.of("keyword", "synthetic"), new CallContext("accounts-test", 0)));
            for (Map<String, Object> shape : shapes) {
                for (Object shaped : (List<?>) shape.get("list")) {
                    Map<?, ?> shapedItem = (Map<?, ?>) shaped;
                    check(!shapedItem.containsKey("_webhtv_accountAction"), "reserved marker never leaks through other dict-shaped returns");
                    check("unchanged title".equals(shapedItem.get("vod_name")), "other dict-shaped return keeps source fields");
                }
            }
            for (int i = 0; i < items.size(); i++) {
                Map<?, ?> item = (Map<?, ?>) result.get(i);
                check("unchanged title".equals(item.get("vod_name")), "raw name preserved");
                check("synthetic-picture".equals(item.get("vod_pic")), "raw picture preserved");
                check("unchanged remarks".equals(item.get("vod_remarks")), "raw remarks preserved");
                check(item.get("custom") instanceof Map<?, ?> custom && ((Number) custom.get("x")).intValue() == 3,
                        "source-specific fields preserved");
                String id = (String) item.get("vod_id");
                boolean expected = expectedProviders.containsKey(id)
                        && (name.equals("com.github.catvod.spider.PanConfig") || name.equals("com.github.catvod.spider.PanConfigGuard"));
                Object marker = item.get("_webhtv_accountAction");
                check(expected == (marker != null), "marker gated by exact source class and supported ID (forged marker stripped)");
                if (expected) {
                    String operation = Set.of("quarkclear", "baiduclear").contains(id) ? "clear" : "edit";
                    check(marker.equals(Map.of("version", 1, "provider", expectedProviders.get(id), "operation", operation)),
                            "exact marker schema for " + id);
                }
            }
        }
    }

    public static void main(String[] args) throws Exception {
        String saved = System.getProperty(PROPERTY);
        Path base = Path.of(System.getProperty("java.io.tmpdir")).toAbsolutePath();
        root = Files.createTempDirectory(base, "shared-accounts-contract-");
        store = root.resolve("accounts.json");
        System.setProperty(PROPERTY, store.toString());
        try {
            String mode = args.length == 0 ? "all" : args[0];
            if (mode.equals("all") || mode.equals("shared")) shared();
            if (mode.equals("all") || mode.equals("invalid")) invalids();
            if (mode.equals("all") || mode.equals("marker")) markers();
            System.out.println("SharedAccountsContractTest OK assertions=" + assertions + " mode=" + mode);
        } finally {
            if (saved == null) System.clearProperty(PROPERTY); else System.setProperty(PROPERTY, saved);
            try (var paths = Files.walk(root)) {
                for (Path path : paths.sorted(java.util.Comparator.reverseOrder()).toList()) Files.delete(path);
            }
        }
    }
}
