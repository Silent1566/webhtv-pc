package android.content;

import java.io.File;
import java.util.regex.Pattern;

/**
 * {@link Context} 的宿主真实现：把站源要的存储位置落在**站点目录**下的一个子目录里。
 *
 * <p>为什么需要它：{@link Context} 是 abstract（照 javap，真机上也是 abstract class，由系统
 * 创建），而 CatVod 站源的 {@code init(Context, String)} 必须收到一个**真实例**。垫片层自己
 * 决定不了「哪个站点用哪个目录」，所以实现放在 shim、目录由宿主（EntryLoader）传入。
 *
 * <p>为什么按站点目录隔离：多个站源共享同一个 JVM，若都写同一个 SharedPreferences 文件，
 * 站点 A 的 token 会被站点 B 读到（§9.8 安全边界）。
 */
public class WebhtvContext extends Context {

    /** 站源 {@code name} 直接拼进文件名会有路径穿越风险；非白名单字符统一替换。 */
    private static final Pattern UNSAFE = Pattern.compile("[^A-Za-z0-9._-]");

    private final File root;

    public WebhtvContext(File root) {
        this.root = root;
        if (root != null && !root.isDirectory()) {
            root.mkdirs();
        }
    }

    /** 站点目录下的宿主数据根（诊断用）。 */
    public File root() {
        return root;
    }

    @Override
    public SharedPreferences getSharedPreferences(String name, int mode) {
        File prefsDir = new File(root, "shared_prefs");
        prefsDir.mkdirs();
        String safe = name == null || name.isEmpty()
                ? "default"
                : UNSAFE.matcher(name).replaceAll("_");
        return new WebhtvPreferences(new File(prefsDir, safe + ".properties"));
    }

    @Override
    public File getFilesDir() {
        File dir = new File(root, "files");
        dir.mkdirs();
        return dir;
    }

    @Override
    public File getCacheDir() {
        File dir = new File(root, "cache");
        dir.mkdirs();
        return dir;
    }

    @Override
    public String getPackageName() {
        return "webhtv.spider.host";
    }

    @Override
    public Object getSystemService(String name) {
        // 桌面 sidecar 没有 Android 系统服务；返回 null 而不是假对象，让依赖它的站源
        // 在调用点失败（而不是以为拿到了可用服务）。
        return null;
    }
}
