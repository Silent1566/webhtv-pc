package webhtv.spider;

import java.io.IOException;
import java.io.InputStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.Deque;
import java.util.Enumeration;
import java.util.HashMap;
import java.util.HashSet;
import java.util.IdentityHashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.zip.ZipEntry;
import java.util.zip.ZipFile;
import java.util.zip.ZipOutputStream;

import com.googlecode.d2j.Method;
import com.googlecode.d2j.reader.DexFileReader;
import com.googlecode.d2j.reader.Op;
import com.googlecode.d2j.visitors.DexClassVisitor;
import com.googlecode.d2j.visitors.DexCodeVisitor;
import com.googlecode.d2j.visitors.DexFileVisitor;
import com.googlecode.d2j.visitors.DexMethodVisitor;

import org.objectweb.asm.ClassReader;
import org.objectweb.asm.ClassWriter;
import org.objectweb.asm.Opcodes;
import org.objectweb.asm.tree.AbstractInsnNode;
import org.objectweb.asm.tree.ClassNode;
import org.objectweb.asm.tree.InsnList;
import org.objectweb.asm.tree.InsnNode;
import org.objectweb.asm.tree.LdcInsnNode;
import org.objectweb.asm.tree.MethodInsnNode;
import org.objectweb.asm.tree.MethodNode;
import org.objectweb.asm.tree.TypeInsnNode;
import org.objectweb.asm.tree.FieldInsnNode;
import org.objectweb.asm.tree.analysis.Analyzer;
import org.objectweb.asm.tree.analysis.AnalyzerException;
import org.objectweb.asm.tree.analysis.Frame;
import org.objectweb.asm.tree.analysis.SourceInterpreter;
import org.objectweb.asm.tree.analysis.SourceValue;

/**
 * dex2jar 2.4.28 产物的**语义**修复（帧修复之后、落盘之前）。
 *
 * <p>帧修复只解决「字节码能过校验器」，解决不了「语义被译错」。混淆过的 dex 有三类已知误译：
 *
 * <ol>
 *   <li><b>{@code new} 抽象类</b>：dex 的 {@code new-instance Lf;}（f 是抽象类 g 的具体子类）被译成
 *       {@code NEW g}——dex2jar 用了构造器的声明类，而不是 new-instance 自己的类型。后果是
 *       {@code InstantiationError: g}，且只有真正走到那条 {@code new} 时才炸；</li>
 *   <li><b>伪 abstract 类</b>：dex 里是具体类，产物却把类和它的方法标成 {@code abstract}，
 *       同样表现为 {@code InstantiationError}；</li>
 *   <li><b>自递归 {@code invokespecial}</b>：dex 的 {@code invoke-super} 被译成「{@code invokespecial}
 *       指向本类同一个方法」，即无限递归。</li>
 * </ol>
 *
 * <p>三类修复都**只按原始 dex 的事实**动手，依据缺失时保持原样并记一条原因：
 *
 * <ul>
 *   <li>{@code new} 改类型时，每处差异都必须是**收窄**：产物类型是 dex 类型的祖先，dex 类型具体。
 *       误译机制始终是 dex2jar 拿**构造器的声明类**当 {@code new-instance} 的类型，而声明类必是
 *       真实类型的祖先，因此这一条覆盖了全部实测形态（抽象父类、{@code java/lang/Object}、以及
 *       {@code ThreadLocal} 这种继承了构造器的普通父类），既不是放宽猜测，也不允许反向或无关替换。
 *       收窄对任何消费方都仍类型安全。对位保留既有下标档，失败后才用描述符链档：
 *       <ol>
 *         <li><b>下标档</b>：dex 的 {@code new-instance} 序列与产物的 {@code NEW} 序列逐条同序且差异均为收窄；</li>
 *         <li><b>描述符链档</b>：dex2jar 会重排指令，序号不可信时改用「每个 {@code NEW} 各自
 *             配到的构造器描述符」当指纹（两侧多重集必须一致，且配对必须唯一）。
 *             只修「收窄」这一种差异的机制不变——换档只是换了对位方式，不是放宽判据。</li>
 *       </ol>
 *       对不上、不唯一或形态不符都整条方法不动；</li>
 *   <li>伪 abstract 类只在 dex 说该类非抽象时才清 abstract，且只给「dex 里确有实现」的方法补桩体，
 *       桩体一律 {@code throw new UnsupportedOperationException(...)}，绝不返回默认值——把
 *       「编译失败」变成「静默跑错」是这里最不能犯的错；</li>
 *   <li>重定向 {@code invokespecial} 只在父类确实声明了同名同描述符方法时才做（父类在 dex 之外，
 *       如 {@code android.*}，一律不动）。</li>
 * </ul>
 */
public final class DexRepair {
    private DexRepair() {}

    /**
     * 修复口径的版本号。产物内容会随修复规则变化，因此把它写进 {@code intake-dex.json}：
     * 版本不一致说明缓存是旧规则生成的，必须重新转译（否则修复永远跑不到真实 payload 上）。
     */
    public static final int VERSION = 6;

    /**
     * 2：{@code NEW} 重定位从「抽象父类 → 具体子类」放宽为「dex 类型是产物类型的子类且具体」，
     * 并把方法筛选从「NEW 类型可疑」改成「有 NEW」——否则 {@code NEW java/lang/Object}、
     * {@code NEW java/lang/ThreadLocal} 这类同样来自构造器声明类的误译会被筛掉。
     *
     * <p>3：新增「描述符链对位」档。下标对位在 dex2jar 重排过指令的方法上会配错（实测
     * {@code z3/o.a(C)V}：dex 的 new-instance 顺序是 a,r,a,r…，产物的 NEW 顺序是 r,a,r,a…，
     * 逐条对位把 NEW {@code z3/c} 和 dex 的 {@code z3/r} 配到一起，整条方法只能原样保留，
     * 运行期炸 {@code InstantiationError: z3/c}）。构造器描述符两侧一致，用它当指纹可以唯一
     * 重新配对；判据仍是「收窄」，只是不再要求序号同序。
     *
     * <p>4：接口方法的 {@code invoke-static} / {@code invoke-special} 被译成普通 {@code Methodref}
     * 时，按「owner 确是接口」改回 {@code InterfaceMethodref}——否则 JVM 解析即抛
     * {@code IncompatibleClassChangeError: … must be InterfaceMethodref constant}（实测
     * AnimeAiGongHeGuo 的 {@code Comparator.comparing}）。
     *
     * <p>5：只扩展下标档失败后的描述符链档：混合类型组也可在完整匹配的目标类型唯一时修复。
     */

