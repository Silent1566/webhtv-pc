package webhtv.spider;

import com.googlecode.d2j.Method;
import com.googlecode.d2j.dex.Dex2Asm;
import com.googlecode.d2j.dex.Dex2jar;
import com.googlecode.d2j.dex.DexExceptionHandler;
import com.googlecode.d2j.node.DexFileNode;
import com.googlecode.d2j.node.DexMethodNode;
import com.googlecode.d2j.reader.DexFileReader;
import java.nio.file.Files;
import java.nio.file.AtomicMoveNotSupportedException;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.util.ArrayList;
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
import org.objectweb.asm.tree.MethodNode;
import org.objectweb.asm.tree.MethodInsnNode;
import org.objectweb.asm.tree.AbstractInsnNode;

/** Keeps dex2jar's mutated failure nodes separate from the original dex used for recovery. */
public final class DexMethodRecovery {
    private DexMethodRecovery() {}

    static List<String> translate(byte[] dex, Path out) throws Exception {
        Map<String, Exception> failures = new LinkedHashMap<>();
        List<Exception> fileFailures = new ArrayList<>();
        try {
        Dex2jar.from(dex).withExceptionHandler(new DexExceptionHandler() {
            @Override public void handleFileException(Exception error) { fileFailures.add(error); }
            @Override public void handleMethodTranslateException(Method method, DexMethodNode mutated,
                    MethodVisitor visitor, Exception error) {
                String key = key(method);
                failures.put(key, error);
                Ipc.log(DexIntake.STAGE_TRANSLATE + ": 方法转译失败 " + key + "（" + error + "）");
            }
        }).to(out);
        } catch (Exception error) {
            if (!failures.isEmpty()) throw rejected(failures.keySet().iterator().next(), error);
            throw error;
        }
        if (!fileFailures.isEmpty()) {
            throw new DexIntake.DexIntakeException(DexIntake.STAGE_TRANSLATE,
                    "dex2jar 文件转译失败：" + fileFailures.get(0), fileFailures.get(0));
        }
        // A concrete method without Code must never escape even if the library missed its callback.
        try (ZipFile zip = new ZipFile(out.toFile())) {
            var entries = zip.entries();
            while (entries.hasMoreElements()) {
                ZipEntry entry = entries.nextElement();
                if (!entry.getName().endsWith(".class")) continue;
                ClassNode clz = readClass(zip.getInputStream(entry).readAllBytes());
                for (MethodNode method : clz.methods) {
                    if (concrete(method) && method.instructions.size() == 0) {
                        failures.putIfAbsent(key(clz.name, method), new IllegalStateException("Absent Code attribute"));
                    }
                }
            }
        }
        if (failures.isEmpty()) return List.of();
        DexFileNode original = new DexFileNode();
        new DexFileReader(dex).accept(original, 0);
        Map<String, DexMethodNode> originals = new LinkedHashMap<>();
        for (var clz : original.clzs) {
            if (clz.methods == null) continue;
            for (DexMethodNode method : clz.methods) {
                if (failures.containsKey(key(method.method))) originals.put(key(method.method), method);
            }
        }
        for (String key : failures.keySet()) {
            if (!originals.containsKey(key)) throw rejected(key, failures.get(key));
        }
        List<String> records = new ArrayList<>();
        Path rebuilt = Files.createTempFile(out.getParent(), ".methods-", ".jar");
        try {
            try (ZipFile zip = new ZipFile(out.toFile());
                    ZipOutputStream output = new ZipOutputStream(Files.newOutputStream(rebuilt))) {
                var entries = zip.entries();
                while (entries.hasMoreElements()) {
                    ZipEntry entry = entries.nextElement();
                    if (entry.isDirectory()) continue;
                    byte[] bytes = zip.getInputStream(entry).readAllBytes();
                    if (entry.getName().endsWith(".class")) {
                        ClassNode clz = readClass(bytes);
                        List<String> changedMethods = new ArrayList<>();
                        for (MethodNode method : clz.methods) {
                            String key = key(clz.name, method);
                            if (!failures.containsKey(key)) continue;
                            try {
                                DexMethodNode node = originals.get(key);
                                if (node.codeNode == null || !concrete(method)) {
                                    throw new IllegalStateException("原始方法没有可重建代码");
                                }
                                MethodNode body = new MethodNode(Opcodes.ASM9, method.access, method.name,
                                        method.desc, method.signature, method.exceptions.toArray(String[]::new));
                                new Dex2Asm().convertCode(node, body, new Dex2Asm.ClzCtx());
                                if (body.instructions.size() == 0) throw new IllegalStateException("重建后仍缺 Code");
                                validateHexHelpers(clz, body, key);
                                method.instructions = body.instructions;
                                method.tryCatchBlocks = body.tryCatchBlocks;
                                method.localVariables = body.localVariables;
                                method.visibleLocalVariableAnnotations = body.visibleLocalVariableAnnotations;
                                method.invisibleLocalVariableAnnotations = body.invisibleLocalVariableAnnotations;
                                method.maxStack = body.maxStack;
                                method.maxLocals = body.maxLocals;
                            } catch (Throwable error) {
                                error.addSuppressed(failures.get(key));
                                throw rejected(key, error);
                            }
                            failures.remove(key);
                            changedMethods.add(key);
                            String record = "原始 dex 方法体重建：" + key;
                            records.add(record);
                            Ipc.log(DexIntake.STAGE_TRANSLATE + ": " + record);
                        }
                        if (!changedMethods.isEmpty()) {
                            try {
                                ClassWriter writer = new ClassWriter(ClassWriter.COMPUTE_FRAMES | ClassWriter.COMPUTE_MAXS) {
                                    @Override protected String getCommonSuperClass(String type1, String type2) {
                                        return "java/lang/Object";
                                    }
                                };
                                clz.accept(writer);
                                bytes = writer.toByteArray();
                            } catch (Throwable error) {
                                throw rejected(String.join(", ", changedMethods), error);
                            }
                        }
                    }
                    ZipEntry copy = new ZipEntry(entry.getName());
                    if (entry.getTime() >= 0) copy.setTime(entry.getTime());
                    output.putNextEntry(copy); output.write(bytes); output.closeEntry();
                }
            }
            if (!failures.isEmpty()) {
                String key = failures.keySet().iterator().next();
                throw rejected(key, new IllegalStateException("产物中找不到待重建方法", failures.get(key)));
            }
            Files.move(rebuilt, out, StandardCopyOption.REPLACE_EXISTING);
            return List.copyOf(records);
        } finally {
            Files.deleteIfExists(rebuilt);
        }
    }


