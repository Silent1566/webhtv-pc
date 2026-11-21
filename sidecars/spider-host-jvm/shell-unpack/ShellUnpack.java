import com.github.unidbg.AndroidEmulator;
import com.github.unidbg.arm.backend.Backend;
import com.github.unidbg.arm.backend.CodeHook;
import com.github.unidbg.arm.backend.UnHook;
import com.github.unidbg.arm.context.RegisterContext;
import com.github.unidbg.linux.android.AndroidEmulatorBuilder;
import com.github.unidbg.linux.android.AndroidResolver;
import com.github.unidbg.linux.android.dvm.AbstractJni;
import com.github.unidbg.linux.android.dvm.BaseVM;
import com.github.unidbg.linux.android.dvm.DalvikModule;
import com.github.unidbg.linux.android.dvm.DvmClass;
import com.github.unidbg.linux.android.dvm.DvmMethod;
import com.github.unidbg.linux.android.dvm.DvmObject;
import com.github.unidbg.linux.android.dvm.StringObject;
import com.github.unidbg.linux.android.dvm.VM;
import com.github.unidbg.linux.android.dvm.VarArg;
import com.github.unidbg.memory.Memory;
import com.github.unidbg.pointer.UnidbgPointer;

import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileDescriptor;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.FilterOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.io.PrintStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.security.MessageDigest;
import java.util.ArrayList;
import java.util.Collections;
import java.util.Enumeration;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Set;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.zip.ZipEntry;
import java.util.zip.ZipFile;
import java.util.zip.ZipInputStream;

/**
 * 把 wex/shinidie 加固壳 jar 解成普通 payload jar。
 *
 * <p>之所以是「单文件源码模式」：unidbg（约 40MB 运行时）是用户机器上按需下载的第三方包，
 * 不入库、构建不联网，所以本解包器不能在编译期依赖 unidbg——由 JDK 源码启动器在运行期
 * 用上层给的 -cp 编译并运行本文件。
 *
 * <p>stdout 只有一行 JSON（Dart 侧按此解析），stderr 是人类日志，退出码 0 成功 / 1 失败。
 *
 * <p>阶段进度另走 stderr 的固定行 `[progress] &lt;stageIndex&gt;/7 &lt;stage&gt;`：行首就是标记，
 * 纯 ASCII、不加 JSON，这样 Dart 侧能边读边把「进度」和「人类日志」分开——两条流若共用
 * stdout，那唯一一行 JSON 的契约会被进度挤坏。
 */
public class ShellUnpack {

    static final String RECIPE = "wex-shinidie";

    /** JNIEnv 函数表里 RegisterNatives 的下标（unidbg 的 DalvikVM 自带同样的布局）。 */
    static final int JNI_SLOT_REGISTER_NATIVES = 215;

    /** 缺一个就说明 native 没按 wex/shinidie 的约定注册，后面调 getLoader 只会得到一个空壳失败。 */
    static final List<String> REQUIRED_NATIVES = List.of("proxyInvoke", "getSpider", "getLoader");

    static final String GET_LOADER = "getLoader(Ljava/lang/Object;)Ljava/lang/Object;";
    static final String PAYLOAD_FILE_NAME = "config.db";

    /**
     * 七个阶段的名字与顺序（顺序即进度顺序）。
     *
     * <p>把词表固化在这里的理由：这些词既是 stderr 进度行里的字段，又是失败 JSON 的
     * stage 取值，Dart 侧的文案与单测都按它们对齐——改名等于改契约。
     */
    static final List<String> STAGES = List.of(
            "shell-读取", "recipe-识别", "emulator-启动", "native-注册", "解包-调用", "payload-校验", "payload-落盘");

    /**
     * 往 stderr 打一行阶段进度标记（进入某阶段时调一次）。
     *
     * <p>格式之所以是「固定 ASCII 前缀 + 序号 + 阶段名」而不是 JSON：stdout 是「恰好
     * 一行 JSON」的进程契约，进度绝不能混进去；而 stderr 上机器行与人类日志混排，
     * 只有行首标记能让 Dart 侧一眼分开两者。
     */
    static void progress(String stage) {
        int index = STAGES.indexOf(stage);
        if (index < 0) {
            // 未登记的阶段名只可能是本文件写错字：宁缺一行进度，也不发一个 Dart 认不出的编号。
            return;
        }
        System.err.println("[progress] " + index + "/" + STAGES.size() + " " + stage);
    }

    public static void main(String[] argv) {
        // unidbg/slf4j 会往 stdout 说闲话，而 stdout 是给 Dart 的进程契约：把默认 stdout 转给 stderr，
        // 另存 fd1 给那唯一一行 JSON。
        PrintStream json = new PrintStream(new FileOutputStream(FileDescriptor.out), true, StandardCharsets.UTF_8);
        System.setOut(new PrintStream(new FileOutputStream(FileDescriptor.err), true, StandardCharsets.UTF_8));
        // stderr 也钉死 UTF-8：Windows 中文机器的默认编码是 GBK，而阶段名与失败信息都是中文，
        // 让 Dart 侧按 UTF-8 逐行解码时撞上非法字节，进度就会被整段丢掉。
        System.setErr(new PrintStream(new FileOutputStream(FileDescriptor.err), true, StandardCharsets.UTF_8));
        int exitCode = new Cli(json).run(argv);
        json.flush();
        System.exit(exitCode);
    }

