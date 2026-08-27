package eu.exeris.benchmarks.micro.fuzz;

import eu.exeris.kernel.core.http.http1.Http1RequestParser;
import java.util.Set;

/**
 * Whitelist of throwables that parsers are documented to raise on malformed
 * input. A fuzz iteration that produces one of these is NOT a finding.
 *
 * Everything else — NPE, AssertionError, OOM, StackOverflow, anything in
 * {@link Error} that isn't on the whitelist — IS a finding and Jazzer will
 * record it as a crash.
 *
 * <p><b>Kernel types are referenced as class literals, never as strings.</b>
 * The HTTP/1 entry used to be the string literal
 * {@code "eu.exeris.kernel.core.http.http1.Http1ParseException"} — a top-level
 * name that has never existed in any kernel jar. The real type is
 * {@code Http1RequestParser$Http1ParseException}, nested, and it extends
 * {@code ExerisKernelException} rather than any JDK type on this list, so
 * {@link #isExpected} walked the whole superclass chain and matched nothing.
 * The whitelist was inert: every documented parse rejection would have been
 * reported as a crash.
 *
 * <p>That defect survived a 119.9 M-input campaign because
 * {@code parseRequestLine} did not raise it on any of those inputs; it
 * surfaced on the FIRST header-block campaign, at iteration 2, on
 * "malformed header field (missing ':')" — the most ordinary rejection the
 * parser has. It is the same failure as the {@code HeaderVisitor} shim: a
 * kernel type named by guess instead of against the jar.
 *
 * <p>A class literal cannot be wrong silently. If the kernel moves or renames
 * the type, this file stops compiling — which is the intended behaviour, the
 * same contract the visitor shim in {@code Http1HeaderParserFuzzTest} carries.
 * JDK types stay as string literals: they are stable, and naming them here
 * would not catch anything.
 */
final class ExpectedThrowables {

  static final Set<String> HTTP1_PARSE_EXPECTED = Set.of(
      Http1RequestParser.Http1ParseException.class.getName(),
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
