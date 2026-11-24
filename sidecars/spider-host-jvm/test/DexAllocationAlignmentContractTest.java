package webhtv.spider;

import com.googlecode.d2j.Method;
import com.googlecode.d2j.dex.writer.DexFileWriter;
import com.googlecode.d2j.reader.Op;
import com.googlecode.d2j.visitors.DexClassVisitor;
import com.googlecode.d2j.visitors.DexCodeVisitor;
import java.lang.reflect.InvocationTargetException;
import java.net.URL;
import java.net.URLClassLoader;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Comparator;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.zip.ZipEntry;
import java.util.zip.ZipFile;
import java.util.zip.ZipOutputStream;
import org.objectweb.asm.ClassReader;
import org.objectweb.asm.ClassWriter;
import org.objectweb.asm.MethodVisitor;
import org.objectweb.asm.Opcodes;
import org.objectweb.asm.tree.ClassNode;
import org.objectweb.asm.tree.MethodInsnNode;
import org.objectweb.asm.tree.TypeInsnNode;

/**
 * Original-dex allocations, reordered ASM allocations, and a real typed-array consumer.
 * Run compiled tests with Java 17+ and -noverify, as the production guarded-shell host does:
 * java -noverify -cp "test-classes;host.jar;lib/*" webhtv.spider.DexAllocationAlignmentContractTest
 * Verification-on rejects inherited Object constructor owners; preserving them is intentional.
 */
public final class DexAllocationAlignmentContractTest {
    private static int assertions;
    private static int failures;
    private static Path work;
    private static final String OBJECT = "java/lang/Object";
    private static final String MODEL = "fixture/Model";
    private static final String OTHER = "fixture/Other";
    private static final String MARKER = "fixture/Marker";
    private static final String FACTORY = "fixture/Factory";
    private static final Map<String, String> TYPES = Map.of(MODEL, OBJECT, OTHER, OBJECT, MARKER, OBJECT);

    private record Fixture(Path raw, Path repaired, byte[] dex, DexRepair.Report report) {}

    public static void main(String[] args) throws Exception {
        work = Files.createTempDirectory("dex-allocation-");
        try {
            run("reordered mixed constructors repair actual typed-array ArrayStoreException", () -> {
                Fixture f = fixture(new String[]{MODEL, MARKER}, new String[]{MARKER, OBJECT}, 1, TYPES);
                try {
                    invoke(f.raw());
                    throw new AssertionError("raw mistranslation did not throw");
                } catch (ArrayStoreException expected) {
                    check(expected.getMessage().equals("java.lang.Object"), "exact original failure: " + expected);
                    System.out.println("RED raw: " + expected);
                }
                Object[] result = invoke(f.repaired());
                check(result.length == 1 && result[0].getClass().getName().equals("fixture.Model"), "real typed-array value");
                check(news(f.repaired()).equals(List.of(MARKER, MODEL)), "only proven allocation narrowed");
                check(constructors(f.repaired()).equals(List.of(OBJECT, OBJECT)), "original superclass constructor owners preserved");
                check(f.report().retypedInstantiations() == 1, "single mistranslated allocation repaired");
                Path again = f.raw().getParent().resolve("again.jar");
                DexRepair.Report second = DexRepair.repair(f.repaired(), again, f.dex());
                check(second.retypedInstantiations() == 0, "idempotent retype count");
                check(Arrays.equals(member(f.repaired(), FACTORY + ".class"), member(again, FACTORY + ".class")), "idempotent method bytes");
            });
            run("duplicate target occurrences need no occurrence identity", () -> {
                Fixture f = fixture(new String[]{MODEL, MODEL, MARKER}, new String[]{MARKER, OBJECT, OBJECT}, 1, TYPES);
                check(news(f.repaired()).equals(List.of(MARKER, MODEL, MODEL)), "equivalent model occurrences accepted");
                check(invoke(f.repaired())[0].getClass().getName().equals("fixture.Model"), "duplicate target runs");
            });
            run("two concrete candidates remain ambiguous", () -> {
                Fixture f = fixture(new String[]{MODEL, OTHER, MARKER}, new String[]{MARKER, OBJECT, OBJECT}, 1, TYPES);
                unchanged(f, "不唯一");
            });
            run("legacy positional tier keeps order-compatible mixed allocations", () -> {
                Fixture f = fixture(new String[]{MODEL, OTHER}, new String[]{OBJECT, OBJECT}, 0, TYPES);
                check(news(f.repaired()).equals(List.of(MODEL, OTHER)), "legacy index mapping remains accepted");
                check(f.report().records().stream().allMatch(r -> r.contains("下标对位")), "no fallback proof imposed on existing positional contract");
                check(invoke(f.repaired())[0].getClass().getName().equals("fixture.Model"), "legacy typed-array construction runs");
            });
            run("greedy exact cancellation cannot hide ancestor stealing", () -> {
                Map<String, String> hierarchy = new LinkedHashMap<>(TYPES);
                hierarchy.put(OTHER, MODEL);
                Fixture f = fixture(new String[]{OTHER, MODEL, MARKER}, new String[]{MARKER, MODEL, OBJECT}, 2, hierarchy);
                unchanged(f, "不唯一");
            });
            run("descriptor group multiplicities must agree", () -> {
                Fixture f = fixture(new String[]{MODEL, MODEL, MARKER}, new String[]{MARKER, OBJECT}, 1, TYPES);
                unchanged(f, "数量");
            });
            run("unknown dex target never guessed", () -> {
                Fixture f = fixture(new String[]{"fixture/Absent", MARKER}, new String[]{MARKER, OBJECT}, 1, TYPES);
                unchanged(f, "收窄");
            });
            run("abstract dex target never instantiated", () -> {
                Map<String, String> hierarchy = new LinkedHashMap<>(TYPES);
                hierarchy.put("fixture/Abstract", OBJECT);
                Fixture f = fixture(new String[]{"fixture/Abstract", MARKER}, new String[]{MARKER, OBJECT}, 1, hierarchy);
                unchanged(f, "收窄");
            });
            run("matching accepts forced ancestor chain without greed", () -> {
                Map<String, String> hierarchy = new LinkedHashMap<>(TYPES);
                hierarchy.put(OTHER, MODEL);
                Fixture f = fixture(new String[]{OTHER, MARKER, MODEL}, new String[]{MARKER, OTHER, OBJECT}, 2, hierarchy);
                check(news(f.repaired()).equals(List.of(MARKER, OTHER, MODEL)), "compatible matching forces each target type");
            });
            run("large descriptor group is bounded and kept unchanged", () -> {
                String[] dexTypes = new String[258], jarTypes = new String[258];
                Arrays.fill(dexTypes, MODEL);Arrays.fill(jarTypes, OBJECT);
                dexTypes[0] = MARKER;jarTypes[257] = MARKER;
                unchanged(fixture(dexTypes, jarTypes, 0, TYPES), "上限");
            });
            System.out.println("DexAllocationAlignmentContractTest assertions=" + assertions + " failures=" + failures);
            if (failures != 0) throw new AssertionError(failures + " allocation contract cases failed");
        } finally {
            try (var paths = Files.walk(work)) {
                for (Path path : paths.sorted(Comparator.reverseOrder()).toList()) Files.deleteIfExists(path);
            }
        }
    }