    static void log(String message) {
        System.err.println("[shell-unpack] " + message);
    }

    /** 带阶段名的失败：阶段的取值是进程契约的一部分，写错就等于让 Dart 无法归类。 */
    static final class UnpackFailure extends RuntimeException {
        final String stage;

        UnpackFailure(String stage, String message) {
            super(message);
            this.stage = stage;
        }
    }

    static final class Options {
        File shell;
        File out;
        File work;
        int timeoutSeconds = 300;

        static Options parse(String[] argv) {
            Options options = new Options();
            for (int i = 0; i < argv.length; i++) {
                String argument = argv[i];
                switch (argument) {
                    case "--shell" -> options.shell = new File(value(argv, ++i, argument));
                    case "--out" -> options.out = new File(value(argv, ++i, argument));
                    case "--work" -> options.work = new File(value(argv, ++i, argument));
                    case "--timeout" -> options.timeoutSeconds = parseTimeout(value(argv, ++i, argument));
                    default -> throw usage("未知参数: " + argument);
                }
            }
            if (options.shell == null || options.out == null) {
                throw usage("缺少 --shell 或 --out");
            }
            return options;
        }

        private static String value(String[] argv, int index, String flag) {
            if (index >= argv.length) {
                throw usage(flag + " 缺少取值");
            }
            return argv[index];
        }

        private static int parseTimeout(String raw) {
            try {
                int seconds = Integer.parseInt(raw);
                if (seconds > 0) {
                    return seconds;
                }
            } catch (NumberFormatException ignored) {
                // 落到下面的统一用法错误
            }
            throw usage("--timeout 需要正整数秒: " + raw);
        }

        private static UnpackFailure usage(String detail) {
            return new UnpackFailure("shell-读取", detail
                    + "；用法: java -cp \"<unidbg-dir>/*\" ShellUnpack.java --shell <壳jar> --out <payload.jar>"
                    + " [--work <临时目录>] [--timeout <秒>]");
        }
    }

    /** 识别出来的壳资产：配方只认「一个 .guard + 一个能跑的 .so」，多一个就说明不是这个配方。 */
    static final class Recipe {
        final File shell;
        final File guard;
        final String guardName;
        final File nativeLib;
        final File dex;
        final boolean is64Bit;

        Recipe(File shell, File guard, String guardName, File nativeLib, File dex, boolean is64Bit) {
            this.shell = shell;
            this.guard = guard;
            this.guardName = guardName;
            this.nativeLib = nativeLib;
            this.dex = dex;
            this.is64Bit = is64Bit;
        }

        String asset() {
            return "assets/" + guardName;
        }
    }

    /** 读壳 jar 并做配方识别：只碰 zip 和文件头，不启动模拟器。 */
    static final class ShellArchive {

        static Recipe open(File shell, File work) {
            progress("shell-读取");
            if (!shell.isFile()) {
                throw new UnpackFailure("shell-读取", "壳 jar 不存在: " + shell);
            }
            File input = new File(work, "input");
            if (!input.mkdirs() && !input.isDirectory()) {
                throw new UnpackFailure("shell-读取", "无法建立解包输入目录: " + input);
            }
            List<String> guardNames = new ArrayList<>();
            List<String> libNames = new ArrayList<>();
            File guard = null;
            List<File> libs = new ArrayList<>();
            File dex = null;
            try (ZipFile zip = new ZipFile(shell)) {
                Enumeration<? extends ZipEntry> entries = zip.entries();
                List<String> names = new ArrayList<>();
                while (entries.hasMoreElements()) {
                    ZipEntry entry = entries.nextElement();
                    if (!entry.isDirectory()) {
                        names.add(entry.getName());
                    }
                }
                for (String name : names) {
                    if (name.startsWith("assets/") && name.endsWith(".guard")) {
                        guardNames.add(name);
                    } else if (name.startsWith("assets/") && name.endsWith(".so")) {
                        libNames.add(name);
                    }
                }
                if (guardNames.size() == 1) {
                    guard = extract(zip, guardNames.get(0), input);
                }
                if (!libNames.isEmpty()) {
                    for (String name : libNames) {
                        libs.add(extract(zip, name, input));
                    }
                }
                if (names.contains("classes.dex")) {
                    dex = extract(zip, "classes.dex", input);
                }
            } catch (IOException e) {
                throw new UnpackFailure("shell-读取", "壳 jar 不是可读的 zip: " + shell + " (" + e + ")");
            }

            // 读 zip 与认配方在同一段代码里，但「读到条目」和「认得出配方」是两件事：
            // 判定从这一行开始，进度也就从这一行翻页。
            progress("recipe-识别");
            if (guardNames.isEmpty()) {
                throw new UnpackFailure("recipe-识别", "壳内没有 assets/*.guard 加密 payload: " + shell);
            }
            if (guardNames.size() > 1) {
                throw new UnpackFailure("recipe-识别", "壳内有多个 assets/*.guard，无法确定 payload: "
                        + String.join(", ", guardNames));
            }
            if (libs.isEmpty()) {
                throw new UnpackFailure("recipe-识别", "壳内没有 assets/*.so native 解包器: " + shell);
            }

            File chosen = null;
            boolean is64Bit = false;
            List<String> rejected = new ArrayList<>();
            for (File lib : libs) {
                int abi = abi(lib);
                if (abi == 64) {
                    chosen = lib;
                    is64Bit = true;
                    break;
                }
                if (abi == 32 && chosen == null) {
                    chosen = lib;
                    is64Bit = false;
                } else {
                    rejected.add(lib.getName());
                }
            }
            if (chosen == null) {
                throw new UnpackFailure("recipe-识别", "壳内 .so 既不是 ELF64 AArch64 也不是 ELF32 ARM: "
                        + String.join(", ", rejected));
            }
            String guardName = guardNames.get(0).substring("assets/".length());
            log("recipe=" + RECIPE + " asset=assets/" + guardName + " native=" + chosen.getName()
                    + " abi=" + (is64Bit ? "AArch64" : "ARM"));
            return new Recipe(shell, guard, guardName, chosen, dex, is64Bit);
        }