    /**
     * 报告里最多保留多少条记录：记录是给人看的诊断，不是数据通道，超出只留一条截断说明。
     *
     * <p>从 200 提到 1000：真实 payload（wex 加固壳）一次修复就产出 600 多条记录（几百条 NEW 重定位
     * 加两百多条「为什么没修」），200 条会把「跳过原因」这类**更该被看见**的记录挤掉——第一轮实测
     * {@code z3/o.a(C)V} 的跳过原因就是这么被截断掉的，排查时等于没有。
     */
    static final int RECORD_LIMIT = 1000;

    private static final String THROWABLE = "java/lang/UnsupportedOperationException";


    /** 继承链回溯的深度上限：畸形 super 链会让循环不终止，宁可按「不是子类」处理。 */
    private static final int SUPER_CHAIN_LIMIT = 64;
    private static final int ALIGNMENT_GROUP_LIMIT = 256;

    /**
     * 修复结果。
     *
     * @param repairedClasses 字节码被改动过的类数（任何一类修复命中即计一次）
     * @param stubbedMethods 补了「显式失败」桩体的方法数
     * @param retargetedCalls 重定向到父类的 {@code invokespecial} 数
     * @param retypedInstantiations 改成 dex 真实类型的 {@code NEW} 数
     * @param records 逐条修复/跳过原因，供宿主如实上报
     */
    public record Report(
            int repairedClasses,
            int stubbedMethods,
            int retargetedCalls,
            int retypedInstantiations,
            List<String> records) {}

    /**
     * 读 {@code rawJar}（已做过帧修复的产物）里的每个 class，按 dex 事实修正后写入 {@code outJar}。
     *
     * <p>未命中的条目按原字节照抄，因此即使一条修复都没发生，产物也与输入等价。
     *
     * @param dex 原始 {@code classes.dex} 字节：修复的唯一事实来源
     */
    public static Report repair(Path rawJar, Path outJar, byte[] dex) throws DexIntake.DexIntakeException {
        Map<String, DexClass> index;
        Map<String, List<DexNewSite>> dexNewInstances;
        try {
            index = indexDex(dex);
            // 只有「可能被译错的 NEW」所在的方法才需要读 dex 指令：1193 个类全读一遍指令要多花几秒，
            // 而绝大多数方法里根本没有 NEW。
            dexNewInstances = indexNewInstances(dex, methodsWithNew(rawJar));
        } catch (IOException error) {
            throw new DexIntake.DexIntakeException(
                    DexIntake.STAGE_REPAIR, "读取 " + rawJar + " 失败：" + error, error);
        } catch (RuntimeException error) {
            throw new DexIntake.DexIntakeException(
                    DexIntake.STAGE_REPAIR, "建立 dex 索引失败：" + error, error);
        }

        List<String> records = new ArrayList<>();
        int repairedClasses = 0;
        int stubbedMethods = 0;
        int retargetedCalls = 0;
        int retypedInstantiations = 0;
        int missing = 0;
        int failed = 0;
        try (ZipFile in = new ZipFile(rawJar.toFile());
                ZipOutputStream out = new ZipOutputStream(Files.newOutputStream(outJar))) {
            Enumeration<? extends ZipEntry> entries = in.entries();
            while (entries.hasMoreElements()) {
                ZipEntry entry = entries.nextElement();
                if (entry.isDirectory()) {
                    continue;
                }
                byte[] data = readEntry(in, entry);
                if (entry.getName().endsWith(".class")) {
                    try {
                        Outcome outcome = repairClass(data, index, dexNewInstances, records);
                        data = outcome.bytes();
                        if (outcome.missing()) {
                            missing++;
                        }
                        if (outcome.touched()) {
                            repairedClasses++;
                        }
                        stubbedMethods += outcome.stubbed();
                        retargetedCalls += outcome.retargeted();
                        retypedInstantiations += outcome.retyped();
                    } catch (Throwable error) {
                        // 单类失败不中断：原样保留，由调用方从 records 里看到哪些类没修。
                        failed++;
                        note(records, "修复失败 " + entry.getName() + "（" + error + "），原样保留");
                    }
                }
                ZipEntry copy = new ZipEntry(entry.getName());
                if (entry.getTime() >= 0) {
                    copy.setTime(entry.getTime());
                }
                out.putNextEntry(copy);
                out.write(data);
                out.closeEntry();
            }
        } catch (IOException error) {
            throw new DexIntake.DexIntakeException(
                    DexIntake.STAGE_REPAIR, "修复 " + rawJar + " 失败：" + error, error);
        }
        if (missing > 0) {
            note(records, "产物里有 " + missing + " 个类在 dex 中找不到，已跳过（名字对不上时不猜）");
        }
        if (failed > 0) {
            note(records, "有 " + failed + " 个类修复失败，原样保留");
        }
        Ipc.log(DexIntake.STAGE_REPAIR + ": repairedClasses=" + repairedClasses
                + " stubbedMethods=" + stubbedMethods
                + " retargetedCalls=" + retargetedCalls
                + " retypedInstantiations=" + retypedInstantiations
                + " records=" + records.size());
        return new Report(repairedClasses, stubbedMethods, retargetedCalls, retypedInstantiations,
                List.copyOf(records));
    }

    // ---------------------------------------------------------------- dex 索引

    /** 一个 dex 类的**事实**：访问标志、父类、每个方法的访问标志（据此判断是否有实现）。 */
    private static final class DexClass {
        final int access;
        final String superName;
        final Map<String, Integer> methods = new HashMap<>();

