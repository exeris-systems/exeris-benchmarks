import java.lang.reflect.*;
public class NRProbe {
    static value class V16 { final long a,b; V16(long a,long b){this.a=a;this.b=b;} }
    static value class H2  { final String n,v; H2(String n,String v){this.n=n;this.v=v;} }
    public static void main(String[] args) throws Exception {
        Class<?> vc = Class.forName("jdk.internal.value.ValueClass");
        System.out.println("ValueClass found: " + vc);
        for (Method m : vc.getMethods()) {
            if (m.getName().toLowerCase().contains("array")) System.out.println("  " + m);
        }
        for (String mn : new String[]{"newNullRestrictedNonAtomicArray","newNullRestrictedAtomicArray","newNullableAtomicArray"}) {
            for (Class<?> el : new Class<?>[]{V16.class, H2.class}) {
                try {
                    Method m = null;
                    for (Method c : vc.getMethods()) if (c.getName().equals(mn)) m = c;
                    if (m == null) { System.out.println("  " + mn + " : absent"); break; }
                    Object arr = m.getParameterCount() == 3
                        ? m.invoke(null, el, 4, el.getDeclaredConstructor(
                              el == V16.class ? new Class<?>[]{long.class,long.class}
                                              : new Class<?>[]{String.class,String.class})
                              .newInstance(el == V16.class ? new Object[]{0L,0L} : new Object[]{"",""}))
                        : m.invoke(null, el, 4);
                    System.out.println("  " + mn + "(" + el.getSimpleName() + ") -> " + arr.getClass());
                } catch (Throwable t) {
                    System.out.println("  " + mn + "(" + el.getSimpleName() + ") -> " + t.getClass().getSimpleName() + ": " + t.getMessage());
                }
            }
        }
    }
}
