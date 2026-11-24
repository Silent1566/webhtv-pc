package webhtv.spider;

import com.googlecode.d2j.Method;
import com.googlecode.d2j.dex.writer.DexFileWriter;
import com.googlecode.d2j.reader.Op;
import com.googlecode.d2j.visitors.DexClassVisitor;
import com.googlecode.d2j.visitors.DexCodeVisitor;
import com.googlecode.d2j.visitors.DexMethodVisitor;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.lang.reflect.InvocationTargetException;
import java.net.URL;
import java.net.URLClassLoader;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
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

/** Real ASM mistranslation -> real JVM IncompatibleClassChangeError -> real DexRepair output. */
public final class DexInterfaceReferenceContractTest {
    private static int assertions;

    public static void main(String[] args) throws Exception {
        Path work = Files.createTempDirectory("dex-interface-refs");
        byte[] dex = fixtureDex();
        Path raw = work.resolve("raw.jar");
        writeRaw(raw);
        Path dir = work.resolve("raw-classes");
        unzip(raw, dir);

        // RED: the mistranslated call is a genuine JVM failure, not a fabricated message.
        try (URLClassLoader loader = loader(dir)) {
            invoke(loader, "fixture.InterfaceCall", "call");
            throw new AssertionError("mistranslated invoke-static unexpectedly linked");
        } catch (IncompatibleClassChangeError error) {
            check(error.getMessage().contains("must be InterfaceMethodref constant"),
                    "actual ICCE wording: " + error.getMessage());
            check(error.getMessage().contains("fixture.Contract.meaning"),
                    "ICCE names the offending reference: " + error.getMessage());
        }

        Path repaired = work.resolve("repaired.jar");
        DexRepair.Report report = DexRepair.repair(raw, repaired, dex);
        Path repairedDir = work.resolve("repaired-classes");
        unzip(repaired, repairedDir);
        System.out.println("records=" + report.records());

        check(itf(repairedDir, "fixture/InterfaceCall", "fixture/Contract", "meaning"), "dex owner flag repaired");
        check(itf(repairedDir, "fixture/JdkCall", "java/util/Comparator", "naturalOrder"), "JDK owner flag repaired");
        check(!itf(repairedDir, "fixture/UnknownCall", "fixture/Missing", "boom"), "unknown owner untouched");
        check(!itf(repairedDir, "fixture/ClassCall", "java/util/Collections", "emptyList"), "class owner untouched");
        check(report.records().stream().anyMatch(r -> r.contains("fixture/Contract.meaning")),
                "repaired call recorded: " + report.records());
        check(report.records().stream().anyMatch(r -> r.contains("fixture/Missing")),
                "unknown owner recorded: " + report.records());

        try (URLClassLoader loader = loader(repairedDir)) {
            check(Integer.valueOf(42).equals(invoke(loader, "fixture.InterfaceCall", "call")), "dex interface call runs");
            Object comparator = invoke(loader, "fixture.JdkCall", "call");
            check(comparator != null, "JDK interface call runs");
            check(((List<?>) invoke(loader, "fixture.ClassCall", "call")).isEmpty(), "normal class call runs unchanged");
        }

        // Idempotent: a second pass over corrected output changes no byte.
        Path again = work.resolve("repaired-again.jar");
        DexRepair.repair(repaired, again, dex);
        check(bytes(repaired, "fixture/InterfaceCall.class").length > 0, "repaired entry readable");
        check(java.util.Arrays.equals(bytes(repaired, "fixture/InterfaceCall.class"),
                bytes(again, "fixture/InterfaceCall.class")), "second pass is a no-op");

        // Java cache gate: only the current repair semantics may be reused; old/malformed records retranslate.
        Path cacheSite = work.resolve("cache-site");
        Files.createDirectories(cacheSite.resolve("dexBundles"));
        Path archive = work.resolve("cache-entry.jar");
        try (ZipOutputStream out = new ZipOutputStream(Files.newOutputStream(archive))) {
            out.putNextEntry(new ZipEntry("classes.dex"));
            out.write("not-a-dex".getBytes(java.nio.charset.StandardCharsets.UTF_8));
            out.closeEntry();
        }
        Path bundle = cacheSite.resolve("dexBundles").resolve("classes.jar");
        Files.write(bundle, "fixture-bundle".getBytes(java.nio.charset.StandardCharsets.UTF_8));
        Path record = cacheSite.resolve("dexBundles").resolve("intake-dex.json");
        String sourceSha = sha256(archive);
        String bundleSha = sha256(bundle);
        writeRecord(record, sourceSha, bundleSha, 5);
        check(!cacheHit(archive, cacheSite), "old repairVersion retranslates instead of reusing bundle");
        writeRecord(record, sourceSha, bundleSha, DexRepair.VERSION);
        DexIntake.Result reused = DexIntake.translate(archive, cacheSite);
        check(reused.cached(), "current repairVersion reuses bundle");
        writeRecord(record, sourceSha, bundleSha, -1);
        check(!cacheHit(archive, cacheSite), "record without repairVersion retranslates");
        check(DexRepair.VERSION == 6, "repair semantics version bumped: " + DexRepair.VERSION);
        System.out.println("DexInterfaceReferenceContractTest assertions=" + assertions + " failures=0");
    }