        private static File extract(ZipFile zip, String name, File targetDir) throws IOException {
            File target = new File(targetDir, name.replace('/', '_'));
            try (InputStream in = zip.getInputStream(zip.getEntry(name))) {
                Files.copy(in, target.toPath(), StandardCopyOption.REPLACE_EXISTING);
            }
            return target;
        }

        /** ELF 头里 e_ident[EI_CLASS] 与 e_machine 决定该起 64 位还是 32 位模拟器。 */
        static int abi(File lib) {
            byte[] head = new byte[20];
            try (InputStream in = new FileInputStream(lib)) {
                if (in.readNBytes(head, 0, head.length) < head.length) {
                    return 0;
                }
            } catch (IOException e) {
                return 0;
            }
            if (head[0] != 0x7f || head[1] != 'E' || head[2] != 'L' || head[3] != 'F') {
                return 0;
            }
            boolean is64 = head[4] == 2;
            int machine = (head[18] & 0xff) | ((head[19] & 0xff) << 8);
            if (is64 && machine == 0xB7) {
                return 64;
            }
            if (!is64 && machine == 0x28) {
                return 32;
            }
            return 0;
        }
    }

    /** 一次解包运行：起模拟器、注册 JNI 桥、调 getLoader，然后交出 native 落盘的 payload。 */
    static final class UnpackRun {
        final File payloadFile;
        final byte[] tapped;

        UnpackRun(File payloadFile, byte[] tapped) {
            this.payloadFile = payloadFile;
            this.tapped = tapped;
        }

        static UnpackRun execute(Recipe recipe, File codecache) {
            progress("emulator-启动");
            AndroidEmulator emulator = null;
            try {
                emulator = (recipe.is64Bit
                        ? AndroidEmulatorBuilder.for64Bit()
                        : AndroidEmulatorBuilder.for32Bit()).setProcessName("com.wex.unpack").build();
                Memory memory = emulator.getMemory();
                memory.setLibraryResolver(new AndroidResolver(23));
                VM vm = recipe.dex == null ? emulator.createDalvikVM() : emulator.createDalvikVM(recipe.dex);
                JniBridge bridge = new JniBridge(vm, recipe, codecache);
                vm.setJni(bridge);

                progress("native-注册");
                // 先挂 RegisterNatives 探针再让 JNI_OnLoad 跑，否则注册信息已经被 native 自己消化掉了。
                RegisterNativesProbe probe = RegisterNativesProbe.attach(emulator, vm, recipe.is64Bit);
                DalvikModule module = vm.loadLibrary(recipe.nativeLib, false);
                module.callJNI_OnLoad(emulator);
                List<String> missing = probe.missing();
                if (!missing.isEmpty()) {
                    throw new UnpackFailure("native-注册", "native 未注册方法 " + String.join(", ", missing)
                            + "（已注册: " + String.join(", ", probe.registered()) + "）");
                }

                DvmClass dexNative = vm.resolveClass("com/github/catvod/spider/DexNative");
                DvmObject<?> context = vm.resolveClass("android/content/Context").newObject(null);
                progress("解包-调用");
                try {
                    dexNative.callStaticJniMethodObject(emulator, GET_LOADER, context);
                } catch (Throwable t) {
                    // getLoader 的返回值不是契约的一部分：payload 已经流式落盘，成败由 payload-校验 判。
                    log("getLoader 抛出: " + t);
                }
                File payload = new File(new File(codecache, "sharedb"), PAYLOAD_FILE_NAME);
                return new UnpackRun(payload, bridge.tapped());
            } catch (UnpackFailure failure) {
                throw failure;
            } catch (Throwable t) {
                throw new UnpackFailure("emulator-启动", "unidbg 启动或加载 " + recipe.nativeLib.getName() + " 失败: " + t);
            } finally {
                if (emulator != null) {
                    try {
                        emulator.close();
                    } catch (Throwable t) {
                        log("关闭模拟器失败: " + t);
                    }
                }
            }
        }
    }