        DexClass(int access, String superName) {
            this.access = access;
            this.superName = superName;
        }
    }

    /**
     * 只读 dex 的类/方法声明，不读指令体：判断「抽象与否」「有没有实现」靠访问标志就够。
     */
    private static Map<String, DexClass> indexDex(byte[] dex) {
        Map<String, DexClass> classes = new HashMap<>(2048);
        // KEEP_ALL_METHODS / KEEP_CLINIT：d2j 默认会跳过部分方法，而这里要的是「dex 里到底有没有
        // 这个方法」的完整事实，漏掉一个就会被误判成「dex 无此方法」。
        int flags = DexFileReader.SKIP_CODE
                | DexFileReader.SKIP_DEBUG
                | DexFileReader.SKIP_ANNOTATION
                | DexFileReader.KEEP_ALL_METHODS
                | DexFileReader.KEEP_CLINIT;
        new DexFileReader(dex).accept(new IndexFileVisitor(classes), flags);
        return classes;
    }

    private static final class IndexFileVisitor extends DexFileVisitor {
        private final Map<String, DexClass> classes;

        IndexFileVisitor(Map<String, DexClass> classes) {
            this.classes = classes;
        }

        @Override
        public DexClassVisitor visit(int access, String className, String superName, String[] interfaceNames) {
            DexClass info = new DexClass(access, internal(superName));
            classes.put(internal(className), info);
            return new IndexClassVisitor(info);
        }
    }

    private static final class IndexClassVisitor extends DexClassVisitor {
        private final DexClass info;

        IndexClassVisitor(DexClass info) {
            this.info = info;
        }

        @Override
        public DexMethodVisitor visitMethod(int access, Method method) {
            info.methods.put(key(method.getName(), method.getDesc()), access);
            // 返回空转 visitor：上游不判 null，交回 null 会让读取器在取 code 时踩空。
            return new DexMethodVisitor();
        }
    }

    /**
     * 预先扫出「产物里含有任意 {@code NEW}」的方法。
     *
     * <p>**不按 NEW 的类型筛**：误译后的类型是「构造器的声明类」，它可以是任何类（抽象父类、
     * {@code Object}、{@code ThreadLocal} 这类继承了构造器的 JDK 类，或站源自己的父类）。曾经用
     * 「NEW 的是 dex 抽象类或 {@code Object}」当筛子，结果 {@code w3/b.<clinit>}（{@code NEW
     * java/lang/ThreadLocal}，dex 是 {@code new-instance Lw3/a}）连看都没被看到，运行期表现为
     * {@code initialValue()} 返回 null。这里只挑候选，真伪一律由 {@link #indexNewInstances} 拿到的
     * dex 序列逐条对位判断——多扫几个方法是几毫秒的事，漏看一条就是一个运行期谜题。
     *
     * <p>名称形如 {@code owner.name(desc)}，与 {@link #key} 拼接后的方法键一致。
     */
    private static Set<String> methodsWithNew(Path rawJar) throws IOException {
        Set<String> needed = new HashSet<>();
        try (ZipFile in = new ZipFile(rawJar.toFile())) {
            Enumeration<? extends ZipEntry> entries = in.entries();
            while (entries.hasMoreElements()) {
                ZipEntry entry = entries.nextElement();
                if (entry.isDirectory() || !entry.getName().endsWith(".class")) {
                    continue;
                }
                ClassNode node = new ClassNode();
                new ClassReader(readEntry(in, entry)).accept(node, ClassReader.SKIP_FRAMES);
                for (MethodNode method : node.methods) {
                    for (AbstractInsnNode insn : method.instructions) {
                        if (insn instanceof TypeInsnNode created && created.getOpcode() == Opcodes.NEW) {
                            needed.add(node.name + "." + key(method.name, method.desc));
                            break;
                        }
                    }
                }
            }
        }
        return needed;
    }
    /**
     * 读指定方法的 dex {@code new-instance} 站点（保持 dex 中的出现顺序）：每处都带上「它自己那条
     * 构造器调用的描述符」。
     *
     * <p>为什么要连描述符一起读：产物的 {@code NEW} 顺序可以和方法里 {@code new-instance} 的顺序
     * 不同（dex2jar 会重排指令），此时「第 i 个 NEW ↔ 第 i 个 new-instance」是错的。描述符不受重排
     * 影响，用它当指纹才能把两侧配成同一批构造（见 {@link #alignByDescriptorChain}）。
     *
     * <p>配对按**寄存器**做、不按顺序：dex 的 {@code new-instance} 把新对象写进某个寄存器，紧随其后的
     * {@code invoke-direct <init>} 以该寄存器作接收者。实测 {@code z3/o.a(C)V}：{@code new-instance
     * Lz3/a;}(reg 11) 之后先出现的是 {@code new-instance Lz3/r;}(reg 3) 的构造调用——按顺序配会把 a 配
     * 到 r 的构造器上，按寄存器就不会。
     */
    private static Map<String, List<DexNewSite>> indexNewInstances(byte[] dex, Set<String> needed) {
        Map<String, List<DexNewSite>> result = new HashMap<>();
        if (needed.isEmpty()) {
            return result;
        }
        new DexFileReader(dex).accept(new DexFileVisitor() {
            @Override
            public DexClassVisitor visit(int access, String className, String superName, String[] interfaceNames) {
                String owner = internal(className);
                return new DexClassVisitor() {
                    @Override
                    public DexMethodVisitor visitMethod(int methodAccess, Method method) {
                        String methodKey = owner + "." + DexRepair.key(method.getName(), method.getDesc());
                        if (!needed.contains(methodKey)) {
                            // 不需要这个方法：返回 null 表示让读取器跳过它的 code（已实证读取器判空）。
                            return null;
                        }
                        List<DexNewSite> sites = new ArrayList<>();
                        result.put(methodKey, sites);
                        return new DexMethodVisitor() {
                            @Override
                            public DexCodeVisitor visitCode() {
                                return new DexCodeVisitor() {
                                    /** 当前还挂着「没配到构造器」的 new-instance 的寄存器。 */
                                    private final Map<Integer, DexNewSite> pending = new HashMap<>();

                                    @Override
                                    public void visitTypeStmt(Op op, int a, int b, String type) {
                                        if (op != Op.NEW_INSTANCE) {
                                            return;
                                        }
                                        DexNewSite site = new DexNewSite(internal(type));
                                        sites.add(site);
                                        pending.put(a, site);
                                    }

                                    @Override
                                    public void visitMethodStmt(Op op, int[] args, Method callee) {
                                        if ((op != Op.INVOKE_DIRECT && op != Op.INVOKE_DIRECT_RANGE)
                                                || !callee.getName().equals("<init>")
                                                || args == null
                                                || args.length == 0) {
                                            return;
                                        }
                                        // args[0] 是接收者寄存器：谁在上面就配给谁。
                                        DexNewSite site = pending.remove(args[0]);
                                        if (site != null) {
                                            site.initDesc = callee.getDesc();
                                        }
                                    }
                                };
                            }
                        };
                    }
                };
            }
        }, DexFileReader.SKIP_DEBUG | DexFileReader.SKIP_ANNOTATION);
        return result;
    }

