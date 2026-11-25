package webhtv.spider;

import com.googlecode.d2j.DexLabel;
import com.googlecode.d2j.Method;
import com.googlecode.d2j.dex.writer.DexFileWriter;
import com.googlecode.d2j.reader.Op;
import java.net.URLClassLoader;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;
import java.nio.charset.StandardCharsets;
import java.util.zip.ZipEntry;
import java.util.zip.ZipFile;
import java.util.zip.ZipOutputStream;
import org.objectweb.asm.ClassReader;
import org.objectweb.asm.ClassWriter;
import org.objectweb.asm.Opcodes;
import org.objectweb.asm.tree.ClassNode;
import org.objectweb.asm.tree.FrameNode;
import org.objectweb.asm.tree.MethodNode;
import org.objectweb.asm.tree.MethodInsnNode;
import org.objectweb.asm.tree.InsnNode;
import org.objectweb.asm.tree.LabelNode;
import org.objectweb.asm.tree.JumpInsnNode;

/** Removing original-node recovery must break both contracts, not merely their diagnostics. */
public final class DexMethodRecoveryContractTest {
    private static final String OWNER = "Lfixture/LongString;";
    private static final String ID = "fixture/LongString#value()Ljava/lang/String;";
    private static final String VALUE = "A".repeat(57014);
    private static int assertions;

    public static void main(String[] args) throws Exception {
        Path work = Files.createTempDirectory("dex-method-recovery-");
        List<String> failures = new ArrayList<>();
        run("regs=1 long const-string has Code and original semantics", () -> longString(work), failures);
        run("write-time records limit preserves cached==fresh", () -> recordLimit(work), failures);
        run("rebuilt raw class already has StackMapTable", () -> rebuiltFrames(work), failures);
        run("rebuilt class frame failure rejects without publication", () -> failedFrames(work), failures);
        run("regs=1 MUTF-8 63000 bytes preserves every character", () -> multiByte(work, 21000, true), failures);
        run("regs=1 MUTF-8 75000 bytes rejects and names method", () -> multiByte(work, 25000, false), failures);
        run("missing $d2j$hex$ helper rejects and names method/helper", () -> helperGuard(), failures);
        run("subprocess recovery matches in-process records and rejects with stage+method", () -> subprocess(work), failures);
        run("launcher discovers JAVA_HOME/javac and rejects insufficient major", () -> launcher(args), failures);
        run("failed rebuild rejects whole bundle", () -> failedRebuild(work), failures);
        System.out.println("DexMethodRecoveryContractTest assertions=" + assertions + " failures=" + failures.size());
        for (String failure : failures) System.out.println("FAIL " + failure);
        if (!failures.isEmpty()) throw new AssertionError(String.join("; ", failures));
    }

    private static void longString(Path work) throws Exception {
        Path archive = archive(work.resolve("long.jar"), fixture(false));
        Path site = work.resolve("long-site");
        DexIntake.Result result = DexIntake.translate(archive, site);
        try (ZipFile zip = new ZipFile(result.bundle().toFile())) {
            ClassNode node = new ClassNode();
            new ClassReader(zip.getInputStream(zip.getEntry("fixture/LongString.class")).readAllBytes()).accept(node, 0);
            check(node.methods.stream().filter(m -> m.name.equals("value")).allMatch(m -> m.instructions.size() > 0),
                    "value() missing Code");
        }
        try (URLClassLoader loader = new URLClassLoader(new java.net.URL[]{result.bundle().toUri().toURL()},
                DexMethodRecoveryContractTest.class.getClassLoader())) {
            Class<?> type = loader.loadClass("fixture.LongString");
            check(VALUE.equals(type.getMethod("value").invoke(null)), "57014-character return value changed");
            type.getField("gate").setInt(null, -1);
            check(type.getMethod("value").invoke(null) == null, "negative gate must return null");
        }
        check(result.records().stream().anyMatch(s -> s.contains(ID) && s.contains("重建")), "recovery report must name " + ID);
        DexIntake.Result cached = DexIntake.translate(archive, site);
        check(cached.cached() && cached.records().equals(result.records()), "cached recovery report changed");
        System.out.println("REBUILT " + result.records().stream().filter(s -> s.contains(ID)).toList());
    }