    /**
     * JNIEnv 函数表第 215 项（RegisterNatives）的探针。
     *
     * <p>不拦这个调用就只能等 getLoader 失败后回猜 native 做了什么；拦住它才能把
     * 「native 确实注册了 proxyInvoke/getSpider/getLoader」变成可判定的前置条件。
     */
    static final class RegisterNativesProbe {
        private final Set<String> names = Collections.synchronizedSet(new LinkedHashSet<>());

        static RegisterNativesProbe attach(AndroidEmulator emulator, VM vm, boolean is64Bit) {
            RegisterNativesProbe probe = new RegisterNativesProbe();
            long pointerSize = is64Bit ? 8L : 4L;
            try {
                UnidbgPointer env = (UnidbgPointer) vm.getJNIEnv();
                UnidbgPointer table = env.getPointer(0);
                long trampoline = table.share(JNI_SLOT_REGISTER_NATIVES * pointerSize).getLong(0);
                log("RegisterNatives trampoline=0x" + Long.toHexString(trampoline));
                emulator.getBackend().hook_add_new(probe.hook(emulator, pointerSize), trampoline, trampoline, null);
            } catch (UnpackFailure failure) {
                throw failure;
            } catch (Throwable t) {
                throw new UnpackFailure("native-注册", "无法 hook JNIEnv[" + JNI_SLOT_REGISTER_NATIVES + "]: " + t);
            }
            return probe;
        }

        private CodeHook hook(AndroidEmulator emulator, long pointerSize) {
            return new CodeHook() {
                @Override
                public void hook(Backend backend, long address, int size, Object user) {
                    try {
                        RegisterContext context = emulator.getContext();
                        UnidbgPointer methods = context.getPointerArg(2);
                        long count = context.getLongArg(3);
                        if (methods == null || count <= 0 || count > 4096) {
                            return;
                        }
                        for (long i = 0; i < count; i++) {
                            UnidbgPointer entry = (UnidbgPointer) methods.share(i * 3L * pointerSize);
                            UnidbgPointer namePointer = entry.getPointer(0);
                            UnidbgPointer signaturePointer = entry.getPointer(pointerSize);
                            if (namePointer == null) {
                                continue;
                            }
                            String name = namePointer.getString(0, "UTF-8");
                            String signature = signaturePointer == null
                                    ? "?" : signaturePointer.getString(0, "UTF-8");
                            names.add(name);
                            log("RegisterNatives " + name + " " + signature);
                        }
                    } catch (Throwable t) {
                        log("读取 RegisterNatives 参数失败: " + t);
                    }
                }

                @Override
                public void detach() {
                }

                @Override
                public void onAttach(UnHook unHook) {
                }
            };
        }

        Set<String> registered() {
            synchronized (names) {
                return new LinkedHashSet<>(names);
            }
        }

        List<String> missing() {
            List<String> absent = new ArrayList<>();
            for (String required : REQUIRED_NATIVES) {
                if (!names.contains(required)) {
                    absent.add(required);
                }
            }
            return absent;
        }
    }

    /**
     * 假 Android 运行时。native 只认图里的这些调用：Context 的缓存目录 + ClassLoader 资源流，
     * 其余一律回 null 让 native 走它自己的失败分支。
     *
     * <p>三个踩过的坑在这里被固化：
     * <ul>
     *   <li>流对象只能用 java/io/InputStream、java/io/OutputStream 承载——JNI 方法 id 是类作用域的，
     *       换成 FileInputStream/FileOutputStream 会让 CallIntMethod/CallVoidMethod 抛无消息 BackendException。</li>
     *   <li>File.setReadOnly() 必须返回 true，否则 native 会回滚并删掉刚写好的 payload。</li>
     *   <li>返回给 native 的字符串一律走 new StringObject(vm, s)，resolveClass("java/lang/String") 造出来的
     *       普通 DvmObject 会在 GetStringUtfChars 抛 CastException。</li>
     * </ul>
     */
    static final class JniBridge extends AbstractJni {
        private static final String CLASS_LOADER = "stub-classloader";
        private static final String ASSET_MANAGER = "stub-assetmanager";

        private final VM vm;
        private final Recipe recipe;
        private final File codecache;
        private final ByteArrayOutputStream tapped = new ByteArrayOutputStream();

        JniBridge(VM vm, Recipe recipe, File codecache) {
            this.vm = vm;
            this.recipe = recipe;
            this.codecache = codecache;
        }