    /**
     * 一处 dex {@code new-instance} 的事实：实例化类型 + 它自己那条构造器调用的描述符。
     *
     * <p>{@code initDesc} 为 null 表示这条 new-instance 没配到 {@code <init>}：没有指纹可用，整条
     * 方法只能「保持原样」。
     */
    private static final class DexNewSite {
        final String type;
        String initDesc;

        DexNewSite(String type) {
            this.type = type;
        }
    }

    private static String key(String name, String descriptor) {
        return name + descriptor;
    }

    /**
     * dex 的类/类型名是描述符（{@code Lcom/x/Y;}），ASM 用内部名（{@code com/x/Y}）：
     * 两边必须换到同一口径，否则所有按名字做的比对都会静默失配。
     */
    private static String internal(String dexType) {
        if (dexType == null) {
            return null;
        }
        int length = dexType.length();
        if (length > 2 && dexType.charAt(0) == 'L' && dexType.charAt(length - 1) == ';') {
            return dexType.substring(1, length - 1);
        }
        return dexType;
    }

    private static boolean isDexAbstract(Map<String, DexClass> index, String internalName) {
        DexClass info = index.get(internalName);
        return info != null && (info.access & Opcodes.ACC_ABSTRACT) != 0;
    }

    private static boolean declaresMethod(
            Map<String, DexClass> index, String owner, String name, String descriptor) {
        DexClass info = index.get(owner);
        return info != null && info.methods.containsKey(key(name, descriptor));
    }

    /** {@code sub} 是否是 {@code sup} 的子类（按 dex 的 super 链判断，不看接口）。 */
    private static boolean isDexSubclass(Map<String, DexClass> index, String sub, String sup) {
        String current = sub;
        for (int depth = 0; current != null && depth < SUPER_CHAIN_LIMIT; depth++) {
            if (current.equals(sup)) {
                return true;
            }
            DexClass info = index.get(current);
            if (info == null) {
                return false;
            }
            current = info.superName;
        }
        return false;
    }

    /**
     * owner 是否是接口。dex 的 {@code ACC_INTERFACE} 是编译器事实，优先用它；dex 之外的类型（JDK、
     * 宿主类）只在不初始化类的前提下读元数据（{@code initialize=false} 不跑 {@code <clinit>}）。
     * 两者都证明不了就返回 {@code null}：站源自己的类不在宿主类路径上，这种「不知道」必须保持原样。
     */
    private static Boolean isInterfaceOwner(String owner, Map<String, DexClass> index) {
        DexClass dex = index.get(owner);
        if (dex != null) {
            return (dex.access & Opcodes.ACC_INTERFACE) != 0;
        }
        try {
            return Class.forName(owner.replace('/', '.'), false, DexRepair.class.getClassLoader()).isInterface();
        } catch (ClassNotFoundException | LinkageError | SecurityException error) {
            return null;
        }
    }

    // ---------------------------------------------------------------- 单类修复

    /**
     * @param bytes 修复后的 class（未命中时为原始字节）
     * @param touched 字节码是否被改动
     * @param missing 产物中的该类在 dex 里找不到
     */
    private record Outcome(
            byte[] bytes, boolean touched, int stubbed, int retargeted, int retyped, boolean missing) {}

