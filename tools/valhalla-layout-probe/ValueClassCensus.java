import java.util.*;
public class ValueClassCensus {
  public static void main(String[] a) throws Exception {
    System.out.println("JDK: "+Runtime.version());
    System.out.println("== AbstractMemorySegmentImpl subclass tree ==");
    walk(Class.forName("jdk.internal.foreign.AbstractMemorySegmentImpl"), 1);
    System.out.println("== java.base value-class census ==");
    var fs = java.nio.file.FileSystems.getFileSystem(java.net.URI.create("jrt:/"));
    List<String> vals = new ArrayList<>();
    int total=0, foreign=0, foreignValue=0;
    try (var s = java.nio.file.Files.walk(fs.getPath("/modules/java.base"))) {
      for (var p : (Iterable<java.nio.file.Path>) s::iterator) {
        String f = p.toString();
        if (!f.endsWith(".class")) continue;
        String cn = f.substring("/modules/java.base/".length(), f.length()-6).replace('/','.');
        Class<?> c;
        try { c = Class.forName(cn, false, null); } catch (Throwable t) { continue; }
        total++;
        boolean isForeign = cn.startsWith("java.lang.foreign") || cn.startsWith("jdk.internal.foreign");
        if (isForeign) foreign++;
        boolean v;
        try { v = c.isValue(); } catch (Throwable t) { continue; }
        if (v) { vals.add(cn); if (isForeign) foreignValue++; }
      }
    }
    System.out.println("  classes scanned:            "+total);
    System.out.println("  value classes in java.base: "+vals.size());
    System.out.println("  foreign-package classes:    "+foreign);
    System.out.println("  ...of which value classes:  "+foreignValue);
    Collections.sort(vals);
    System.out.println("  value classes: "+vals);
  }
  static void walk(Class<?> c, int d) {
    Class<?>[] p = c.getPermittedSubclasses();
    if (p == null) return;
    for (Class<?> s : p) {
      System.out.printf("  %s%-44s value=%-5s abstract=%s%n", "  ".repeat(d), s.getName(),
        s.isValue(), java.lang.reflect.Modifier.isAbstract(s.getModifiers()));
      walk(s, d+1);
    }
  }
}