        byte[] tapped() {
            return tapped.toByteArray();
        }

        private DvmObject<?> object(String className, Object value) {
            DvmClass clazz = vm.resolveClass(className);
            return clazz == null ? null : clazz.newObject(value);
        }

        private DvmObject<?> string(String value) {
            return value == null ? null : new StringObject(vm, value);
        }

        private DvmObject<?> bool(boolean value) {
            return object("java/lang/Boolean", value);
        }

        private DvmObject<?> integer(int value) {
            return object("java/lang/Integer", value);
        }

        @Override
        public DvmObject<?> allocObject(BaseVM baseVM, DvmClass clazz, String signature) {
            return object(clazz.getClassName(), null);
        }

        @Override
        public boolean acceptMethod(DvmClass clazz, String signature, boolean isStatic) {
            return true;
        }

        @Override
        public DvmObject<?> newObject(BaseVM baseVM, DvmClass clazz, DvmMethod method, VarArg args) {
            String className = clazz.getClassName();
            try {
                switch (className) {
                    case "java/io/File":
                        return object("java/io/File", resolvePath(args));
                    case "java/io/FileInputStream":
                        return openInput(argString(args, 0));
                    case "java/io/FileOutputStream":
                        return openOutput(argString(args, 0));
                    case "dalvik/system/DexClassLoader":
                        return object("dalvik/system/DexClassLoader", argString(args, 0));
                    default:
                        return object(className, null);
                }
            } catch (Throwable t) {
                log("构造 " + className + " 失败: " + t);
                return object(className, null);
            }
        }

        @Override
        public DvmObject<?> callObjectMethod(BaseVM baseVM, DvmObject<?> target, DvmMethod method, VarArg args) {
            return invoke(target, method, args);
        }

        @Override
        public int callIntMethod(BaseVM baseVM, DvmObject<?> target, DvmMethod method, VarArg args) {
            Object value = unwrap(invoke(target, method, args));
            return value instanceof Integer number ? number : 0;
        }

        @Override
        public boolean callBooleanMethod(BaseVM baseVM, DvmObject<?> target, DvmMethod method, VarArg args) {
            Object value = unwrap(invoke(target, method, args));
            return value instanceof Boolean flag && flag;
        }

        @Override
        public void callVoidMethod(BaseVM baseVM, DvmObject<?> target, DvmMethod method, VarArg args) {
            invoke(target, method, args);
        }

        @Override
        public DvmObject<?> callStaticObjectMethod(BaseVM baseVM, DvmClass clazz, DvmMethod method, VarArg args) {
            String className = clazz.getClassName();
            String name = method.getMethodName();
            if ("com/github/catvod/spider/Init".equals(className) && "classLoader".equals(name)) {
                return object("java/lang/ClassLoader", CLASS_LOADER);
            }
            if ("java/lang/ClassLoader".equals(className) && "getSystemClassLoader".equals(name)) {
                return object("java/lang/ClassLoader", CLASS_LOADER);
            }
            return null;
        }

        private DvmObject<?> invoke(DvmObject<?> target, DvmMethod method, VarArg args) {
            String className = target == null ? "" : target.getObjectType().getClassName();
            Object value = unwrap(target);
            String name = method.getMethodName();
            try {
                if (value instanceof InputStream in && "java/io/InputStream".equals(className)) {
                    return onInputStream(in, name, method.getArgs(), args);
                }
                if (value instanceof OutputStream out && "java/io/OutputStream".equals(className)) {
                    return onOutputStream(out, name, method.getArgs(), args);
                }
                if (value instanceof String path && "java/io/File".equals(className)) {
                    return onFile(path, name);
                }
                switch (className) {
                    case "android/content/Context":
                        return onContext(name);
                    case "java/lang/ClassLoader":
                        return onClassLoader(name, args);
                    case "dalvik/system/DexClassLoader":
                        log("DexClassLoader." + name);
                        return null;
                    default:
                        return null;
                }
            } catch (Throwable t) {
                log("桥接 " + className + "." + name + " 失败: " + t);
                return null;
            }
        }

        private DvmObject<?> onFile(String path, String name) throws IOException {
            File file = new File(path);
            return switch (name) {
                case "exists" -> bool(file.exists());
                case "isFile" -> bool(file.isFile());
                case "isDirectory" -> bool(file.isDirectory());
                case "canRead", "canWrite" -> bool(true);
                case "length" -> object("java/lang/Long", file.length());
                case "mkdirs", "mkdir" -> bool(file.mkdirs() || file.isDirectory());
                case "createNewFile" -> bool(file.createNewFile());
                case "getAbsolutePath", "getPath", "toString" -> string(file.getAbsolutePath());
                case "getName" -> string(file.getName());
                case "getParent" -> string(file.getParent());
                case "getParentFile" -> object("java/io/File", file.getParent());
                // native 在 setReadOnly 返回 false 时会回滚并删掉刚写好的 payload。
                case "setReadOnly", "setWritable", "setReadable", "setExecutable" -> bool(true);
                // 回滚分支就在 payload 上做，跟着删就等于自毁交付物。
                case "delete" -> bool(false);
                case "deleteOnExit" -> null;
                default -> null;
            };
        }