    private static Outcome repairClass(
            byte[] data,
            Map<String, DexClass> index,
            Map<String, List<DexNewSite>> dexNewInstances,
            List<String> records) {
        ClassNode node = new ClassNode();
        new ClassReader(data).accept(node, ClassReader.SKIP_FRAMES);
        DexClass source = index.get(node.name);
        if (source == null) {
            // 名字对不上时不动：dex2jar 的命名规则一旦与索引不同，任何「猜着改」都是瞎改。
            return new Outcome(data, false, 0, 0, 0, true);
        }

        int stubbed = 0;
        int retargeted = 0;
        int retyped = 0;
        boolean touched = false;

        // a) NEW 类型误译：dex 的 new-instance 类型被译成了「构造器的声明类」——抽象父类、Object、
        //    或任一个继承了构造器的普通父类。
        //
        //    对位分两档，保留既有下标判据，失败后才尝试描述符链唯一性证明：
        //      1) 下标档：产物的 NEW 序列与 dex 的 new-instance 序列逐条同序（绝大多数方法如此）；
        //      2) 描述符链档：dex2jar 会重排指令——实测 z3/o.a(C)V 里 dex 是 a,r,a,r…、产物是
        //         r,a,r,a…，序号对不上，但「每个 NEW + 它自己的构造器描述符」这条链两侧一致。用描述符
        //         当指纹重新配对，才能把 NEW z3/c 改回 dex 的 z3/b（c 是 b 的抽象父类、构造器声明在
        //         c 上，正是误译机制）。
        //    两档都失败就整条方法原样，并把两档各自的原因写进 records——宁可不修，也不改出一个
        //    「看起来修了」的类。
        for (MethodNode method : node.methods) {
            List<TypeInsnNode> news = new ArrayList<>();
            for (AbstractInsnNode insn : method.instructions) {
                if (insn instanceof TypeInsnNode created && created.getOpcode() == Opcodes.NEW) {
                    news.add(created);
                }
            }
            if (news.isEmpty()) {
                continue;
            }
            String methodKey = node.name + "." + key(method.name, method.desc);
            List<DexNewSite> dexSites = dexNewInstances.get(methodKey);
            if (dexSites == null) {
                note(records, "dex 中找不到该方法，NEW 保持原样：" + methodKey);
                continue;
            }
            Alignment byIndex = alignByIndex(index, news, dexSites);
            Alignment alignment = byIndex;
            String tier = "下标对位";
            if (!byIndex.ok()) {
                alignment = alignByDescriptorChain(index, method, news, dexSites);
                tier = "描述符链对位";
            }
            if (!alignment.ok()) {
                note(records, "NEW 对位失败（下标：" + byIndex.reason()
                        + "；描述符链：" + alignment.reason() + "），整条方法保持原样：" + methodKey);
                continue;
            }
            int applied = 0;
            for (int i = 0; i < news.size(); i++) {
                String dexType = alignment.targets().get(i);
                if (!dexType.equals(news.get(i).desc)) {
                    note(records, "NEW " + news.get(i).desc + " → " + dexType
                            + "（" + tier + "，" + methodKey + "）");
                    news.get(i).desc = dexType;
                    applied++;
                }
            }
            if (applied > 0) {
                retyped += applied;
                touched = true;
            }
        }

        // b) 伪 abstract 类：dex 说它具体，产物却 abstract。
        boolean pseudoAbstract = (source.access & Opcodes.ACC_ABSTRACT) == 0
                && (node.access & Opcodes.ACC_ABSTRACT) != 0
                // 接口/注解按规范必须 abstract，dex2jar 这样标是对的，不碰。
                && (node.access & (Opcodes.ACC_INTERFACE | Opcodes.ACC_ANNOTATION)) == 0;
        if (pseudoAbstract) {
            boolean allResolved = true;
            for (MethodNode method : node.methods) {
                if ((method.access & Opcodes.ACC_ABSTRACT) == 0) {
                    continue;
                }
                Integer dexAccess = source.methods.get(key(method.name, method.desc));
                if (dexAccess == null) {
                    allResolved = false;
                    note(records, "dex 无此方法，保持 abstract：" + node.name + "." + key(method.name, method.desc));
                    continue;
                }
                if ((dexAccess & (Opcodes.ACC_ABSTRACT | Opcodes.ACC_NATIVE)) != 0) {
                    // dex 里确实没实现（抽象方法 / native）：补桩体等于凭空造实现，保持抽象。
                    allResolved = false;
                    note(records, "dex 里确实无实现，保持 abstract：" + node.name + "." + key(method.name, method.desc));
                    continue;
                }
                stub(method, node.name);
                stubbed++;
                touched = true;
                note(records, "补桩体（dex 有实现）：" + node.name + "." + key(method.name, method.desc));
            }
            if (allResolved) {
                node.access &= ~Opcodes.ACC_ABSTRACT;
                touched = true;
                note(records, "清 abstract：" + node.name + "（dex 中该类非抽象）");
            } else {
                note(records, "仍有无法解释的抽象方法，保持 abstract：" + node.name);
            }
        }

        // c) 自递归 invokespecial：dex2jar 把 invoke-super 译成了指向本类同一方法的 invokespecial。
        for (MethodNode method : node.methods) {
            Integer dexAccess = source.methods.get(key(method.name, method.desc));
            boolean isConstructor = method.name.equals("<init>");
            for (AbstractInsnNode insn : method.instructions) {
                if (!(insn instanceof MethodInsnNode call) || call.getOpcode() != Opcodes.INVOKESPECIAL) {
                    continue;
                }
                if (!call.owner.equals(node.name)
                        || !call.name.equals(method.name)
                        || !call.desc.equals(method.desc)) {
                    continue;
                }
                // 私有成员方法在 dex 里走 invoke-direct，dex2jar 译成 invokespecial 是**对的**：
                // 私有方法自递归必须原样保留。构造器不算——同描述符的 this(...) 委派必然是死循环，
                // 只可能是 super 调用被译错。
                if (!isConstructor && dexAccess != null && (dexAccess & Opcodes.ACC_PRIVATE) != 0) {
                    note(records, "私有方法自递归，保持：" + node.name + "." + key(method.name, method.desc));
                    continue;
                }
                String target = node.superName;
                if (target == null) {
                    note(records, "无父类，保持自递归调用：" + node.name + "." + key(method.name, method.desc));
                    continue;
                }
                if (!declaresMethod(index, target, call.name, call.desc) && !isObjectConstructor(target, call)) {
                    // 父类（可能在 dex 之外，如 android.*）没有同名同描述符的方法：宁可留着错译，
                    // 也不改出一个必然 NoSuchMethodError 的调用点。
                    note(records, "父类 " + target + " 无 " + call.name + call.desc
                            + "，保持自递归：" + node.name);
                    continue;
                }
                note(records, "重定向 invokespecial " + node.name + "." + call.name + call.desc
                        + " → " + target);
                call.owner = target;
                retargeted++;
                touched = true;
            }
        }

        // d) 接口方法调用标记误译：dex2jar 把对接口方法的 invoke-static / invoke-special 译成了普通
        //    Methodref（itf=false）。JVM 解析这类常量时直接抛
        //    IncompatibleClassChangeError: Method '…' must be InterfaceMethodref constant（实测
        //    AnimeAiGongHeGuo 的 Comparator.comparing(Function)）。只翻转「能证明 owner 是接口」的调用：
        //    dex 的 ACC_INTERFACE 优先，dex 之外（JDK/宿主类）只在**不初始化**的前提下读类元数据；
        //    证明不了的一律保持原样并记录原因，绝不猜。
        for (MethodNode method : node.methods) {
            for (AbstractInsnNode insn : method.instructions) {
                if (!(insn instanceof MethodInsnNode call) || call.itf) {
                    continue;
                }
                if (call.getOpcode() != Opcodes.INVOKESTATIC && call.getOpcode() != Opcodes.INVOKESPECIAL) {
                    continue;
                }
                if (call.name.equals("<init>") || call.name.equals("<clinit>")) {
                    // 接口不能声明构造器：这类调用只可能落在类上，不必去证明 owner。
                    continue;
                }
                Boolean ownerIsInterface = isInterfaceOwner(call.owner, index);
                if (ownerIsInterface == null) {
                    note(records, "无法确认 " + call.owner + " 是否为接口，调用标记保持："
                            + node.name + "." + key(method.name, method.desc));
                    continue;
                }
                if (!ownerIsInterface) {
                    continue;
                }
                note(records, "接口调用标记 itf=true：" + call.owner + "." + call.name + call.desc
                        + "（" + node.name + "）");
                call.itf = true;
                touched = true;
            }
        }

        if (!touched) {
            // 没改动就不重写：重写意味着再跑一遍 COMPUTE_FRAMES，1193 个类都不该白跑。
            return new Outcome(data, false, 0, 0, 0, false);
        }
        ClassWriter writer = new ClassWriter(ClassWriter.COMPUTE_FRAMES | ClassWriter.COMPUTE_MAXS) {
            @Override
            protected String getCommonSuperClass(String type1, String type2) {
                // 与 DexIntake 的帧修复同一策略：站源类在这里不可见，精确求公共父类不可得。
                return "java/lang/Object";
            }
        };
        node.accept(writer);
        return new Outcome(writer.toByteArray(), true, stubbed, retargeted, retyped, false);
    }

