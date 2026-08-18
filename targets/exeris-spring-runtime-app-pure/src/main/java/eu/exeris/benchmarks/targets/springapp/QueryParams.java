package eu.exeris.benchmarks.targets.springapp;

import java.net.URLDecoder;
import java.nio.charset.StandardCharsets;
import java.util.HashMap;
import java.util.Map;

/**
 * Query-string parsing for pure-mode handlers.
 *
 * <p>The kernel hands the handler the raw request target: {@code HttpRequest.path()} retains
 * the query string (this is why exeris-community-app's route handler parses it out of
 * {@code path()} rather than from a separate accessor). Compatibility mode hides this behind
 * Spring MVC's {@code @RequestParam} resolution; pure mode does not, so the parsing lives here.
 *
 * <p>Deliberately a transcription of {@code CommunityBenchmarkRouteHandler.parseQueryParams} —
 * same blank/missing-'='/trailing-'=' handling — so the native Exeris arms agree on what a
 * malformed query means and the comparison is not measuring two different parsers.
 */
final class QueryParams {

    private QueryParams() {
    }

    static Map<String, String> parse(String path) {
        int queryIndex = path.indexOf('?');
        if (queryIndex < 0 || queryIndex >= path.length() - 1) {
            return Map.of();
        }

        String query = path.substring(queryIndex + 1);
        Map<String, String> params = new HashMap<>();
        for (String pair : query.split("&")) {
            if (pair.isBlank()) {
                continue;
            }
            int equalsIndex = pair.indexOf('=');
            if (equalsIndex <= 0 || equalsIndex == pair.length() - 1) {
                continue;
            }
            params.putIfAbsent(
                    decode(pair.substring(0, equalsIndex)),
                    decode(pair.substring(equalsIndex + 1)));
        }
        return params;
    }

    private static String decode(String value) {
        return URLDecoder.decode(value, StandardCharsets.UTF_8);
    }
}
