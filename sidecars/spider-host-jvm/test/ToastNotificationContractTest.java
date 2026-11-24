package webhtv.spider;

import android.content.Context;
import android.os.Handler;
import java.io.ByteArrayOutputStream;
import java.io.PrintStream;
import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;
import java.lang.reflect.Proxy;
import java.nio.charset.StandardCharsets;
import org.objectweb.asm.ClassWriter;
import org.objectweb.asm.Label;
import org.objectweb.asm.MethodVisitor;
import org.objectweb.asm.Opcodes;

/** Standalone runtime contract; the in-memory call site matches merge.g.x.run's Toast descriptors. */
public final class ToastNotificationContractTest extends ClassLoader implements Opcodes {
    private static int assertions;
    private static Method notify;
    private static final ByteArrayOutputStream stdout = new ByteArrayOutputStream();
    private static final ByteArrayOutputStream stderr = new ByteArrayOutputStream();

    private static void check(boolean value, String reason) {
        assertions++;
        if (!value) throw new AssertionError(reason);
    }

    private static String diagnostic() {
        return stderr.toString(StandardCharsets.UTF_8);
    }

    private void linkCallSite() throws ReflectiveOperationException {
        ClassWriter writer = new ClassWriter(ClassWriter.COMPUTE_FRAMES | ClassWriter.COMPUTE_MAXS);
        writer.visit(V17, ACC_PUBLIC | ACC_FINAL, "webhtv/spider/ToastNotificationCallSite", null,
                "java/lang/Object", null);
        MethodVisitor method = writer.visitMethod(ACC_PUBLIC | ACC_STATIC, "notify",
                "(Landroid/content/Context;Ljava/lang/CharSequence;ILjava/lang/Object;)Ljava/lang/Object;",
                null, null);
        method.visitCode();
        Label create = new Label();
        method.visitVarInsn(ALOAD, 3);
        method.visitJumpInsn(IFNULL, create);
        method.visitVarInsn(ALOAD, 3);
        method.visitTypeInsn(CHECKCAST, "android/widget/Toast");
        method.visitMethodInsn(INVOKEVIRTUAL, "android/widget/Toast", "cancel", "()V", false);
        method.visitLabel(create);
        method.visitVarInsn(ALOAD, 0);
        method.visitVarInsn(ALOAD, 1);
        method.visitVarInsn(ILOAD, 2);
        method.visitMethodInsn(INVOKESTATIC, "android/widget/Toast", "makeText",
                "(Landroid/content/Context;Ljava/lang/CharSequence;I)Landroid/widget/Toast;", false);
        method.visitVarInsn(ASTORE, 4);
        method.visitVarInsn(ALOAD, 4);
        method.visitMethodInsn(INVOKEVIRTUAL, "android/widget/Toast", "show", "()V", false);
        method.visitVarInsn(ALOAD, 4);
        method.visitInsn(ARETURN);
        method.visitMaxs(0, 0);
        method.visitEnd();
        writer.visitEnd();
        byte[] bytecode = writer.toByteArray();
        Class<?> callSite = defineClass(null, bytecode, 0, bytecode.length);
        notify = callSite.getMethod("notify", Context.class, CharSequence.class, int.class, Object.class);
    }

    private static Object notification(CharSequence text, int duration, Object previous) throws Throwable {
        try {
            return notify.invoke(null, null, text, duration, previous);
        } catch (InvocationTargetException failure) {
            throw failure.getCause();
        }
    }

    private static Object invoke(Method method, Object target, Object... arguments) throws Throwable {
        try {
            return method.invoke(target, arguments);
        } catch (InvocationTargetException failure) {
            throw failure.getCause();
        }
    }