    private static void unchanged(Fixture f, String reason) throws Exception {
        check(Arrays.equals(member(f.raw(), FACTORY + ".class"), member(f.repaired(), FACTORY + ".class")), "whole method remains untouched");
        check(f.report().records().stream().anyMatch(r -> r.contains(FACTORY + ".make") && r.contains(reason)), "skip explains " + reason + ": " + f.report().records());
    }

    private static Fixture fixture(String[] dexTypes, String[] jarTypes, int value, Map<String, String> hierarchy) throws Exception {
        Path raw = work.resolve("raw.jar"), repaired = work.resolve("repaired.jar");
        try (ZipOutputStream out = new ZipOutputStream(Files.newOutputStream(raw))) {
            for (var type : hierarchy.entrySet()) entry(out, type.getKey() + ".class", typeClass(type.getKey(), type.getValue()));
            entry(out, FACTORY + ".class", factory(jarTypes, value));
        }
        byte[] dex = dex(dexTypes, hierarchy);
        return new Fixture(raw, repaired, dex, DexRepair.repair(raw, repaired, dex));
    }

    private static byte[] dex(String[] allocations, Map<String, String> hierarchy) {
        DexFileWriter writer = new DexFileWriter();
        for (var type : hierarchy.entrySet()) {
            DexClassVisitor c = writer.visit(Opcodes.ACC_PUBLIC | (type.getKey().equals("fixture/Abstract") ? Opcodes.ACC_ABSTRACT : 0),
                    "L" + type.getKey() + ";", "L" + type.getValue() + ";", null);
            c.visitEnd();
        }
        DexClassVisitor c = writer.visit(Opcodes.ACC_PUBLIC, "L" + FACTORY + ";", "Ljava/lang/Object;", null);
        var m = c.visitMethod(Opcodes.ACC_PUBLIC | Opcodes.ACC_STATIC, new Method("L" + FACTORY + ";", "make", new String[0], "[L" + MODEL + ";"));
        DexCodeVisitor code = m.visitCode();
        code.visitRegister(1);
        for (String type : allocations) {
            code.visitTypeStmt(Op.NEW_INSTANCE, 0, -1, "L" + type + ";");
            code.visitMethodStmt(Op.INVOKE_DIRECT, new int[]{0}, new Method("Ljava/lang/Object;", "<init>", new String[0], "V"));
        }
        code.visitConstStmt(Op.CONST_4, 0, 0);
        code.visitStmt1R(Op.RETURN_OBJECT, 0);
        code.visitEnd();m.visitEnd();c.visitEnd();
        return writer.toByteArray();
    }