    private static void failedRebuild(Path work) throws Exception {
        Path archive = archive(work.resolve("bad.jar"), fixture(true));
        Path site = work.resolve("bad-site");
        try {
            DexIntake.translate(archive, site);
            throw new AssertionError("translation silently accepted an unrebuildable method");
        } catch (DexIntake.DexIntakeException error) {
            check(error.stage().equals("dex-转译"), "failure stage must be STAGE_TRANSLATE: " + error);
            check(error.getMessage().contains(ID), "failure must name owner#name desc: " + error);
            check(!Files.exists(site.resolve("dexBundles/classes.jar")), "invalid bundle was published");
            check(!Files.exists(site.resolve("dexBundles/intake-dex.json")), "invalid bundle was cached");
            System.out.println("REJECTED " + error.getMessage());
        }
    }

    private static byte[] fixture(boolean invalid) { return fixture(invalid, VALUE, 1); }

    private static byte[] fixture(boolean invalid, String value, int methods) {
        DexFileWriter writer = new DexFileWriter();
        var c = writer.visit(Opcodes.ACC_PUBLIC, OWNER, "Ljava/lang/Object;", null);
        c.visitField(Opcodes.ACC_PUBLIC | Opcodes.ACC_STATIC, new com.googlecode.d2j.Field(OWNER, "gate", "I"), 0).visitEnd();
        var gate = c.visitMethod(Opcodes.ACC_PUBLIC | Opcodes.ACC_STATIC, new Method(OWNER, "gateValue", new String[0], "I"));
        var g = gate.visitCode();
        g.visitRegister(1);
        g.visitFieldStmt(Op.SGET, 0, -1, new com.googlecode.d2j.Field(OWNER, "gate", "I"));
        g.visitStmt1R(Op.RETURN, 0);
        g.visitEnd(); gate.visitEnd();
        for (int index = 0; index < methods; index++) {
        var m = c.visitMethod(Opcodes.ACC_PUBLIC | Opcodes.ACC_STATIC, new Method(OWNER, index == 0 ? "value" : "value" + index, new String[0], "Ljava/lang/String;"));
        var code = m.visitCode();
        code.visitRegister(1);
        // The discarded long ASCII constant triggers dex2jar register mutation even for short CJK strings.
        if (!value.equals(VALUE)) code.visitConstStmt(Op.CONST_STRING, 0, VALUE);
        code.visitMethodStmt(Op.INVOKE_STATIC, new int[0], new Method(OWNER, "gateValue", new String[0], "I"));
        code.visitStmt1R(Op.MOVE_RESULT, 0);
        DexLabel positive = new DexLabel();
        code.visitJumpStmt(Op.IF_GEZ, 0, -1, positive);
        code.visitConstStmt(Op.CONST_4, 0, 0);
        code.visitStmt1R(Op.RETURN_OBJECT, 0);
        code.visitLabel(positive);
        code.visitConstStmt(Op.CONST_STRING, invalid ? 1 : 0, value);
        code.visitStmt1R(Op.RETURN_OBJECT, invalid ? 1 : 0);
        code.visitEnd(); m.visitEnd();
        }
        c.visitEnd(); writer.visitEnd();
        return writer.toByteArray();
    }


    private static void recordLimit(Path work) throws Exception {
        Path archive = archive(work.resolve("limit.jar"), fixture(false, VALUE, DexRepair.RECORD_LIMIT + 2));
        Path site = work.resolve("limit-site");
        DexIntake.Result fresh = DexIntake.translate(archive, site);
        var data = (java.util.Map<?, ?>) Json.parse(Files.readString(site.resolve("dexBundles/intake-dex.json")));
        var stored = (List<?>) data.get("records");
        check(stored.size() <= DexRepair.RECORD_LIMIT, "persisted records exceed RECORD_LIMIT: " + stored.size());
        check(stored.size() == DexRepair.RECORD_LIMIT, "overflow should fill record budget including marker");
        check(stored.get(stored.size() - 1).toString().contains("其余已省略"), "missing final omission marker");
        check(fresh.records().equals(stored), "fresh report differs from written records");
        DexIntake.Result cached = DexIntake.translate(archive, site);
        check(cached.cached() && cached.records().equals(fresh.records()), "overflow cached==fresh violated");
        System.out.println("LIMIT records=" + stored.size() + " cached==fresh=true marker=" + stored.get(stored.size() - 1));
        var legacy = new java.util.LinkedHashMap<String, Object>();
        data.forEach((key, item) -> legacy.put(key.toString(), item));
        var legacyRecords = new ArrayList<Object>(stored);
        legacyRecords.add("legacy extra 1"); legacyRecords.add("legacy extra 2");
        legacy.put("records", legacyRecords);
        Files.writeString(site.resolve("dexBundles/intake-dex.json"), Json.write(legacy));
        check(DexIntake.translate(archive, site).records().equals(legacyRecords), "read side truncated legacy records");
    }

