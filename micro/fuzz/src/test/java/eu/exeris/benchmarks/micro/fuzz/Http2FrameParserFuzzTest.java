package eu.exeris.benchmarks.micro.fuzz;

import com.code_intelligence.jazzer.junit.FuzzTest;
import eu.exeris.kernel.core.http.http2.Http2FrameParser;
import java.lang.foreign.Arena;
import java.lang.foreign.MemorySegment;

class Http2FrameParserFuzzTest {

  // RFC 7540 §4.1: frame header is fixed 9 bytes.
  private static final int H2_FRAME_HEADER_SIZE = 9;

  @FuzzTest(maxDuration = "60s")
  void parseFrameHeader_neverThrowsUnexpected(byte[] data) {
    if (data == null || data.length < H2_FRAME_HEADER_SIZE) return;

    try (Arena arena = Arena.ofConfined()) {
      MemorySegment seg = FuzzInputs.intoConfinedSegment(arena, data);
      try {
        Http2FrameParser.parseHeader(seg, 0L);
      } catch (Throwable t) {
        if (!ExpectedThrowables.isExpected(t, ExpectedThrowables.HTTP2_PARSE_EXPECTED)) {
          throw t;
        }
      }
    }
  }
}
