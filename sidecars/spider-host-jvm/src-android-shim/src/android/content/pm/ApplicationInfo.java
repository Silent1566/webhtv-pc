package android.content.pm;

/**
 * android.content.pm.ApplicationInfo 的垫片。
 *
 * <p>字段清单照 javap -classpath &lt;android.jar&gt; android.content.pm.ApplicationInfo
 * （android-36）取真实声明：本类声明了 ApplicationInfo 自身声明的全部 public 实例字段，
 * 外加父类 PackageItemInfo 的 packageName / name / icon / labelRes —— 站源的
 * {@code getApplicationInfo().packageName} 字节码里字段宿主按静态类型记成 ApplicationInfo，
 * JVM 解析时不看声明处、只看宿主类，所以这些字段必须落在本类里。
 *
 * <p>真机签名是 {@code extends PackageItemInfo implements Parcelable}，此处两者都省略：
 * 垫片里不存在 android.content.pm.PackageItemInfo，也不存在 android.os.Parcel；
 * 目标站源只经 Context#getApplicationInfo() 取 packageName 等普通字段，不触发父类/接口成员。
 */
public class ApplicationInfo {

    public String appComponentFactory;
    public String backupAgentName;
    public int category;
    public String className;
    public int compatibleWidthLimitDp;
    public int compileSdkVersion;
    public String compileSdkVersionCodename;
    public String dataDir;
    public int descriptionRes;
    public String deviceProtectedDataDir;
    public boolean enabled;
    public int flags;
    public int largestWidthLimitDp;
    public String manageSpaceActivityName;
    public int minSdkVersion;
    public String nativeLibraryDir;
    public String permission;
    public String processName;
    public String publicSourceDir;
    public int requiresSmallestWidthDp;
    public String[] sharedLibraryFiles;
    public String sourceDir;
    public String[] splitNames;
    public String[] splitPublicSourceDirs;
    public String[] splitSourceDirs;
    public java.util.UUID storageUuid;
    public int targetSdkVersion;
    public String taskAffinity;
    public int theme;
    public int uiOptions;
    public int uid;

    // 以下四项真机继承自 PackageItemInfo，见类注释。
    public String packageName;
    public String name;
    public int icon;
    public int labelRes;

    public ApplicationInfo() {
    }

    @Override
    public String toString() {
        return "ApplicationInfo{packageName=" + packageName + ", name=" + name
                + ", sourceDir=" + sourceDir + ", uid=" + uid + "}";
    }
}