        private DvmObject<?> onInputStream(InputStream in, String name, String signature, VarArg args)
                throws IOException {
            return switch (name) {
                case "read" -> integer(signature.contains("[B") ? in.read((byte[]) argValue(args, 0)) : in.read());
                case "available" -> integer(in.available());
                case "close" -> {
                    in.close();
                    yield null;
                }
                default -> null;
            };
        }

        private DvmObject<?> onOutputStream(OutputStream out, String name, String signature, VarArg args)
                throws IOException {
            switch (name) {
                case "write" -> {
                    byte[] buffer = (byte[]) argValue(args, 0);
                    if (buffer == null) {
                        return null;
                    }
                    boolean ranged = signature.contains("[BII");
                    out.write(buffer, ranged ? args.getIntArg(1) : 0, ranged ? args.getIntArg(2) : buffer.length);
                    return null;
                }
                case "flush" -> {
                    out.flush();
                    return null;
                }
                case "close" -> {
                    out.close();
                    return null;
                }
                default -> {
                    return null;
                }
            }
        }

        private DvmObject<?> onContext(String name) {
            return switch (name) {
                case "getClassLoader" -> object("java/lang/ClassLoader", CLASS_LOADER);
                case "getCodeCacheDir" -> object("java/io/File", codecache.getAbsolutePath());
                case "getCacheDir", "getFilesDir" -> object("java/io/File", codecache.getAbsolutePath());
                case "getPackageCodePath", "getPackageResourcePath" -> string(recipe.shell.getAbsolutePath());
                case "getAssets" -> object("android/content/res/AssetManager", ASSET_MANAGER);
                default -> null;
            };
        }

        private DvmObject<?> onClassLoader(String name, VarArg args) throws IOException {
            if (!"getResourceAsStream".equals(name)) {
                return null;
            }
            String resource = argString(args, 0);
            log("ClassLoader.getResourceAsStream(" + resource + ")");
            if (resource == null) {
                return null;
            }
            String normalized = resource.startsWith("/") ? resource.substring(1) : resource;
            if (!normalized.equals(recipe.asset()) && !normalized.equals(recipe.guardName)) {
                return null;
            }
            return object("java/io/InputStream", new FileInputStream(recipe.guard));
        }

        private DvmObject<?> openInput(String path) {
            try {
                return object("java/io/InputStream", new FileInputStream(new File(path)));
            } catch (Throwable t) {
                log("打开输入流失败 " + path + ": " + t);
                return object("java/io/InputStream", null);
            }
        }

        private DvmObject<?> openOutput(String path) {
            try {
                File file = new File(path);
                if (file.getParentFile() != null) {
                    file.getParentFile().mkdirs();
                }
                OutputStream out = new FileOutputStream(file);
                if (PAYLOAD_FILE_NAME.equals(file.getName())) {
                    out = new Tap(out, tapped);
                }
                return object("java/io/OutputStream", out);
            } catch (Throwable t) {
                log("打开输出流失败 " + path + ": " + t);
                return object("java/io/OutputStream", null);
            }
        }

        private String resolvePath(VarArg args) {
            String parent = argString(args, 0);
            String child = argString(args, 1);
            if (child == null || child.isEmpty()) {
                return parent == null ? "" : parent;
            }
            return new File(new File(parent), child).getPath();
        }

        private static Object unwrap(DvmObject<?> object) {
            return object == null ? null : object.getValue();
        }

        private static Object argValue(VarArg args, int index) {
            try {
                return unwrap(args.getObjectArg(index));
            } catch (Throwable t) {
                return null;
            }
        }

        private static String argString(VarArg args, int index) {
            Object value = argValue(args, index);
            return value == null ? null : String.valueOf(value);
        }

        /** 边写 config.db 边留一份内存副本：native 的失败回滚会删文件，但删不掉这份。 */
        static final class Tap extends FilterOutputStream {
            private final ByteArrayOutputStream sink;

            Tap(OutputStream out, ByteArrayOutputStream sink) {
                super(out);
                this.sink = sink;
            }

            @Override
            public void write(int b) throws IOException {
                out.write(b);
                sink.write(b);
            }

            @Override
            public void write(byte[] buffer, int offset, int length) throws IOException {
                out.write(buffer, offset, length);
                sink.write(buffer, offset, length);
            }
        }
    }

    /** payload 校验与落盘：先验 PK/classes.dex，再算 sha256，最后 .part 改名，失败绝不留下 --out。 */
    static final class Payload {
        final byte[] bytes;
        final String sha256;

        Payload(byte[] bytes, String sha256) {
            this.bytes = bytes;
            this.sha256 = sha256;
        }

