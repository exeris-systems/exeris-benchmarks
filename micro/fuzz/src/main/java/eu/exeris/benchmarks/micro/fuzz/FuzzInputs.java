package eu.exeris.benchmarks.micro.fuzz;

import java.lang.foreign.Arena;
import java.lang.foreign.MemorySegment;
import java.lang.foreign.ValueLayout;

/**
 * Helpers for wrapping a Jazzer-supplied byte[] in a confined Arena
 * MemorySegment, so each fuzz iteration uses an Arena lifecycle identical to
 * the per-request Arena lifecycle the kernel uses in production.
 *
 * Callers are responsible for closing the Arena (use try-with-resources).
 */
public final class FuzzInputs {

  public static MemorySegment intoConfinedSegment(Arena arena, byte[] data) {
    MemorySegment seg = arena.allocate(data.length);
    MemorySegment.copy(data, 0, seg, ValueLayout.JAVA_BYTE, 0, data.length);
    return seg;
  }

  private FuzzInputs() {}
}
