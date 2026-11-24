package webhtv.spider;

import com.googlecode.d2j.Method;
import com.googlecode.d2j.dex.writer.DexFileWriter;
import com.googlecode.d2j.reader.Op;
import com.googlecode.d2j.visitors.DexCodeVisitor;
import java.lang.reflect.Field;
import java.util.List;
import java.util.Map;
import java.util.Set;
import org.objectweb.asm.Opcodes;

public final class DexRangeConstructorContractTest {
    private static int assertions;
    private static final String KEY = "fixture/Range.make()Ljava/lang/Object;";

    public static void main(String[] args) throws Exception {
        check("(IIIII)V".equals(descriptor(Op.INVOKE_DIRECT_RANGE, "<init>", new int[]{10,11,12,13,14,15}, 10, 5)), "range receiver and more than five registers are paired");
        check("()V".equals(descriptor(Op.INVOKE_DIRECT, "<init>", new int[]{2}, 2, 0)), "normal direct still paired");
        check(descriptor(Op.INVOKE_STATIC_RANGE, "<init>", new int[]{10}, 10, 0) == null, "unrelated invocation ignored");
        check(descriptor(Op.INVOKE_DIRECT_RANGE, "notConstructor", new int[]{10}, 10, 0) == null, "nonconstructor ignored");
        check(descriptor(Op.INVOKE_DIRECT_RANGE, "<init>", new int[]{11}, 10, 0) == null, "wrong receiver does not pair");
        check(descriptor(Op.INVOKE_DIRECT_RANGE, "<init>", new int[0], 10, 0) == null, "empty register list ignored");
        System.out.println("DexRangeConstructorContractTest assertions=" + assertions);
    }

    private static String descriptor(Op op, String name, int[] regs, int allocated, int arguments) throws Exception {
        DexFileWriter writer = new DexFileWriter();
        var c = writer.visit(Opcodes.ACC_PUBLIC, "Lfixture/Range;", "Ljava/lang/Object;", null);
        var m = c.visitMethod(Opcodes.ACC_PUBLIC | Opcodes.ACC_STATIC, new Method("Lfixture/Range;", "make", new String[0], "Ljava/lang/Object;"));
        DexCodeVisitor code = m.visitCode();code.visitRegister(20);
        code.visitTypeStmt(Op.NEW_INSTANCE, allocated, -1, "Lfixture/Token;");
        String[] params = new String[arguments];java.util.Arrays.fill(params,"I");
        code.visitMethodStmt(op, regs, new Method("Ljava/lang/Object;", name, params, "V"));
        code.visitStmt1R(Op.RETURN_OBJECT, allocated);code.visitEnd();m.visitEnd();c.visitEnd();
        java.lang.reflect.Method index = DexRepair.class.getDeclaredMethod("indexNewInstances", byte[].class, Set.class);index.setAccessible(true);
        Map<?,?> result = (Map<?,?>)index.invoke(null, writer.toByteArray(), Set.of(KEY));
        Object site = ((List<?>)result.get(KEY)).get(0);Field descriptor = site.getClass().getDeclaredField("initDesc");descriptor.setAccessible(true);
        return (String)descriptor.get(site);
    }
    private static void check(boolean ok, String message) { assertions++;if(!ok)throw new AssertionError(message); }
}