        static Payload read(UnpackRun run) {
            List<String> sources = new ArrayList<>();
            List<byte[]> candidates = new ArrayList<>();
            if (run.payloadFile.isFile() && run.payloadFile.length() > 0) {
                sources.add(run.payloadFile.getAbsolutePath());
                candidates.add(readAll(run.payloadFile));
            }
            if (run.tapped != null && run.tapped.length > 0) {
                sources.add("native 写入流副本");
                candidates.add(run.tapped);
            }
            if (candidates.isEmpty()) {
                throw new UnpackFailure("payload-校验",
                        "native 没有产出 payload: " + run.payloadFile + " 不存在且没有捕获到写入");
            }
            String firstProblem = null;
            for (int i = 0; i < candidates.size(); i++) {
                byte[] candidate = candidates.get(i);
                String problem = describe(candidate);
                if (problem == null) {
                    Payload payload = new Payload(candidate, sha256(candidate));
                    log("payload 来源=" + sources.get(i) + " bytes=" + candidate.length + " sha256=" + payload.sha256);
                    return payload;
                }
                if (firstProblem == null) {
                    firstProblem = sources.get(i) + " -> " + problem;
                }
            }
            throw new UnpackFailure("payload-校验", firstProblem);
        }

        /** @return null 表示通过，否则是给报错用的一行说明 */
        private static String describe(byte[] bytes) {
            String magic = hex(bytes, 4);
            if (bytes.length < 4 || (bytes[0] & 0xff) != 0x50 || (bytes[1] & 0xff) != 0x4b
                    || (bytes[2] & 0xff) != 0x03 || (bytes[3] & 0xff) != 0x04) {
                return "payload 不是 zip: magic=" + magic + " bytes=" + bytes.length;
            }
            try (ZipInputStream zip = new ZipInputStream(new ByteArrayInputStream(bytes))) {
                ZipEntry entry;
                while ((entry = zip.getNextEntry()) != null) {
                    if ("classes.dex".equals(entry.getName())) {
                        return null;
                    }
                }
            } catch (IOException e) {
                return "payload zip 读不动: magic=" + magic + " bytes=" + bytes.length + " (" + e + ")";
            }
            return "payload zip 缺少 classes.dex: magic=" + magic + " bytes=" + bytes.length;
        }

        static void write(File out, byte[] bytes) {
            File part = new File(out.getParentFile() == null ? new File(".") : out.getParentFile(),
                    out.getName() + ".part");
            try {
                File parent = part.getParentFile();
                if (parent != null) {
                    Files.createDirectories(parent.toPath());
                }
                Files.write(part.toPath(), bytes);
                try {
                    Files.move(part.toPath(), out.toPath(),
                            StandardCopyOption.REPLACE_EXISTING, StandardCopyOption.ATOMIC_MOVE);
                } catch (IOException atomicFailed) {
                    Files.move(part.toPath(), out.toPath(), StandardCopyOption.REPLACE_EXISTING);
                }
            } catch (IOException e) {
                deleteQuietly(part);
                throw new UnpackFailure("payload-落盘", "写入 " + out + " 失败: " + e);
            }
        }

        private static byte[] readAll(File file) {
            try {
                return Files.readAllBytes(file.toPath());
            } catch (IOException e) {
                throw new UnpackFailure("payload-校验", "读取 " + file + " 失败: " + e);
            }
        }

        private static String sha256(byte[] bytes) {
            try {
                MessageDigest digest = MessageDigest.getInstance("SHA-256");
                return hex(digest.digest(bytes), bytes.length);
            } catch (Exception e) {
                throw new UnpackFailure("payload-校验", "计算 sha256 失败: " + e);
            }
        }
    }

    static String hex(byte[] bytes, int limit) {
        StringBuilder builder = new StringBuilder();
        for (int i = 0; i < Math.min(limit, bytes.length); i++) {
            builder.append(String.format("%02x", bytes[i]));
        }
        return builder.toString();
    }

    static void deleteQuietly(File file) {
        try {
            Files.deleteIfExists(file.toPath());
        } catch (IOException ignored) {
            // 清理是尽力而为，不影响进程契约
        }
    }

    static final class WorkDir {
        static File create() {
            try {
                return Files.createTempDirectory("shell-unpack-").toFile();
            } catch (IOException e) {
                throw new UnpackFailure("shell-读取", "无法建立临时目录: " + e);
            }
        }

        static void delete(File dir) {
            if (dir == null || !dir.exists()) {
                return;
            }
            try (var paths = Files.walk(dir.toPath())) {
                paths.sorted((left, right) -> right.getNameCount() - left.getNameCount())
                        .forEach(path -> deleteQuietly(path.toFile()));
            } catch (IOException ignored) {
                // 同上：尽力清理
            }
        }
    }