    // ---------------------------------------------------------------- NEW 对位

    /** 一档对位的结果：成功时 {@code targets} 与 {@code news} 同序，给出每个 NEW 应改成的 dex 类型。 */
    private record Alignment(List<String> targets, String reason) {
        boolean ok() {
            return targets != null;
        }

        static Alignment rejected(String reason) {
            return new Alignment(null, reason);
        }
    }

    /**
     * 下标档：dex 的 new-instance 序列与产物的 NEW 序列逐条同序，且每处差异都是收窄。
     *
     * <p>保持既有位置判据：各位置类型一致或为收窄时采用该序列；不再额外要求描述符唯一。
     */
    private static Alignment alignByIndex(
            Map<String, DexClass> index, List<TypeInsnNode> news, List<DexNewSite> dexSites) {
        if (dexSites.size() != news.size()) {
            return Alignment.rejected(
                    "NEW 数量与 dex 不一致（dex=" + dexSites.size() + " jar=" + news.size() + "）");
        }
        List<String> targets = new ArrayList<>(news.size());
        for (int i = 0; i < news.size(); i++) {
            String jarType = news.get(i).desc;
            String dexType = dexSites.get(i).type;
            if (!dexType.equals(jarType) && !isNarrowingToConcrete(index, jarType, dexType)) {
                return Alignment.rejected("第 " + i + " 处 NEW " + jarType + " 与 dex 的 " + dexType
                        + " 不是「祖先→具体子类」的收窄");
            }
            targets.add(dexType);
        }
        return new Alignment(targets, null);
    }

    /**
     * 描述符链档：dex2jar 重排过指令时序号不可信，改用构造器描述符当指纹重新配对。
     *
     * <p>「唯一」的定义（任一不满足就整条方法放弃，不猜）：
     * <ol>
     *   <li>两侧的描述符集合与每组数量都必须一致——这是「在构造同一批对象、只是顺序不同」的指纹，
     *       少一条多一条都说明形状超出这里的认知；</li>
     *   <li>同一描述符内建立「相同类型或祖先→具体子类」的二分图；必须存在完整匹配，且每处 NEW
     *       在所有完整匹配里的目标类型相同（同类型的多次出现可互换）。无法证明唯一就整条放弃；</li>
     *   <li>每处差异仍必须是收窄（与下标档同一条判据）。档位只换对位方式，不放宽判据。</li>
     * </ol>
     */
    private static Alignment alignByDescriptorChain(
            Map<String, DexClass> index,
            MethodNode method,
            List<TypeInsnNode> news,
            List<DexNewSite> dexSites) {
        List<String> jarInits = jarInitDescriptors(method, news);
        if (jarInits == null) {
            return Alignment.rejected("产物里有 NEW 配不到构造器调用");
        }
        Map<String, List<Integer>> jarGroups = new LinkedHashMap<>();
        for (int i = 0; i < news.size(); i++) {
            jarGroups.computeIfAbsent(jarInits.get(i), k -> new ArrayList<>()).add(i);
        }
        Map<String, List<DexNewSite>> dexGroups = new LinkedHashMap<>();
        for (DexNewSite site : dexSites) {
            if (site.initDesc == null) {
                return Alignment.rejected("dex 里有 new-instance 配不到 invoke-direct <init>");
            }
            dexGroups.computeIfAbsent(site.initDesc, k -> new ArrayList<>()).add(site);
        }
        if (!jarGroups.keySet().equals(dexGroups.keySet())) {
            return Alignment.rejected("构造器描述符集合不一致（jar=" + jarGroups.keySet()
                    + " dex=" + dexGroups.keySet() + "）");
        }
        Map<TypeInsnNode, Set<String>> fieldOwners = allocationFieldOwners(method, news);
        if (fieldOwners == null) {
            return Alignment.rejected("分配使用分析超过上限");
        }
        List<String> targets = new ArrayList<>(news.size());
        for (int i = 0; i < news.size(); i++) {
            targets.add(null);
        }
        for (Map.Entry<String, List<Integer>> group : jarGroups.entrySet()) {
            List<Integer> jarIndexes = group.getValue();
            List<DexNewSite> dexSame = dexGroups.get(group.getKey());
            if (jarIndexes.size() != dexSame.size()) {
                return Alignment.rejected("描述符 " + group.getKey() + " 两侧数量不一致（jar="
                        + jarIndexes.size() + " dex=" + dexSame.size() + "）");
            }
            Alignment groupAlignment = alignDescriptorGroup(index, news, jarIndexes, dexSame, group.getKey(), fieldOwners);
            if (!groupAlignment.ok()) {
                return groupAlignment;
            }
            for (int i = 0; i < jarIndexes.size(); i++) {
                targets.set(jarIndexes.get(i), groupAlignment.targets().get(i));
            }
        }
        return new Alignment(targets, null);
    }