    private static void rebuiltFrames(Path work) throws Exception {
        Path raw = work.resolve("frames-raw.jar");
        List<String> rebuilt = DexMethodRecovery.translate(fixture(false), raw);
        check(rebuilt.size() == 1, "expected one rebuilt method");
        try (ZipFile zip = new ZipFile(raw.toFile())) {
            ClassNode node = new ClassNode();
            new ClassReader(zip.getInputStream(zip.getEntry("fixture/LongString.class")).readAllBytes()).accept(node, 0);
            MethodNode value = node.methods.stream().filter(m -> m.name.equals("value")).findFirst().orElseThrow();
            boolean hasFrame = false;
            for (var instruction : value.instructions) if (instruction instanceof FrameNode) hasFrame = true;
            check(hasFrame, "rebuilt raw value() missing StackMapTable before fixFrames");
        }
    }

    private static void failedFrames(Path work) throws Exception {
        byte[] dex = fixture(false);
        Path raw = work.resolve("frame-failure-raw.jar");
        List<String> rebuilt = DexMethodRecovery.translate(dex, raw);
        byte[] recovered;
        try (ZipFile zip = new ZipFile(raw.toFile())) {
            recovered = zip.getInputStream(zip.getEntry("fixture/LongString.class")).readAllBytes();
        }
        ClassNode node = new ClassNode();
        new ClassReader(recovered).accept(node, 0);
        MethodNode bad = new MethodNode(Opcodes.ACC_PUBLIC | Opcodes.ACC_STATIC, "badFrame", "()V", null, null);
        LabelNode target = new LabelNode();
        bad.instructions.add(new InsnNode(Opcodes.POP));
        bad.instructions.add(new JumpInsnNode(Opcodes.GOTO, target));
        bad.instructions.add(target);
        bad.instructions.add(new InsnNode(Opcodes.RETURN));
        node.methods.add(bad);
        ClassWriter writer = new ClassWriter(ClassWriter.COMPUTE_MAXS);
        node.accept(writer);
        ClassWriter healthy = new ClassWriter(0);
        healthy.visit(Opcodes.V1_8, Opcodes.ACC_PUBLIC, "fixture/Healthy", null, "java/lang/Object", null);
        healthy.visitEnd();
        try (ZipOutputStream zip = new ZipOutputStream(Files.newOutputStream(raw))) {
            zip.putNextEntry(new ZipEntry("fixture/LongString.class")); zip.write(writer.toByteArray()); zip.closeEntry();
            zip.putNextEntry(new ZipEntry("fixture/Healthy.class")); zip.write(healthy.toByteArray()); zip.closeEntry();
        }
        Path site = work.resolve("frame-failure-site");
        Path bundleDir = site.resolve("dexBundles");
        Files.createDirectories(bundleDir);
        Path staging = Files.createTempDirectory(bundleDir, ".test-staging-");
        try {
            DexIntake.finishTranslation(dex, raw, staging, bundleDir.resolve("classes.jar"),
                    bundleDir.resolve("intake-dex.json"), "fixture-sha", dex.length, rebuilt);
            throw new AssertionError("frame failure on rebuilt class was silently published");
        } catch (DexIntake.DexIntakeException intake) {
            Throwable error = intake;
            check(intake.stage().equals("dex-转译"), "rebuilt frame failure stage must be STAGE_TRANSLATE: " + error);
            check(error.getMessage().contains("fixture/LongString"), "frame rejection must name rebuilt class: " + error);
            check(!Files.exists(bundleDir.resolve("classes.jar")), "frame-invalid bundle was published");
            check(!Files.exists(bundleDir.resolve("intake-dex.json")), "frame-invalid bundle was cached");
            System.out.println("FRAME_REJECTED " + error.getMessage() + " bundleExists=false recordExists=false healthyClass=1");
        }
    }

