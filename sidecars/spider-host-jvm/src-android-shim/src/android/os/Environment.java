package android.os;

import java.io.File;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;

/**
 * android.os.Environment 的桌面垫片（真实现，不再返回 "Stub!"）。
 *
 * <p>存在意义：站源/播放器代码习惯用 Environment 拿「外部存储/下载/缓存」目录，
 * 跑在桌面 JVM 上没有 /sdcard，也不该往用户文档目录里乱写。所以这里把四个入口
 * 全部重定向到 {@code System.getProperty("java.io.tmpdir")/webhtv-dex/} 下的子目录，
 * 保证卸载/重启后由系统临时目录自行清理。
 *
 * <p>常量名与取值一律照 android-36 android.jar 的 javap -c 常量池抄写。注意
 * DIRECTORY_* 在真机上本来就是「非 final 的 static 字段」（可被测试替换），
 * 这里保持一致，不加 final。
 */
public class Environment {

    /** 桌面侧所有「外部存储」的落点，位于 java.io.tmpdir 之下。 */
    private static final String BASE_DIR_NAME = "webhtv-dex";

    private static final File BASE_DIR =
            new File(System.getProperty("java.io.tmpdir", "."), BASE_DIR_NAME);

    /** 只用来保证每个子目录的 mkdirs 只发生一次，避免每次取路径都打一次系统调用。 */
    private static final Set<String> CREATED = ConcurrentHashMap.newKeySet();

    public static String DIRECTORY_ALARMS = "Alarms";
    public static String DIRECTORY_AUDIOBOOKS = "Audiobooks";
    public static String DIRECTORY_DCIM = "DCIM";
    public static String DIRECTORY_DOCUMENTS = "Documents";
    public static String DIRECTORY_DOWNLOADS = "Download";
    public static String DIRECTORY_MOVIES = "Movies";
    public static String DIRECTORY_MUSIC = "Music";
    public static String DIRECTORY_NOTIFICATIONS = "Notifications";
    public static String DIRECTORY_PICTURES = "Pictures";
    public static String DIRECTORY_PODCASTS = "Podcasts";
    public static String DIRECTORY_RECORDINGS = "Recordings";
    public static String DIRECTORY_RINGTONES = "Ringtones";
    public static String DIRECTORY_SCREENSHOTS = "Screenshots";

    public static final String MEDIA_BAD_REMOVAL = "bad_removal";
    public static final String MEDIA_CHECKING = "checking";
    public static final String MEDIA_EJECTING = "ejecting";
    public static final String MEDIA_MOUNTED = "mounted";
    public static final String MEDIA_MOUNTED_READ_ONLY = "mounted_ro";
    public static final String MEDIA_NOFS = "nofs";
    public static final String MEDIA_REMOVED = "removed";
    public static final String MEDIA_SHARED = "shared";
    public static final String MEDIA_UNKNOWN = "unknown";
    public static final String MEDIA_UNMOUNTABLE = "unmountable";
    public static final String MEDIA_UNMOUNTED = "unmounted";

    public Environment() {
        // javap 显示真机有这个 public 构造器，保留以便反射/子类兼容。
    }

    public static File getExternalStorageDirectory() {
        return dir("external");
    }

    public static File getExternalStoragePublicDirectory(String type) {
        // type 为 null 时落到 external 本身，与真机「找不到就退到根」的行为接近，且不至于 NPE。
        return type == null ? dir("external") : dir("external/" + type);
    }

    public static File getDataDirectory() {
        return dir("data");
    }

    public static File getDownloadCacheDirectory() {
        return dir("cache");
    }

    public static File getRootDirectory() {
        return dir("system");
    }

    public static File getStorageDirectory() {
        return dir("storage");
    }

    public static String getExternalStorageState() {
        return MEDIA_MOUNTED;
    }

    public static String getExternalStorageState(File path) {
        return getStorageState(path);
    }

    public static String getStorageState(File path) {
        // 桌面下我们用的就是本地临时目录，能读写即视为已挂载。
        return MEDIA_MOUNTED;
    }

    public static boolean isExternalStorageEmulated() {
        return true;
    }

    public static boolean isExternalStorageEmulated(File path) {
        return true;
    }

    public static boolean isExternalStorageLegacy() {
        return false;
    }

    public static boolean isExternalStorageLegacy(File path) {
        return false;
    }

    public static boolean isExternalStorageManager() {
        return true;
    }

    public static boolean isExternalStorageManager(File path) {
        return true;
    }

    public static boolean isExternalStorageRemovable() {
        return false;
    }

    public static boolean isExternalStorageRemovable(File path) {
        return false;
    }

    /**
     * 取（并在首次访问时创建）webhtv-dex 下的子目录。
     * mkdirs 放在访问路径上而不是静态块里：只有真正被用到的目录才会落盘。
     */
    private static File dir(String name) {
        File target = new File(BASE_DIR, name);
        if (CREATED.add(target.getAbsolutePath())) {
            if (!target.isDirectory() && !target.mkdirs() && !target.isDirectory()) {
                // 禁止 System.out：垫片所有告警走 stderr，避免污染宿主的 stdout 协议管道。
                System.err.println("[android-shim] Environment: 无法创建目录 " + target);
            }
        }
        return target;
    }
}