    private static Alignment alignDescriptorGroup(
            Map<String, DexClass> index, List<TypeInsnNode> news, List<Integer> jarIndexes,
            List<DexNewSite> dexSites, String descriptor, Map<TypeInsnNode, Set<String>> fieldOwners) {
        int size = jarIndexes.size();
        if (size > ALIGNMENT_GROUP_LIMIT) {
            return Alignment.rejected("描述符组超过匹配上限（" + descriptor + " size=" + size + "）");
        }
        boolean[][] compatible = new boolean[size][size];
        for (int jar = 0; jar < size; jar++) {
            String jarType = news.get(jarIndexes.get(jar)).desc;
            for (int dex = 0; dex < size; dex++) {
                String dexType = dexSites.get(dex).type;
                compatible[jar][dex] = (jarType.equals(dexType)
                        || isNarrowingToConcrete(index, jarType, dexType))
                        && fieldOwners.getOrDefault(news.get(jarIndexes.get(jar)), Set.of()).stream()
                                .allMatch(owner -> isDexSubclass(index, dexType, owner));
            }
        }
        int[] matchedJar = new int[size];
        java.util.Arrays.fill(matchedJar, -1);
        for (int jar = 0; jar < size; jar++) {
            if (!augmentMatching(jar, compatible, matchedJar, new boolean[size])) {
                return Alignment.rejected("描述符组不存在完整的祖先→具体子类收窄匹配（" + descriptor + "）");
            }
        }
        // Collapse each matched pair to one vertex. An alternative edge belongs to some
        // complete matching exactly when it closes an alternating cycle.
        boolean[][] reachable = new boolean[size][size];
        for (int jar = 0; jar < size; jar++) {
            reachable[jar][jar] = true;
            for (int dex = 0; dex < size; dex++) {
                if (compatible[jar][dex]) reachable[jar][matchedJar[dex]] = true;
            }
        }
        for (int via = 0; via < size; via++) {
            for (int from = 0; from < size; from++) {
                if (!reachable[from][via]) continue;
                for (int to = 0; to < size; to++) {
                    reachable[from][to] |= reachable[via][to];
                }
            }
        }
        List<String> targets = new ArrayList<>(size);
        for (int jar = 0; jar < size; jar++) {
            String target = null;
            for (int dex = 0; dex < size; dex++) {
                if (!compatible[jar][dex] || !reachable[matchedJar[dex]][jar]) continue;
                String candidate = dexSites.get(dex).type;
                if (target != null && !target.equals(candidate)) {
                    return Alignment.rejected("描述符链目标类型不唯一（" + descriptor + " NEW "
                            + news.get(jarIndexes.get(jar)).desc + " 可配 " + target + " 或 " + candidate + "）");
                }
                target = candidate;
            }
            targets.add(target);
        }
        return new Alignment(targets, null);
    }

    private static final int ALLOCATION_USE_INSTRUCTION_LIMIT = 4096;
    private static final int ALLOCATION_USE_FRAME_SLOT_LIMIT = 262144;

    /** Only a single proven allocation receiver can exclude a dex candidate. */
    private static Map<TypeInsnNode, Set<String>> allocationFieldOwners(MethodNode method, List<TypeInsnNode> news) {
        boolean hasFields = false;
        for (AbstractInsnNode insn : method.instructions) {
            if (insn.getOpcode() == Opcodes.PUTFIELD) { hasFields = true; break; }
        }
        if (!hasFields) return Map.of();
        int instructions = method.instructions.size();
        if (instructions > ALLOCATION_USE_INSTRUCTION_LIMIT || news.size() > ALIGNMENT_GROUP_LIMIT
                || (long) instructions * (method.maxLocals + method.maxStack) > ALLOCATION_USE_FRAME_SLOT_LIMIT) {
            return null;
        }
        Map<TypeInsnNode, Set<String>> owners = new IdentityHashMap<>();
        try {
            Frame<SourceValue>[] frames = new Analyzer<>(new AllocationSources()).analyze("java/lang/Object", method);
            int offset = 0;
            for (AbstractInsnNode insn : method.instructions) {
                Frame<SourceValue> frame = frames[offset++];
                if (!(insn instanceof FieldInsnNode field) || insn.getOpcode() != Opcodes.PUTFIELD
                        || frame == null || frame.getStackSize() < 2) continue;
                SourceValue receiver = frame.getStack(frame.getStackSize() - 2);
                if (receiver.insns.size() != 1) continue;
                AbstractInsnNode origin = receiver.insns.iterator().next();
                if (origin instanceof TypeInsnNode created && origin.getOpcode() == Opcodes.NEW) {
                    owners.computeIfAbsent(created, ignored -> new HashSet<>()).add(field.owner);
                }
            }
        } catch (AnalyzerException | IllegalArgumentException unsupported) {
            // An unsupported shape supplies no proof, not a guessed receiver origin.
            return Map.of();
        }
        return owners;
    }

    private static final class AllocationSources extends SourceInterpreter {
        private final AbstractInsnNode unknown = new InsnNode(Opcodes.NOP);

        AllocationSources() { super(Opcodes.ASM9); }

        private SourceValue unknown(SourceValue value) {
            return value == null ? null : new SourceValue(value.getSize(), unknown);
        }