    private static void initializationLinksAndLogs() throws Throwable {
        Object first = notification("initialize notification", 1, null);
        Class<?> toast = first.getClass();
        check(toast.getName().equals("android.widget.Toast"), "factory returns the linked Toast type");
        check(toast.getField("LENGTH_SHORT").getInt(null) == 0, "standard short duration links");
        check(toast.getField("LENGTH_LONG").getInt(null) == 1, "standard long duration links");
        String firstLog = diagnostic();
        check(firstLog.contains("android.widget.Toast#show"), "diagnostic identifies substituted API");
        check(firstLog.contains("desktop notification substitution"), "substitution is explicit, not silently dropped");
        check(firstLog.contains("no UI"), "diagnostic does not claim Android UI support");
        check(firstLog.contains("initialize notification"), "notification message remains visible");
        check(firstLog.lines().count() == 1, "one show produces one diagnostic line");

        stderr.reset();
        Object replacement = notification("replacement notification", 0, first);
        check(replacement != first, "replacement creates an independent notification");
        check(diagnostic().contains("replacement notification"), "CHECKCAST/cancel/makeText/show chain links");
        Method show = toast.getMethod("show");
        Method cancel = toast.getMethod("cancel");
        stderr.reset();
        invoke(cancel, replacement);
        invoke(cancel, replacement);
        invoke(show, replacement);
        invoke(show, replacement);
        invoke(cancel, replacement);
        check(diagnostic().lines().filter(line -> line.contains("replacement notification")).count() == 2,
                "repeated show/cancel is safe and each show remains observable");

        stderr.reset();
        boolean[] continued = {false};
        boolean posted = new Handler().post(() -> {
            try {
                notification("handler initialization", 1, replacement);
                continued[0] = true;
            } catch (Throwable failure) {
                throw new AssertionError("Handler notification linkage failed", failure);
            }
        });
        check(posted && continued[0], "synchronous Handler initialization continues beyond notification");
        check(diagnostic().contains("handler initialization"), "Handler path keeps the diagnostic");
    }

    private static void untrustedTextIsBoundedAndSingleLine() throws Throwable {
        stderr.reset();
        notification("prefix\r\nforged\t\u0000\u001b[31m\u0085\u2028\u2029\u202eend", 1, null);
        String line = diagnostic().stripTrailing();
        check(diagnostic().lines().count() == 1, "untrusted text cannot inject diagnostic lines");
        check(line.codePoints().noneMatch(code -> Character.isISOControl(code)
                        || Character.getType(code) == Character.FORMAT || code == 0x2028 || code == 0x2029),
                "control, terminal, bidi and Unicode line separators are sanitized");
        check(line.contains("prefix") && line.contains("forged") && line.contains("end"),
                "sanitization preserves useful surrounding notification content");

        stderr.reset();
        notification("界".repeat(100_000) + "TRAILER_MUST_NOT_APPEAR", 0, null);
        check(diagnostic().length() <= 640, "untrusted notification line is bounded");
        check(diagnostic().contains("..."), "truncation is explicit");
        check(!diagnostic().contains("TRAILER_MUST_NOT_APPEAR"), "large tail is not retained in output");

        stderr.reset();
        StringBuilder mutable = new StringBuilder("original snapshot");
        Object snapshot = notification(mutable, 0, null);
        mutable.replace(0, mutable.length(), "changed later");
        stderr.reset();
        invoke(snapshot.getClass().getMethod("show"), snapshot);
        check(diagnostic().contains("original snapshot") && !diagnostic().contains("changed later"),
                "notification retains a text snapshot, not the caller's mutable object");

        stderr.reset();
        notification(null, 0, null);
        notification("", 1, null);
        check(diagnostic().lines().count() == 2, "null and empty notifications remain safe and explicit");
    }

