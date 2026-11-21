package webhtv.spider;

import java.io.ByteArrayOutputStream;
import java.io.PrintStream;
import java.nio.charset.StandardCharsets;
import java.util.List;
import java.util.Map;
import java.util.concurrent.CancellationException;

/** Run against host.jar; every failure traverses the real playerContent reflection boundary. */
public final class LinkageDiagnosticsContractTest {
    private static int assertions;
    private static int failures;

    public static final class Fixture {
        private final Throwable failure;
        Fixture(Throwable failure) { this.failure = failure; }
        public String playerContent(String flag, String id, List<String> vipFlags) throws Throwable {
            throw failure.fillInStackTrace();
        }
    }

    private record Observed(RuntimeException failure, String stderr) {}

    private static Observed play(Throwable failure) {
        CatVodSpiderAdapter adapter = new CatVodSpiderAdapter(new Fixture(failure), null);
        PrintStream previous = System.err;
        ByteArrayOutputStream bytes = new ByteArrayOutputStream();
        try (PrintStream capture = new PrintStream(bytes, true, StandardCharsets.UTF_8)) {
            System.setErr(capture);
            try {
                adapter.play(Map.of("id", "fixture-episode", "flag", "fixture"), new CallContext("fixture", 0));
                throw new AssertionError("expected source failure");
            } catch (RuntimeException mapped) {
                return new Observed(mapped, bytes.toString(StandardCharsets.UTF_8));
            }
        } finally {
            System.setErr(previous);
        }
    }

    private static void check(boolean value, String reason) {
        assertions++;
        if (!value) throw new AssertionError(reason);
    }

    private static void linkage(Throwable original, String kind, String detail, boolean android) {
        Observed observed = play(original);
        RuntimeException mapped = observed.failure();
        check(mapped instanceof UnsupportedOperationException, "linkage keeps unsupported semantics: " + mapped);
        check(mapped.getMessage().contains(kind), "actual error kind lost: " + mapped.getMessage());
        check(mapped.getMessage().contains(detail), "actual linkage detail lost: " + mapped.getMessage());
        check(!mapped.getMessage().contains("Android 类：Method"), "method token is not a class");
        check(!mapped.getMessage().contains("只支持不碰 UI"), "failure does not prove a UI dependency");
        if (!android) check(!mapped.getMessage().contains("Android 类"), "non-Android failure mislabeled: " + mapped);
        check(mapped.getCause() == original, "entire original cause chain retained");
        check(observed.stderr().contains("Fixture.playerContent"), "original source frame retained on stderr");
    }

    private static void run(String name, Runnable test) {
        try { test.run(); System.out.println("PASS " + name); }
        catch (AssertionError failure) { failures++; System.out.println("FAIL " + name + ": " + failure.getMessage()); }
    }

    public static void main(String[] args) {
        run("missing Android class", () -> {
            NoClassDefFoundError error = new NoClassDefFoundError("android/widget/AbsentWidget");
            error.initCause(new ClassNotFoundException("android.widget.AbsentWidget"));
            linkage(error, "NoClassDefFoundError", "android.widget.AbsentWidget", true);
        });
        run("missing third-party class", () -> linkage(new NoClassDefFoundError("org/example/MissingCodec"),
                "NoClassDefFoundError", "org.example.MissingCodec", false));
        run("NoSuchMethodError signature", () -> linkage(new NoSuchMethodError("'void android.os.Bundle.absent(int)'"),
                "NoSuchMethodError", "'void android.os.Bundle.absent(int)'", false));
        run("AbstractMethodError Method prefix", () -> linkage(new AbstractMethodError(
                "Method fixture/Codec.decode(Ljava/lang/String;)Ljava/lang/String; is abstract"),
                "AbstractMethodError", "Method fixture/Codec.decode(Ljava/lang/String;)Ljava/lang/String; is abstract", false));
        run("ICCE exact kind", () -> linkage(new IncompatibleClassChangeError("Expected static method 'void fixture.Codec.decode()'"),
                "IncompatibleClassChangeError", "Expected static method 'void fixture.Codec.decode()'", false));
        run("proven Anime Comparator constant-pool error", () -> linkage(new IncompatibleClassChangeError(
                "Method 'java.util.Comparator java.util.Comparator.comparing(java.util.function.Function)' must be InterfaceMethodref constant"),
                "IncompatibleClassChangeError", "Method 'java.util.Comparator java.util.Comparator.comparing(java.util.function.Function)' must be InterfaceMethodref constant", false));
        run("VerifyError exact detail", () -> linkage(new VerifyError("Bad type on operand stack at fixture.Codec.decode()V"),
                "VerifyError", "Bad type on operand stack at fixture.Codec.decode()V", false));
        run("initialization failure is not a missing class", () -> linkage(
                new NoClassDefFoundError("Could not initialize class android.os.Broken"),
                "NoClassDefFoundError", "Could not initialize class android.os.Broken", false));
        run("wrapped linkage retains outer cause", () -> linkage(new RuntimeException("source wrapper",
                new NoSuchMethodError("fixture.Codec.decode()V")), "NoSuchMethodError", "fixture.Codec.decode()V", false));
        run("resource error remains resource failure", () -> {
            OutOfMemoryError error = new OutOfMemoryError("fixture heap exhausted");
            RuntimeException mapped = play(error).failure();
            check(mapped instanceof IllegalStateException, "OOM is not unsupported");
            check(mapped.getMessage().contains("OutOfMemoryError"), "OOM kind retained");
            check(!mapped.getMessage().contains("Android"), "OOM not Android");
            check(mapped.getCause() == error, "OOM cause retained");
        });
        run("declared unsupported and invalid argument unchanged", () -> {
            UnsupportedOperationException unsupported = new UnsupportedOperationException("fixture unsupported");
            IllegalArgumentException invalid = new IllegalArgumentException("fixture invalid");
            check(play(unsupported).failure() == unsupported, "unsupported identity");
            check(play(invalid).failure() == invalid, "invalid argument identity");
        });
        run("cancelled call never invokes source", () -> {
            CallContext context = new CallContext("cancelled", 0);
            context.markCancelled();
            try {
                new CatVodSpiderAdapter(new Fixture(new AssertionError("must not invoke")), null)
                        .play(Map.of("id", "fixture-episode"), context);
                throw new AssertionError("expected cancellation");
            } catch (CancellationException expected) { check(true, "cancellation preserved"); }
        });
        run("non-linkage Error is not an Android class", () -> {
            RuntimeException mapped = play(new AssertionError("fixture assertion")).failure();
            check(mapped instanceof UnsupportedOperationException, "existing Error unsupported semantics");
            check(mapped.getMessage().contains("AssertionError"), "actual Error kind retained");
            check(!mapped.getMessage().contains("Android 类"), "assertion not Android");
        });
        System.out.println("LinkageDiagnosticsContractTest assertions=" + assertions + " failures=" + failures);
        if (failures != 0) throw new AssertionError(failures + " contract cases failed");
    }
}
