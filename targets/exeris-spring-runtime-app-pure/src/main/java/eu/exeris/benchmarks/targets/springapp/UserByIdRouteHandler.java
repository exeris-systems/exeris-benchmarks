package eu.exeris.benchmarks.targets.springapp;

import eu.exeris.kernel.spi.http.HttpMethod;
import eu.exeris.kernel.spi.http.HttpStatus;
import eu.exeris.spring.runtime.web.ExerisRequestHandler;
import eu.exeris.spring.runtime.web.ExerisRoute;
import eu.exeris.spring.runtime.web.ExerisServerRequest;
import eu.exeris.spring.runtime.web.ExerisServerResponse;

import org.springframework.http.MediaType;
import org.springframework.stereotype.Component;

import java.util.Map;

/**
 * Light single-read contract: {@code GET /api/v1/user?id=N -> {id, username}}.
 *
 * <p>Pure-mode counterpart of the compat arm's {@code SpringBenchmarkController.readUser}.
 * The service and repository beans below it are byte-identical to the compat target's — only
 * the path from socket to method call differs, which is the whole point of the axis.
 */
@Component
@ExerisRoute(method = HttpMethod.GET, path = "/api/v1/user")
public class UserByIdRouteHandler implements ExerisRequestHandler {

    private final UserService userService;
    private final JsonEncoder jsonEncoder;

    public UserByIdRouteHandler(UserService userService, JsonEncoder jsonEncoder) {
        this.userService = userService;
        this.jsonEncoder = jsonEncoder;
    }

    @Override
    public ExerisServerResponse handle(ExerisServerRequest request) {
        Map<String, String> params = QueryParams.parse(request.path());
        String rawId = params.get("id");
        if (rawId == null || rawId.isBlank()) {
            return ExerisServerResponse.status(HttpStatus.BAD_REQUEST);
        }

        long id;
        try {
            id = Long.parseLong(rawId);
        } catch (NumberFormatException exception) {
            return ExerisServerResponse.status(HttpStatus.BAD_REQUEST);
        }

        UserSummary user = userService.findUserById(id);
        if (user == null) {
            return ExerisServerResponse.status(HttpStatus.NOT_FOUND);
        }
        return ExerisServerResponse.ok()
                .contentType(MediaType.APPLICATION_JSON)
                .body(jsonEncoder.encode(user));
    }
}