    /** 一次性 JSON 行：进程契约只给一行 stdout，所以发过就不再发。 */
    static final class Json {
        static String ok(String payload, String sha256, long bytes, String asset, long elapsedMs) {
            return "{\"ok\":true,\"payload\":\"" + escape(payload) + "\",\"sha256\":\"" + sha256
                    + "\",\"bytes\":" + bytes + ",\"recipe\":\"" + RECIPE + "\",\"asset\":\"" + escape(asset)
                    + "\",\"elapsedMs\":" + elapsedMs + "}";
        }

        static String fail(String stage, String message) {
            return "{\"ok\":false,\"stage\":\"" + escape(stage) + "\",\"message\":\"" + escape(message) + "\"}";
        }

        static String escape(String raw) {
            if (raw == null) {
                return "";
            }
            StringBuilder builder = new StringBuilder(raw.length() + 8);
            for (int i = 0; i < raw.length(); i++) {
                char c = raw.charAt(i);
                switch (c) {
                    case '"' -> builder.append("\\\"");
                    case '\\' -> builder.append("\\\\");
                    case '\n' -> builder.append("\\n");
                    case '\r' -> builder.append("\\r");
                    case '\t' -> builder.append("\\t");
                    default -> {
                        if (c < 0x20) {
                            builder.append(String.format("\\u%04x", (int) c));
                        } else {
                            builder.append(c);
                        }
                    }
                }
            }
            return builder.toString();
        }
    }

    /**
     * 超时看门狗。unidbg 里的 native 死循环没有任何协作式中断点，只能由外部线程兜底
     * 把那唯一一行 JSON 发出去再硬停。
     */
    static final class Watchdog {
        private volatile boolean cancelled;

        static Watchdog arm(PrintStream json, AtomicBoolean emitted, int timeoutSeconds, File work) {
            Watchdog watchdog = new Watchdog();
            Thread thread = new Thread(() -> {
                try {
                    Thread.sleep(timeoutSeconds * 1000L);
                } catch (InterruptedException e) {
                    return;
                }
                if (watchdog.cancelled) {
                    return;
                }
                if (emitted.compareAndSet(false, true)) {
                    json.println(Json.fail("解包-调用", "超时 " + timeoutSeconds + " 秒未完成解包"));
                    json.flush();
                }
                WorkDir.delete(work);
                Runtime.getRuntime().halt(1);
            }, "shell-unpack-watchdog");
            thread.setDaemon(true);
            thread.start();
            return watchdog;
        }

        void cancel() {
            cancelled = true;
        }
    }

    /** 编排：解析参数 → 识别配方 → 解包 → 校验 → 落盘，任何一步失败都只发一行失败 JSON。 */
    static final class Cli {
        private final PrintStream json;
        private final AtomicBoolean emitted = new AtomicBoolean();
        private String stage = "shell-读取";

        Cli(PrintStream json) {
            this.json = json;
        }

        int run(String[] argv) {
            long startedAt = System.nanoTime();
            File work = null;
            boolean ownedWork = false;
            Watchdog watchdog = null;
            try {
                Options options = Options.parse(argv);
                if (options.work != null) {
                    work = options.work.getAbsoluteFile();
                    if (!work.mkdirs() && !work.isDirectory()) {
                        throw new UnpackFailure("shell-读取", "无法建立工作目录: " + work);
                    }
                } else {
                    work = WorkDir.create();
                    ownedWork = true;
                }
                File codecache = new File(work, "codecache");
                if (!codecache.mkdirs() && !codecache.isDirectory()) {
                    throw new UnpackFailure("recipe-识别", "无法建立 codecache 目录: " + codecache);
                }
                watchdog = Watchdog.arm(json, emitted, options.timeoutSeconds, work);

                Recipe recipe = ShellArchive.open(options.shell.getAbsoluteFile(), work);
                stage = "emulator-启动";
                UnpackRun run = UnpackRun.execute(recipe, codecache);
                stage = "payload-校验";
                progress("payload-校验");
                Payload payload = Payload.read(run);
                stage = "payload-落盘";
                progress("payload-落盘");
                File out = options.out.getAbsoluteFile();
                Payload.write(out, payload.bytes);
                long elapsedMs = (System.nanoTime() - startedAt) / 1_000_000L;
                emit(Json.ok(out.getAbsolutePath(), payload.sha256, payload.bytes.length, recipe.asset(), elapsedMs));
                log("payload 落盘 " + out.getAbsolutePath() + " (" + payload.bytes.length + " B, " + elapsedMs + " ms)");
                return 0;
            } catch (UnpackFailure failure) {
                emit(Json.fail(failure.stage, failure.getMessage()));
                return 1;
            } catch (Throwable t) {
                emit(Json.fail(stage, t.getClass().getSimpleName()
                        + (t.getMessage() == null ? "" : ": " + t.getMessage())));
                return 1;
            } finally {
                if (watchdog != null) {
                    watchdog.cancel();
                }
                if (ownedWork) {
                    WorkDir.delete(work);
                }
            }
        }

        private void emit(String line) {
            if (emitted.compareAndSet(false, true)) {
                json.println(line);
                json.flush();
            }
        }
    }
}
