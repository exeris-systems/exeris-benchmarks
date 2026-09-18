import java.lang.foreign.*;
import java.lang.reflect.*;
public class ValueCheck {
  static void p(Class<?> c){
    try { System.out.printf("  %-46s isValue=%-5s isInterface=%-5s isSealed=%s%n",
        c.getName(), c.isValue(), c.isInterface(), c.isSealed()); }
    catch (Throwable t){ System.out.println("  "+c.getName()+" -> "+t); }
  }
  public static void main(String[] a) throws Exception {
    System.out.println("JDK: "+Runtime.version());
    System.out.println("== MemorySegment ==");
    Class<?> ms = MemorySegment.class;
    p(ms);
    Class<?>[] perms = ms.getPermittedSubclasses();
    System.out.println("  permits: "+(perms==null?"<not sealed>":java.util.Arrays.toString(perms)));
    System.out.println("== java.lang.foreign public API ==");
    for (String n : new String[]{"java.lang.foreign.MemorySegment","java.lang.foreign.Arena",
        "java.lang.foreign.MemoryLayout","java.lang.foreign.ValueLayout","java.lang.foreign.Linker",
        "java.lang.foreign.SegmentAllocator","java.lang.foreign.MemorySegment$Scope",
        "java.lang.foreign.FunctionDescriptor","java.lang.foreign.SymbolLookup"}) {
      try { p(Class.forName(n)); } catch (Throwable t){ System.out.println("  "+n+" -> "+t); }
    }
    System.out.println("== impls (jdk.internal.foreign) ==");
    for (String n : new String[]{"jdk.internal.foreign.NativeMemorySegmentImpl",
        "jdk.internal.foreign.MappedMemorySegmentImpl","jdk.internal.foreign.HeapMemorySegmentImpl",
        "jdk.internal.foreign.AbstractMemorySegmentImpl","jdk.internal.foreign.MemorySessionImpl"}) {
      try { p(Class.forName(n)); } catch (Throwable t){ System.out.println("  "+n+" -> "+t.getClass().getSimpleName()); }
    }
    System.out.println("== control: known migrated value classes ==");
    for (Class<?> c : new Class<?>[]{Integer.class, Long.class, Double.class, String.class, Object.class}) p(c);
  }
}
