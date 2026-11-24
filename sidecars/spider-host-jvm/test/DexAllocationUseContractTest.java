package webhtv.spider;

import com.googlecode.d2j.Method;
import com.googlecode.d2j.dex.writer.DexFileWriter;
import com.googlecode.d2j.reader.Op;
import java.net.URL;
import java.net.URLClassLoader;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.*;
import java.util.zip.*;
import org.objectweb.asm.*;
import org.objectweb.asm.tree.*;

/** Inherited constructor owners require the same -noverify switch as the guarded host. */
public final class DexAllocationUseContractTest {
    private static final String A="fixture/TokenA", B="fixture/TokenB", BASE="fixture/Base", MARKER="fixture/Marker", FACTORY="fixture/Use", OBJECT="java/lang/Object";
    private static int assertions;
    private static Path work;
    private record Fixture(Path raw, Path repaired, byte[] dex, DexRepair.Report report) {}
    public static void main(String[] args) throws Exception {
        work=Files.createTempDirectory("allocation-use-");
        try {
            Fixture f=fixture("unique");
            check(types(f.repaired()).equals(List.of(MARKER,A,B)),"two reordered Object tokens constrained by proven field receivers");
            check(constructors(f.repaired()).equals(List.of(OBJECT,OBJECT,OBJECT)),"constructor owners unchanged");
            try(URLClassLoader l=new URLClassLoader(new URL[]{f.repaired().toUri().toURL()},DexAllocationUseContractTest.class.getClassLoader())) {
                Object[] tokens=(Object[])l.loadClass(FACTORY.replace('/','.')).getMethod("make",Object.class,boolean.class).invoke(null,null,false);
                com.google.gson.Gson gson=new com.google.gson.Gson();
                check(gson.toJson(new Object()).equals("{}"),"raw actual Object token serializes empty shape without executing unsafe PUTFIELD");
                for(Object token:tokens){String json=gson.toJson(token);check(json.contains("identifier"),"typed token serializer retains provider identifier");}
            }
            Path again=work.resolve("again.jar");DexRepair.Report second=DexRepair.repair(f.repaired(),again,f.dex());
            check(second.retypedInstantiations()==0,"idempotence");
            check(Arrays.equals(member(f.repaired()),member(again)),"idempotent bytecode");
            check(types(fixture("superclass").repaired()).equals(List.of(MARKER,A,B)),"declared field owner superclass admits concrete subtype");
            for(String scenario:List.of("merged","parameterMerge","noUse","conflict","unknownOwner","wrongReceiver")) {
                Fixture bad=fixture(scenario);check(Arrays.equals(member(bad.raw()),member(bad.repaired())),scenario+" remains unchanged");
                check(bad.report().records().stream().anyMatch(r->r.contains("整条方法保持原样")),scenario+" reports rejection");
            }
            Fixture wide=fixture("wide");check(types(wide.repaired()).equals(List.of(MARKER,A,B)),"category-two field value still traces receiver");
            Fixture cast=fixture("cast");check(types(cast.repaired()).equals(List.of(MARKER,A,B)),"copy and CHECKCAST preserve unique origin");
            System.out.println("DexAllocationUseContractTest assertions="+assertions);
        } finally {try(var paths=Files.walk(work)){for(Path p:paths.sorted(Comparator.reverseOrder()).toList())Files.deleteIfExists(p);}}
    }
    private static Fixture fixture(String scenario)throws Exception {
        Path raw=work.resolve("raw.jar"),repaired=work.resolve("repaired.jar");
        try(ZipOutputStream z=new ZipOutputStream(Files.newOutputStream(raw))){
            entry(z,BASE,type(BASE,OBJECT));entry(z,A,type(A,BASE));entry(z,B,type(B,OBJECT));entry(z,MARKER,type(MARKER,OBJECT));entry(z,FACTORY,factory(scenario));
        }
        byte[] dex=dex();return new Fixture(raw,repaired,dex,DexRepair.repair(raw,repaired,dex));
    }
    private static byte[] dex(){
        DexFileWriter w=new DexFileWriter();for(String t:List.of(A,B,BASE,MARKER)){var c=w.visit(Opcodes.ACC_PUBLIC,"L"+t+";","L"+(t.equals(A)?BASE:OBJECT)+";",null);c.visitEnd();}
        var c=w.visit(Opcodes.ACC_PUBLIC,"L"+FACTORY+";","Ljava/lang/Object;",null);
        var m=c.visitMethod(Opcodes.ACC_PUBLIC|Opcodes.ACC_STATIC,new Method("L"+FACTORY+";","make",new String[]{"Ljava/lang/Object;","Z"},"[Ljava/lang/Object;"));
        var code=m.visitCode();code.visitRegister(20);
        for(String t:List.of(A,B,MARKER)){code.visitTypeStmt(Op.NEW_INSTANCE,10,-1,"L"+t+";");code.visitMethodStmt(Op.INVOKE_DIRECT_RANGE,new int[]{10},new Method("Ljava/lang/Object;","<init>",new String[0],"V"));}
        code.visitStmt1R(Op.RETURN_OBJECT,10);code.visitEnd();m.visitEnd();c.visitEnd();return w.toByteArray();
    }
    private static byte[] type(String name,String parent){
        ClassWriter w=new ClassWriter(0);w.visit(Opcodes.V17,Opcodes.ACC_PUBLIC,name,null,parent,null);
        if(name.equals(A)){w.visitField(Opcodes.ACC_PUBLIC,"a","Ljava/lang/String;",null,null).visitEnd();w.visitField(Opcodes.ACC_PUBLIC,"size","J",null,null).visitEnd();}if(name.equals(B))w.visitField(Opcodes.ACC_PUBLIC,"b","Ljava/lang/String;",null,null).visitEnd();
        MethodVisitor m=w.visitMethod(Opcodes.ACC_PUBLIC,"<init>","()V",null,null);m.visitCode();m.visitVarInsn(Opcodes.ALOAD,0);m.visitMethodInsn(Opcodes.INVOKESPECIAL,parent,"<init>","()V",false);m.visitInsn(Opcodes.RETURN);m.visitMaxs(1,1);m.visitEnd();w.visitEnd();return w.toByteArray();
    }
    private static byte[] factory(String scenario){
        ClassWriter w=new ClassWriter(ClassWriter.COMPUTE_MAXS);w.visit(Opcodes.V17,Opcodes.ACC_PUBLIC,FACTORY,null,OBJECT,null);
        MethodVisitor m=w.visitMethod(Opcodes.ACC_PUBLIC|Opcodes.ACC_STATIC,"make","(Ljava/lang/Object;Z)[Ljava/lang/Object;",null,null);m.visitCode();
        for(int i=0;i<3;i++){m.visitTypeInsn(Opcodes.NEW,i==0?MARKER:OBJECT);m.visitInsn(Opcodes.DUP);m.visitMethodInsn(Opcodes.INVOKESPECIAL,OBJECT,"<init>","()V",false);m.visitVarInsn(Opcodes.ASTORE,i+2);}
        if(!scenario.equals("noUse")){
            if(scenario.equals("merged")||scenario.equals("parameterMerge")){Label alt=new Label(),end=new Label();m.visitVarInsn(Opcodes.ILOAD,1);m.visitJumpInsn(Opcodes.IFEQ,alt);m.visitVarInsn(Opcodes.ALOAD,3);m.visitJumpInsn(Opcodes.GOTO,end);m.visitLabel(alt);m.visitVarInsn(Opcodes.ALOAD,scenario.equals("merged")?4:0);m.visitLabel(end);}
            else m.visitVarInsn(Opcodes.ALOAD,scenario.equals("wrongReceiver")?0:3);
            if(scenario.equals("cast"))m.visitTypeInsn(Opcodes.CHECKCAST,OBJECT);
            if(scenario.equals("wide")){m.visitInsn(Opcodes.LCONST_1);m.visitFieldInsn(Opcodes.PUTFIELD,A,"size","J");m.visitVarInsn(Opcodes.ALOAD,3);}
            m.visitLdcInsn("identifier-a");m.visitFieldInsn(Opcodes.PUTFIELD,scenario.equals("superclass")?BASE:scenario.equals("unknownOwner")?"fixture/Unknown":A,"a","Ljava/lang/String;");
            m.visitVarInsn(Opcodes.ALOAD,scenario.equals("merged")||scenario.equals("parameterMerge")||scenario.equals("wrongReceiver")?0:4);m.visitLdcInsn("identifier-b");m.visitFieldInsn(Opcodes.PUTFIELD,B,"b","Ljava/lang/String;");
            if(scenario.equals("conflict")){m.visitVarInsn(Opcodes.ALOAD,3);m.visitLdcInsn("conflict");m.visitFieldInsn(Opcodes.PUTFIELD,B,"b","Ljava/lang/String;");}
        }
        m.visitInsn(Opcodes.ICONST_2);m.visitTypeInsn(Opcodes.ANEWARRAY,OBJECT);for(int i=0;i<2;i++){m.visitInsn(Opcodes.DUP);m.visitInsn(i==0?Opcodes.ICONST_0:Opcodes.ICONST_1);m.visitVarInsn(Opcodes.ALOAD,i+3);m.visitInsn(Opcodes.AASTORE);}m.visitInsn(Opcodes.ARETURN);m.visitMaxs(0,0);m.visitEnd();w.visitEnd();return w.toByteArray();
    }
    private static List<String> types(Path jar)throws Exception {ClassNode n=node(jar);List<String> r=new ArrayList<>();for(var m:n.methods)for(var a:m.instructions)if(a instanceof TypeInsnNode t&&a.getOpcode()==Opcodes.NEW)r.add(t.desc);return r;}
    private static List<String> constructors(Path jar)throws Exception {ClassNode n=node(jar);List<String> r=new ArrayList<>();for(var m:n.methods)for(var a:m.instructions)if(a instanceof MethodInsnNode c&&c.name.equals("<init>"))r.add(c.owner);return r;}
    private static ClassNode node(Path p)throws Exception {ClassNode n=new ClassNode();new ClassReader(member(p)).accept(n,0);return n;}
    private static byte[] member(Path p)throws Exception {try(ZipFile z=new ZipFile(p.toFile())){return z.getInputStream(z.getEntry(FACTORY+".class")).readAllBytes();}}
    private static void entry(ZipOutputStream z,String name,byte[] b)throws Exception {z.putNextEntry(new ZipEntry(name+".class"));z.write(b);z.closeEntry();}
    private static void check(boolean ok,String message){assertions++;if(!ok)throw new AssertionError(message);}
}