    private static void multiByte(Path work, int characters, boolean accepted) throws Exception {
        String value = "汉".repeat(characters);
        Path archive = archive(work.resolve("mutf-" + characters + ".jar"), fixture(false, value, 1));
        Path site = work.resolve("mutf-" + characters + "-site");
        if (!accepted) {
            try {
                DexIntake.translate(archive, site);
                throw new AssertionError("75000-byte MUTF-8 constant accepted");
            } catch (DexIntake.DexIntakeException error) {
                check(error.stage().equals("dex-转译"), "MUTF-8 failure stage changed: " + error);
                check(error.getMessage().contains(ID), "MUTF-8 rejection must name method: " + error);
                check(!Files.exists(site.resolve("dexBundles/classes.jar")), "oversized MUTF-8 bundle was published");
                check(!Files.exists(site.resolve("dexBundles/intake-dex.json")), "oversized MUTF-8 record was cached");
                System.out.println("MUTF_REJECTED bytes=75000 " + error.getMessage());
            }
            return;
        }
        DexIntake.Result result = DexIntake.translate(archive, site);
        check(result.records().stream().anyMatch(s -> s.contains(ID) && s.contains("重建")), "MUTF-8 fixture did not exercise recovery");
        try (URLClassLoader loader = new URLClassLoader(new java.net.URL[]{result.bundle().toUri().toURL()},
                DexMethodRecoveryContractTest.class.getClassLoader())) {
            String actual = (String) loader.loadClass("fixture.LongString").getMethod("value").invoke(null);
            check(actual.length() == characters, "MUTF-8 return length changed");
            for (int i = 0; i < characters; i++) check(actual.charAt(i) == value.charAt(i), "MUTF-8 char differs at " + i);
        }
        System.out.println("MUTF_REBUILT chars=21000 bytes=63000 everyCharacterEqual=true");
    }



    private static void helperGuard() {
        ClassNode clz = new ClassNode();
        clz.name = "fixture/LongString";
        MethodNode body = new MethodNode();
        body.instructions.add(new MethodInsnNode(Opcodes.INVOKESTATIC, "fixture/LongString",
                "$d2j$hex$decode_1", "([BI)Ljava/lang/String;", false));
        try {
            DexMethodRecovery.validateHexHelpers(clz, body, "fixture/LongString#value()Ljava/lang/String;");
            throw new AssertionError("missing helper was accepted");
        } catch (IllegalStateException error) {
            check(error.getMessage().contains("fixture/LongString#value()Ljava/lang/String;"), "helper rejection lost method: " + error);
            check(error.getMessage().contains("$d2j$hex$decode_1"), "helper rejection lost helper: " + error);
            System.out.println("HELPER_REJECTED " + error.getMessage());
        }
        clz.methods.add(new MethodNode(Opcodes.ACC_STATIC, "$d2j$hex$decode_1", "([BI)Ljava/lang/String;", null, null));
        DexMethodRecovery.validateHexHelpers(clz, body, "fixture/LongString#value()Ljava/lang/String;");
        System.out.println("HELPER_DECLARED accepted");
    }

    private static void subprocess(Path work) throws Exception {
        Path archive = archive(work.resolve("subprocess.jar"), fixture(false));
        Path direct = work.resolve("subprocess-direct.jar");
        List<String> inProcess = DexMethodRecovery.translate(fixture(false), direct);
        Path out = work.resolve("subprocess-child.jar");
        Path report = work.resolve("subprocess-child.json");
        var result = child(archive, out, report);
        check(result.exit == 0, "subprocess recovery failed: " + result.output);
        List<String> childRecords = new ArrayList<>();
        Object parsed = Json.parse(Files.readString(report, StandardCharsets.UTF_8));
        for (Object item : (List<?>) parsed) childRecords.add((String) item);
        check(childRecords.equals(inProcess), "subprocess records differ from in-process: " + childRecords + " vs " + inProcess);
        check(Files.isRegularFile(out), "subprocess recovery did not publish its jar");
        Path rejected = archive(work.resolve("subprocess-bad.jar"), fixture(true));
        var refused = child(rejected, out, report);
        check(refused.exit != 0, "subprocess accepted an unrebuildable method");
        String marker = refused.output.lines().filter(line -> line.contains("dex-转译") && line.contains(ID))
                .findFirst().orElseThrow(() -> new AssertionError("subprocess rejection lost stage+method marker: " + refused.output));
        check(!Files.exists(out), "subprocess published a rejected jar on reused path");
        check(!Files.exists(report), "subprocess left stale successful methods.json on reused path");
        System.out.println("SUBPROCESS_REUSE successThenReject=true jarExists=false reportExists=false");
        System.out.println("SUBPROCESS records=" + childRecords.size() + " match=true rejection=" + marker.strip());
    }

    private record Child(int exit, String output) {}

