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

  // HeaderVisitor is NESTED in Http1RequestParser and takes materialised Strings. This shim
  // originally declared a top-level eu.exeris.kernel.core.http.http1.HeaderVisitor with an
  // offset-based onHeader(MemorySegment, long, long, long, long) — a type that has never
  // existed in any released kernel (checked v0.5.0 through v0.11.0), so this test could not
  // compile against anything and the whole fuzz family had never run.
  //
  // Note for anyone reading this while changing the parser: the String materialisation happens
  // INSIDE parseHeaders, before the visitor is called, so a no-op visitor does not avoid it.
  // Fuzzing here therefore covers the allocation path as well as the parse path.
  //
  // If the SAM signature changes again, the compile error here is intentional: re-pin the
  // kernel version and update this shim rather than loosening the type.
  private enum NoOpHeaderVisitor implements Http1RequestParser.HeaderVisitor {
    INSTANCE;

    @Override
    public void onHeader(String name, String value) {
      // intentionally empty — fuzz target only cares whether the parser itself
      // crashes; visitor side effects are out of scope here.
    }
  }
}