    /** true when translate() reused the bundle; an untranslatable fixture proves a real retranslation attempt. */
    private static boolean cacheHit(Path archive, Path siteDir) throws Exception {
        try {
            return DexIntake.translate(archive, siteDir).cached();
        } catch (DexIntake.DexIntakeException attempted) {
            check(attempted.stage().equals("dex-转译"), "retranslation reached dex2jar: " + attempted.getMessage());
            return false;
        }
    }

    private static void writeRecord(Path record, String sourceSha, String bundleSha, int version) throws IOException {
        String json = "{\"sourceSha256\":\"" + sourceSha + "\",\"bundleSha256\":\"" + bundleSha
                + "\",\"classCount\":5" + (version < 0 ? "" : ",\"repairVersion\":" + version) + "}";
        Files.writeString(record, json);
    }

    private static String sha256(Path file) throws Exception {
        byte[] digest = java.security.MessageDigest.getInstance("SHA-256").digest(Files.readAllBytes(file));
        StringBuilder hex = new StringBuilder();
        for (byte value : digest) hex.append(String.format("%02x", value));
        return hex.toString();
    }
    private static void check(boolean value, String reason) {
        assertions++;
        if (!value) throw new AssertionError(reason);
    }

    private static Object invoke(URLClassLoader loader, String name, String method, Object... args) throws Exception {
        try {
            return Class.forName(name, true, loader).getMethod(method).invoke(null, args);
        } catch (InvocationTargetException wrapped) {
            Throwable cause = wrapped.getCause();
            if (cause instanceof Error error) throw error;
            throw wrapped;
        }
    }

    private static URLClassLoader loader(Path dir) throws IOException {
        return new URLClassLoader(new URL[] {dir.toUri().toURL()}, DexInterfaceReferenceContractTest.class.getClassLoader());
    }

    /** ASM writes exactly what dex2jar emitted for the real site: invoke-static on an interface owner with a Methodref. */
    private static void writeRaw(Path jar) throws IOException {
        byte[] contract = contractInterface();
        byte[] interfaceCall = callClass("fixture/InterfaceCall", "fixture/Contract", "meaning", "I", Opcodes.IRETURN);
        byte[] jdkCall = callClass("fixture/JdkCall", "java/util/Comparator", "naturalOrder", "Ljava/util/Comparator;", Opcodes.ARETURN);
        byte[] unknownCall = callClass("fixture/UnknownCall", "fixture/Missing", "boom", "V", Opcodes.RETURN);
        byte[] classCall = callClass("fixture/ClassCall", "java/util/Collections", "emptyList", "Ljava/util/List;", Opcodes.ARETURN);
        try (ZipOutputStream out = new ZipOutputStream(Files.newOutputStream(jar))) {
            for (Map.Entry<String, byte[]> entry : Map.of(
                    "fixture/Contract.class", contract,
                    "fixture/InterfaceCall.class", interfaceCall,
                    "fixture/JdkCall.class", jdkCall,
                    "fixture/UnknownCall.class", unknownCall,
                    "fixture/ClassCall.class", classCall).entrySet()) {
                out.putNextEntry(new ZipEntry(entry.getKey()));
                out.write(entry.getValue());
                out.closeEntry();
            }
        }
    }

    private static byte[] contractInterface() {
        ClassWriter writer = new ClassWriter(0);
        writer.visit(Opcodes.V17, Opcodes.ACC_PUBLIC | Opcodes.ACC_INTERFACE | Opcodes.ACC_ABSTRACT,
                "fixture/Contract", null, "java/lang/Object", null);
        MethodVisitor method = writer.visitMethod(Opcodes.ACC_PUBLIC | Opcodes.ACC_STATIC, "meaning", "()I", null, null);
        method.visitCode();
        method.visitIntInsn(Opcodes.BIPUSH, 42);
        method.visitInsn(Opcodes.IRETURN);
        method.visitMaxs(1, 0);
        method.visitEnd();
        writer.visitEnd();
        return writer.toByteArray();
    }