    private static Child child(Path archive, Path out, Path report) throws Exception {
        String java = Path.of(System.getProperty("java.home"), "bin", "java.exe").toString();
        ProcessBuilder builder = new ProcessBuilder(java, "-cp", System.getProperty("java.class.path"),
                "webhtv.spider.DexMethodRecovery", archive.toString(), out.toString(), report.toString()).redirectErrorStream(true);
        Process process = builder.start();
        String output = new String(process.getInputStream().readAllBytes(), StandardCharsets.UTF_8);
        return new Child(process.waitFor(), output);
    }

    private static void launcher(String[] args) throws Exception {
        check(args.length == 2, "launcher must provide script and PowerShell paths");
        Path real = Path.of(System.getProperty("java.home")).toAbsolutePath().normalize();
        Path expected = Files.createDirectory(Path.of(System.getProperty("java.io.tmpdir"), "dex-jdk-alias-" + System.nanoTime())).resolve("jdk");
        Process link = new ProcessBuilder("cmd.exe", "/c", "mklink", "/J", expected.toString(), real.toString()).redirectErrorStream(true).start();
        String linkOutput = new String(link.getInputStream().readAllBytes(), java.nio.charset.StandardCharsets.UTF_8);
        check(link.waitFor() == 0, "cannot create JDK alias: " + linkOutput);
        expected = expected.resolve("bin");
        Path runtimeBin = real.resolve("bin");
        String script = args[0].replace("'", "''");
        String load = "$ErrorActionPreference='Stop'; $Jdk=''; "
                + "$ast=[System.Management.Automation.Language.Parser]::ParseFile('" + script + "',[ref]$null,[ref]$null); "
                + "$f=$ast.Find({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] "
                + "-and $n.Name -eq 'Resolve-JdkBin'},$true); . ([scriptblock]::Create($f.Extent.Text)); ";
        String defaultText = (String) java.nio.file.Files.readAllLines(Path.of(args[0])).stream()
                .filter(line -> line.trim().startsWith("[string]$Jdk")).findFirst().orElseThrow();
        check(defaultText.replace(" ", "").equals("[string]$Jdk='',"), "launcher hardcodes a machine JDK path: " + defaultText);
        for (boolean fromHome : new boolean[]{true, false}) {
            Path wanted = fromHome ? expected : runtimeBin;
            ProcessBuilder process = new ProcessBuilder(args[1], "-NoProfile", "-Command", load
                    + "$bin=Resolve-JdkBin; Write-Output ('RESOLVED=' + [IO.Path]::GetFullPath($bin))").redirectErrorStream(true);
            process.environment().put("JAVA_HOME", fromHome ? expected.getParent().toString() : "");
            process.environment().put("PATH", fromHome ? "" : runtimeBin.toString());
            Process child = process.start();
            String output = new String(child.getInputStream().readAllBytes(), java.nio.charset.StandardCharsets.UTF_8);
            check(child.waitFor() == 0, "JDK discovery failed: " + output);
            String resolved = output.lines().filter(line -> line.startsWith("RESOLVED=")).findFirst().orElseThrow().substring(9);
            check(Path.of(resolved).normalize().equals(wanted), "launcher ignored " + (fromHome ? "JAVA_HOME" : "javac") + ": " + output);
        }
        int unavailable = Runtime.version().feature() + 1;
        ProcessBuilder process = new ProcessBuilder(args[1], "-NoProfile", "-Command", load
                + "Resolve-JdkBin -MinMajor " + unavailable).redirectErrorStream(true);
        process.environment().put("JAVA_HOME", expected.getParent().toString());
        process.environment().put("PATH", "");
        Process child = process.start();
        String output = new String(child.getInputStream().readAllBytes(), java.nio.charset.StandardCharsets.UTF_8);
        check(child.waitFor() != 0, "launcher accepted a JDK below the required major");
        check(output.contains("JDK " + unavailable + "+"), "JDK rejection omitted minimum major: " + output);
        System.out.println("JDK_DISCOVERY JAVA_HOME=PASS javac=PASS majorGate=PASS runtime=" + Runtime.version().feature());
    }

    private static Path archive(Path out, byte[] dex) throws Exception {
        try (ZipOutputStream zip = new ZipOutputStream(Files.newOutputStream(out))) {
            zip.putNextEntry(new ZipEntry("classes.dex")); zip.write(dex); zip.closeEntry();
        }
        return out;
    }

    private static void run(String name, Checked test, List<String> failures) {
        try { test.run(); System.out.println("PASS " + name); }
        catch (Throwable error) { failures.add(name + ": " + error); }
    }
    private static void check(boolean ok, String message) { assertions++; if (!ok) throw new AssertionError(message); }
    private interface Checked { void run() throws Exception; }
}