    private static void supplementaryUnicodeIsSanitizedWithoutSplittingPairs() throws Throwable {
        String supplementaryFormat = new String(Character.toChars(0x1D173));
        String rocket = new String(Character.toChars(0x1F680));
        stderr.reset();
        notification("before" + supplementaryFormat + rocket + "after", 1, null);
        check(diagnostic().codePoints().noneMatch(code -> Character.getType(code) == Character.FORMAT),
                "supplementary FORMAT U+1D173 is sanitized by code point");
        check(diagnostic().contains("before") && diagnostic().contains(rocket) && diagnostic().contains("after"),
                "ordinary supplementary text survives sanitization");
        check(diagnostic().lines().count() == 1, "supplementary sanitization retains one diagnostic line");

        String marker = "no UI): ";
        for (int prefixLength : new int[]{510, 511}) {
            stderr.reset();
            notification("a".repeat(prefixLength) + rocket + "tail", 0, null);
            String line = diagnostic().stripTrailing();
            String message = line.substring(line.indexOf(marker) + marker.length());
            check(message.endsWith("..."), "supplementary boundary truncation stays explicit");
            check(message.length() <= 515, "snapshot prefix is bounded to 512 UTF-16 units plus truncation marker");
            check(message.codePoints().noneMatch(code -> code >= 0xD800 && code <= 0xDFFF),
                    "UTF-16 snapshot does not split a supplementary pair");
            check(message.equals("a".repeat(prefixLength) + (prefixLength == 510 ? rocket : "") + "..."),
                    "supplementary pair is preserved whole or omitted whole at the UTF-16 bound");
        }
    }

    private static void unsupportedApisStayUnsupported() throws Throwable {
        Class<?> toast = Class.forName("android.widget.Toast");
        try {
            toast.getMethod("makeText", Context.class, int.class, int.class);
            throw new AssertionError("resource-id overload must not be guessed");
        } catch (NoSuchMethodException expected) {
            check(true, "unknown resource-id API is absent");
        }
        check(toast.getConstructors().length == 0, "no unsupported UI constructor is advertised");
        for (java.lang.reflect.Field field : toast.getDeclaredFields()) {
            check(!Context.class.isAssignableFrom(field.getType()), "notification must not retain Context");
        }
        for (Method method : toast.getDeclaredMethods()) {
            for (Class<?> parameter : method.getParameterTypes()) {
                check(!parameter.getName().startsWith("android.view."), "no Android window/view dependency");
            }
        }
    }

    private static void sourceFailuresAreNotSuppressed() throws Throwable {
        Throwable[] failures = {new IllegalStateException("source text failure"),
                new UnsatisfiedLinkError("source native failure")};
        for (Throwable original : failures) {
            CharSequence broken = (CharSequence) Proxy.newProxyInstance(
                    ToastNotificationContractTest.class.getClassLoader(), new Class<?>[]{CharSequence.class},
                    (proxy, method, args) -> { throw original; });
            stderr.reset();
            try {
                notification(broken, 1, null);
                throw new AssertionError("source failure was suppressed");
            } catch (Throwable observed) {
                check(observed == original, "original source/native failure propagates unchanged: " + observed);
            }
            check(diagnostic().isEmpty(), "failed notification is not falsely logged as delivered");
        }
    }

    public static void main(String[] args) throws Throwable {
        PrintStream previousOut = System.out;
        PrintStream previousErr = System.err;
        Throwable failure = null;
        try (PrintStream out = new PrintStream(stdout, true, StandardCharsets.UTF_8);
             PrintStream err = new PrintStream(stderr, true, StandardCharsets.UTF_8)) {
            System.setOut(out);
            System.setErr(err);
            new ToastNotificationContractTest().linkCallSite();
            initializationLinksAndLogs();
            untrustedTextIsBoundedAndSingleLine();
            supplementaryUnicodeIsSanitizedWithoutSplittingPairs();
            unsupportedApisStayUnsupported();
            sourceFailuresAreNotSuppressed();
            check(stdout.size() == 0, "notification never writes to stdout IPC");
        } catch (Throwable observed) {
            failure = observed;
        } finally {
            System.setOut(previousOut);
            System.setErr(previousErr);
        }
        if (failure != null) {
            System.err.println("FAIL ToastNotificationContractTest after " + assertions + " assertions; captured stdout bytes=" + stdout.size());
            throw failure;
        }
        System.err.println("PASS ToastNotificationContractTest: " + assertions + " assertions; captured stdout bytes=" + stdout.size());
    }
}