    private static byte[] typeClass(String name, String parent) {
        ClassWriter w = new ClassWriter(0);
        w.visit(Opcodes.V17, Opcodes.ACC_PUBLIC | (name.equals("fixture/Abstract") ? Opcodes.ACC_ABSTRACT : 0), name, null, parent, null);
        MethodVisitor m = w.visitMethod(Opcodes.ACC_PUBLIC, "<init>", "()V", null, null);
        m.visitCode();m.visitVarInsn(Opcodes.ALOAD, 0);
        m.visitMethodInsn(Opcodes.INVOKESPECIAL, parent, "<init>", "()V", false);
        m.visitInsn(Opcodes.RETURN);m.visitMaxs(1,1);m.visitEnd();w.visitEnd();
        return w.toByteArray();
    }

    private static byte[] factory(String[] allocations, int value) {
        ClassWriter w = new ClassWriter(0);
        w.visit(Opcodes.V17, Opcodes.ACC_PUBLIC, FACTORY, null, OBJECT, null);
        MethodVisitor m = w.visitMethod(Opcodes.ACC_PUBLIC | Opcodes.ACC_STATIC, "make", "()[L" + MODEL + ";", null, null);
        m.visitCode();
        for (int i = 0; i < allocations.length; i++) {
            m.visitTypeInsn(Opcodes.NEW, allocations[i]);m.visitInsn(Opcodes.DUP);
            m.visitMethodInsn(Opcodes.INVOKESPECIAL, OBJECT, "<init>", "()V", false);
            m.visitVarInsn(Opcodes.ASTORE, i);
        }
        m.visitInsn(Opcodes.ICONST_1);m.visitTypeInsn(Opcodes.ANEWARRAY, MODEL);m.visitInsn(Opcodes.DUP);
        m.visitInsn(Opcodes.ICONST_0);m.visitVarInsn(Opcodes.ALOAD, value);m.visitInsn(Opcodes.AASTORE);m.visitInsn(Opcodes.ARETURN);
        m.visitMaxs(4,allocations.length);m.visitEnd();w.visitEnd();
        return w.toByteArray();
    }

    private static Object[] invoke(Path jar) throws Exception {
        try (URLClassLoader loader = new URLClassLoader(new URL[]{jar.toUri().toURL()}, DexAllocationAlignmentContractTest.class.getClassLoader())) {
            try { return (Object[]) loader.loadClass(FACTORY.replace('/', '.')).getMethod("make").invoke(null); }
            catch (InvocationTargetException wrapped) {
                if (wrapped.getCause() instanceof Error e) throw e;
                if (wrapped.getCause() instanceof RuntimeException e) throw e;
                throw wrapped;
            }
        }
    }

    private static List<String> news(Path jar) throws Exception {
        ClassNode n = new ClassNode();new ClassReader(member(jar, FACTORY + ".class")).accept(n, 0);
        List<String> result = new ArrayList<>();
        for (var m : n.methods) for (var i : m.instructions)
            if (i instanceof TypeInsnNode t && t.getOpcode() == Opcodes.NEW) result.add(t.desc);
        return result;
    }

    private static List<String> constructors(Path jar) throws Exception {
        ClassNode n = new ClassNode();new ClassReader(member(jar, FACTORY + ".class")).accept(n, 0);
        List<String> result = new ArrayList<>();
        for (var m : n.methods) for (var i : m.instructions)
            if (i instanceof MethodInsnNode call && call.name.equals("<init>")) result.add(call.owner);
        return result;
    }

    private static byte[] member(Path jar, String name) throws Exception {
        try (ZipFile z = new ZipFile(jar.toFile())) {return z.getInputStream(z.getEntry(name)).readAllBytes();}
    }
    private static void entry(ZipOutputStream out, String name, byte[] bytes) throws Exception {
        out.putNextEntry(new ZipEntry(name));out.write(bytes);out.closeEntry();
    }
    private static void check(boolean value, String reason) {assertions++;if (!value) throw new AssertionError(reason);}
    private interface Checked {void run() throws Exception;}
    private static void run(String name, Checked test) {
        try {test.run();System.out.println("PASS " + name);}
        catch (Throwable error) {failures++;System.out.println("FAIL " + name + ": " + error);}
    }
}