    /** A fresh ClzCtx cannot recreate dex2jar's long-string helper; never publish such a call. */
    static void validateHexHelpers(ClassNode clz, MethodNode body, String method) {
        for (AbstractInsnNode instruction : body.instructions) {
            if (!(instruction instanceof MethodInsnNode call) || !call.owner.equals(clz.name)
                    || !call.name.contains("$d2j$hex$")) {
                continue;
            }
            boolean declared = clz.methods.stream()
                    .anyMatch(m -> m.name.equals(call.name) && m.desc.equals(call.desc));
            if (!declared) {
                throw new IllegalStateException("重建方法引用缺失的 $d2j$hex$ 助手：" + method + " -> " + call.name + call.desc);
            }
        }
    }

    private static ClassNode readClass(byte[] data) {
        ClassNode clz = new ClassNode();
        new ClassReader(data).accept(clz, 0);
        return clz;
    }
    private static boolean concrete(MethodNode method) {
        return (method.access & (Opcodes.ACC_ABSTRACT | Opcodes.ACC_NATIVE)) == 0;
    }
    private static String key(Method method) {
        String owner = method.getOwner();
        return owner.substring(1, owner.length() - 1) + "#" + method.getName() + method.getDesc();
    }
    private static String key(String owner, MethodNode method) { return owner + "#" + method.name + method.desc; }
    private static DexIntake.DexIntakeException rejected(String method, Throwable error) {
        return new DexIntake.DexIntakeException(DexIntake.STAGE_TRANSLATE,
                "方法体重建失败，拒绝整包：" + method + "（" + error + "）", error);
    }

    private static void writeReport(Path report, List<String> records) throws java.io.IOException {
        report = report.toAbsolutePath();
        Path temp = Files.createTempFile(report.getParent(), ".methods-", ".tmp");
        try {
            Files.writeString(temp, Json.write(records));
            try {
                Files.move(temp, report, StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING);
            } catch (AtomicMoveNotSupportedException unsupported) {
                Files.move(temp, report, StandardCopyOption.REPLACE_EXISTING);
            }
        } finally {
            Files.deleteIfExists(temp);
        }
    }

    /** Subprocess entry uses the same handler/rebuild path and publishes diagnostics only on success. */
    public static void main(String[] args) {
        // Subprocess diagnostics are consumed as UTF-8; Windows defaults stderr to GBK.
        System.setErr(new java.io.PrintStream(new java.io.FileOutputStream(java.io.FileDescriptor.err), true,
                java.nio.charset.StandardCharsets.UTF_8));
        try {
            byte[] dex;
            try (ZipFile zip = new ZipFile(Path.of(args[0]).toFile())) {
                dex = zip.getInputStream(zip.getEntry("classes.dex")).readAllBytes();
            }
            List<String> records = translate(dex, Path.of(args[1]));
            writeReport(Path.of(args[2]), records);
        } catch (Throwable error) {
            for (int i = 1; i < args.length && i <= 2; i++) {
                try {
                    Files.deleteIfExists(Path.of(args[i]));
                } catch (Exception cleanupError) {
                    error.addSuppressed(cleanupError);
                }
            }
            System.err.println(error);
            System.exit(1);
        }
    }
}