        @Override public SourceValue newValue(org.objectweb.asm.Type type) { return unknown(super.newValue(type)); }
        @Override public SourceValue newOperation(AbstractInsnNode insn) {
            SourceValue value = super.newOperation(insn);
            return insn.getOpcode() == Opcodes.NEW ? value : unknown(value);
        }
        @Override public SourceValue copyOperation(AbstractInsnNode insn, SourceValue value) { return value; }
        @Override public SourceValue unaryOperation(AbstractInsnNode insn, SourceValue value) {
            return insn.getOpcode() == Opcodes.CHECKCAST ? value : unknown(super.unaryOperation(insn, value));
        }
        @Override public SourceValue binaryOperation(AbstractInsnNode insn, SourceValue left, SourceValue right) {
            return unknown(super.binaryOperation(insn, left, right));
        }
        @Override public SourceValue ternaryOperation(AbstractInsnNode insn, SourceValue first, SourceValue second, SourceValue third) {
            return unknown(super.ternaryOperation(insn, first, second, third));
        }
        @Override public SourceValue naryOperation(AbstractInsnNode insn, List<? extends SourceValue> values) {
            return unknown(super.naryOperation(insn, values));
        }
    }

    private static boolean augmentMatching(
            int jar, boolean[][] compatible, int[] matchedJar, boolean[] seenDex) {
        for (int dex = 0; dex < matchedJar.length; dex++) {
            if (!compatible[jar][dex] || seenDex[dex]) continue;
            seenDex[dex] = true;
            if (matchedJar[dex] == -1 || augmentMatching(matchedJar[dex], compatible, matchedJar, seenDex)) {
                matchedJar[dex] = jar;
                return true;
            }
        }
        return false;
    }

    /**
     * 取产物方法里每个 {@code NEW} 各自的构造器描述符（与 {@code news} 同序）。
     *
     * <p>用栈而不是「取下一条 invokespecial」：{@code new A(new B())} 的指令次序是 NEW A / NEW B /
     * init B / init A，最近一个还没初始化的 NEW 先被消费。栈空时遇到的 {@code <init>} 是构造器里对
     * 父类的委托，与 NEW 无关，跳过。任一 NEW 配不到构造器就返回 null（形状超出认知）。
     */
    private static List<String> jarInitDescriptors(MethodNode method, List<TypeInsnNode> news) {
        Map<TypeInsnNode, String> descriptors = new IdentityHashMap<>();
        Deque<TypeInsnNode> pending = new ArrayDeque<>();
        for (AbstractInsnNode insn : method.instructions) {
            if (insn instanceof TypeInsnNode created && created.getOpcode() == Opcodes.NEW) {
                pending.push(created);
            } else if (insn instanceof MethodInsnNode call
                    && call.getOpcode() == Opcodes.INVOKESPECIAL
                    && call.name.equals("<init>")
                    && !pending.isEmpty()) {
                descriptors.put(pending.pop(), call.desc);
            }
        }
        List<String> result = new ArrayList<>(news.size());
        for (TypeInsnNode created : news) {
            String descriptor = descriptors.get(created);
            if (descriptor == null) {
                return null;
            }
            result.add(descriptor);
        }
        return result;
    }

    /**
     * 差异是否只是「收窄」：dex 类型是产物类型的子类，且 dex 说它**具体**。
     *
     * <p>为什么「祖先」这一个条件就够：误译的机制始终是 dex2jar 拿**构造器的声明类**当
     * {@code new-instance} 的类型，而声明类必是真实类型的祖先。实测到三种表现，都是本条件特例：
     * <ol>
     *   <li>抽象父类 → 具体子类（构造器声明在抽象父类上）；</li>
     *   <li>{@code java/lang/Object} → 具体类（构造器一路解析到 Object，如无构造器的类）；</li>
     *   <li>非抽象的普通父类 → 具体子类（如 {@code new-instance Lw3/a;} + {@code ThreadLocal.<init>}，
     *       产物写成 {@code NEW java/lang/ThreadLocal}——a 继承了 ThreadLocal 的构造器）。</li>
     * </ol>
     * 相反方向（放宽到祖先）或换成不相干的类一律拒绝：那会把误译变成别处的乱跑。
     */
    private static boolean isNarrowingToConcrete(
            Map<String, DexClass> index, String jarType, String dexType) {
        return isDexSubclass(index, dexType, jarType) && !isDexAbstract(index, dexType);
    }

    /**
     * 把「没有实现却必须是具体方法」的方法改成**显式失败**：抛异常而不是返回默认值。
     *
     * <p>返回 0 / null 能让类加载成功、程序继续跑，最终在别处以一个看不出根因的错误崩掉——
     * 那比 {@code UnsupportedOperationException}（消息里带 owner.name(desc)）难查得多。
     */
    private static void stub(MethodNode method, String owner) {
        method.access &= ~(Opcodes.ACC_ABSTRACT | Opcodes.ACC_NATIVE);
        InsnList body = new InsnList();
        body.add(new TypeInsnNode(Opcodes.NEW, THROWABLE));
        body.add(new InsnNode(Opcodes.DUP));
        body.add(new LdcInsnNode("dex2jar 未能转译 " + owner + "." + method.name + method.desc));
        body.add(new MethodInsnNode(
                Opcodes.INVOKESPECIAL, THROWABLE, "<init>", "(Ljava/lang/String;)V", false));
        body.add(new InsnNode(Opcodes.ATHROW));
        method.instructions = body;
        method.tryCatchBlocks = new ArrayList<>();
        method.localVariables = null;
        method.maxStack = 0;
        method.maxLocals = 0;
    }

    /** {@code java.lang.Object} 不在 dex 里，但它的 {@code <init>()V} 是 JVM 保证存在的。 */
    private static boolean isObjectConstructor(String target, MethodInsnNode call) {
        return target.equals("java/lang/Object")
                && call.name.equals("<init>")
                && call.desc.equals("()V");
    }

    private static void note(List<String> records, String message) {
        if (records.size() < RECORD_LIMIT) {
            records.add(message);
        } else if (records.size() == RECORD_LIMIT) {
            records.add("…记录超过 " + RECORD_LIMIT + " 条，其余已省略");
        }
    }

    private static byte[] readEntry(ZipFile zip, ZipEntry entry) throws IOException {
        try (InputStream in = zip.getInputStream(entry)) {
            return in.readAllBytes();
        }
    }
}
