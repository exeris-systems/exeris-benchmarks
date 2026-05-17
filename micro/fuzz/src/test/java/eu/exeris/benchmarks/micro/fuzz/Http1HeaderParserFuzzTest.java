package eu.exeris.benchmarks.micro.fuzz;

import com.code_intelligence.jazzer.junit.FuzzTest;
import eu.exeris.kernel.core.http.http1.Http1RequestParser;
import java.lang.foreign.Arena;
import java.lang.foreign.MemorySegment;

class Http1HeaderParserFuzzTest {

  // Tighter than RFC defaults — keeps fuzz iterations bounded so that an
  // attacker-supplied length field can't make a single iteration drag.
  private static final int MAX_HEADERS = 64;
  private static final int MAX_HEADER_SIZE = 4096;

  @FuzzTest(maxDuration = "60s")
  void parseHeaders_neverThrowsUnexpected(byte[] data) {
    if (data == null || data.length == 0) return;

    try (Arena arena = Arena.ofConfined()) {
      MemorySegment seg = FuzzInputs.intoConfinedSegment(arena, data);
      try {
        Http1RequestParser.parseHeaders(
            seg, 0L, data.length,
            MAX_HEADERS, MAX_HEADER_SIZE,
            NoOpHeaderVisitor.INSTANCE);
      } catch (Throwable t) {
        if (!ExpectedThrowables.isExpected(t, ExpectedThrowables.HTTP1_PARSE_EXPECTED)) {
          throw t;
        }
      }
    }
  }

  // The kernel's HeaderVisitor SAM lives in eu.exeris.kernel.core.http.http1.
  // We use a no-op so fuzzing exercises the parser path, not visitor logic.
  // If the SAM signature changes, the compile error here is intentional:
  // pin the kernel snapshot in pom.xml and update this shim.
  private enum NoOpHeaderVisitor
      implements eu.exeris.kernel.core.http.http1.HeaderVisitor {
    INSTANCE;

    @Override
    public void onHeader(MemorySegment seg, long nameOffset, long nameLength,
                         long valueOffset, long valueLength) {
      // intentionally empty — fuzz target only cares whether the parser itself
      // crashes; visitor side effects are out of scope here.
    }
  }
}
