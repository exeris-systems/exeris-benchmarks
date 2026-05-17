package eu.exeris.benchmarks.micro.fuzz;

import java.util.Set;

/**
 * Whitelist of throwables that parsers are documented to raise on malformed
 * input. A fuzz iteration that produces one of these is NOT a finding.
 *
 * Everything else — NPE, AssertionError, OOM, StackOverflow, anything in
 * {@link Error} that isn't on the whitelist — IS a finding and Jazzer will
 * record it as a crash.
 */
final class ExpectedThrowables {

  static final Set<String> HTTP1_PARSE_EXPECTED = Set.of(
      "eu.exeris.kernel.core.http.http1.Http1ParseException",
      "java.lang.IndexOutOfBoundsException",
      "java.lang.IllegalArgumentException",
      "java.nio.BufferUnderflowException"
  );

  static final Set<String> HTTP2_PARSE_EXPECTED = Set.of(
      "java.lang.IndexOutOfBoundsException",
      "java.lang.IllegalArgumentException",
      "java.nio.BufferUnderflowException"
  );

  static boolean isExpected(Throwable t, Set<String> whitelist) {
    for (Class<?> c = t.getClass(); c != null && c != Object.class; c = c.getSuperclass()) {
      if (whitelist.contains(c.getName())) {
        return true;
      }
    }
    return false;
  }

  private ExpectedThrowables() {}
}
