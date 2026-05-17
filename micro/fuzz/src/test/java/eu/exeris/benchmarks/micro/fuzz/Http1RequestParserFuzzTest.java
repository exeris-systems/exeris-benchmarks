package eu.exeris.benchmarks.micro.fuzz;

import com.code_intelligence.jazzer.junit.FuzzTest;
import eu.exeris.kernel.core.http.http1.Http1RequestParser;
import java.lang.foreign.Arena;
import java.lang.foreign.MemorySegment;

class Http1RequestParserFuzzTest {

  @FuzzTest(maxDuration = "60s")
  void parseRequestLine_neverThrowsUnexpected(byte[] data) {
    if (data == null || data.length == 0) return;

    try (Arena arena = Arena.ofConfined()) {
      MemorySegment seg = FuzzInputs.intoConfinedSegment(arena, data);
      try {
        Http1RequestParser.parseRequestLine(seg, 0L, data.length);
      } catch (Throwable t) {
        if (!ExpectedThrowables.isExpected(t, ExpectedThrowables.HTTP1_PARSE_EXPECTED)) {
          throw t;
        }
      }
    }
  }
}