    private static byte[] callClass(String name, String owner, String callee, String returnDesc, int ret) {
        ClassWriter writer = new ClassWriter(ClassWriter.COMPUTE_MAXS);
        writer.visit(Opcodes.V17, Opcodes.ACC_PUBLIC, name, null, "java/lang/Object", null);
        MethodVisitor method = writer.visitMethod(Opcodes.ACC_PUBLIC | Opcodes.ACC_STATIC, "call", "()" + returnDesc, null, null);
        method.visitCode();
        method.visitMethodInsn(Opcodes.INVOKESTATIC, owner, callee, "()" + returnDesc, false);
        method.visitInsn(ret);
        method.visitMaxs(1, 0);
        method.visitEnd();
        writer.visitEnd();
        return writer.toByteArray();
    }

    /** Minimal dex: only class/method declarations, which is exactly what the repair rule consults. */
    private static byte[] fixtureDex() {
        DexFileWriter writer = new DexFileWriter();
        interfaceClass(writer, "fixture/Contract", "meaning", "()I");
        plainClass(writer, "fixture/InterfaceCall", "call", "I");
        plainClass(writer, "fixture/JdkCall", "call", "Ljava/lang/Object;");
        plainClass(writer, "fixture/UnknownCall", "call", "V");
        plainClass(writer, "fixture/ClassCall", "call", "Ljava/lang/Object;");
        return writer.toByteArray();
    }

    private static void interfaceClass(DexFileWriter writer, String name, String method, String desc) {
        DexClassVisitor type = writer.visit(Opcodes.ACC_PUBLIC | Opcodes.ACC_INTERFACE | Opcodes.ACC_ABSTRACT,
                "L" + name + ";", "Ljava/lang/Object;", null);
        body(type.visitMethod(Opcodes.ACC_PUBLIC | Opcodes.ACC_STATIC, new Method("L" + name + ";", method, new String[0], desc)), desc);
        type.visitEnd();
    }

    private static void plainClass(DexFileWriter writer, String name, String method, String desc) {
        DexClassVisitor type = writer.visit(Opcodes.ACC_PUBLIC, "L" + name + ";", "Ljava/lang/Object;", null);
        body(type.visitMethod(Opcodes.ACC_PUBLIC | Opcodes.ACC_STATIC, new Method("L" + name + ";", method, new String[0], desc)), desc);
        type.visitEnd();
    }

    private static void body(DexMethodVisitor method, String desc) {
        DexCodeVisitor code = method.visitCode();
        code.visitRegister(1);
        String result = desc.substring(desc.indexOf(')') + 1);
        if (result.equals("V")) {
            code.visitStmt0R(Op.RETURN_VOID);
        } else {
            code.visitConstStmt(Op.CONST_16, 0, 0);
            code.visitStmt1R(result.equals("I") ? Op.RETURN : Op.RETURN_OBJECT, 0);
        }
        code.visitEnd();
        method.visitEnd();
    }

    private static boolean itf(Path dir, String type, String owner, String name) throws IOException {
        ClassNode node = new ClassNode();
        new ClassReader(Files.readAllBytes(dir.resolve(type + ".class"))).accept(node, 0);
        for (var method : node.methods) {
            for (var insn : method.instructions) {
                if (insn instanceof MethodInsnNode call && call.owner.equals(owner) && call.name.equals(name)) {
                    return call.itf;
                }
            }
        }
        throw new AssertionError("no call to " + owner + "." + name + " in " + type);
    }

    private static void unzip(Path jar, Path dir) throws IOException {
        Files.createDirectories(dir);
        try (ZipFile zip = new ZipFile(jar.toFile())) {
            var entries = zip.entries();
            while (entries.hasMoreElements()) {
                ZipEntry entry = entries.nextElement();
                if (entry.isDirectory() || !entry.getName().endsWith(".class")) continue;
                Path target = dir.resolve(entry.getName());
                Files.createDirectories(target.getParent());
                try (InputStream in = zip.getInputStream(entry)) {
                    Files.copy(in, target);
                }
            }
        }
    }

    private static byte[] bytes(Path jar, String name) throws IOException {
        try (ZipFile zip = new ZipFile(jar.toFile())) {
            try (InputStream in = zip.getInputStream(zip.getEntry(name))) {
                ByteArrayOutputStream out = new ByteArrayOutputStream();
                in.transferTo(out);
                return out.toByteArray();
            }
        }
    }
}
