package eu.exeris.benchmarks.targets.springapp;

import eu.exeris.kernel.spi.http.HttpMethod;
import eu.exeris.spring.runtime.web.ExerisRequestHandler;
import eu.exeris.spring.runtime.web.ExerisRoute;
import eu.exeris.spring.runtime.web.ExerisServerRequest;
import eu.exeris.spring.runtime.web.ExerisServerResponse;

import org.springframework.http.MediaType;
import org.springframework.stereotype.Component;

/**
 * Heavy aggregate contract: {@code GET /api/v1/users} — 10 users x 10 friends x 10 interests.
 *
 * <p>Pure-mode counterpart of the compat arm's {@code SpringBenchmarkController.readUsers}.
 */
@Component
@ExerisRoute(method = HttpMethod.GET, path = "/api/v1/users")
public class UsersRouteHandler implements ExerisRequestHandler {

    private final UserService userService;
    private final JsonEncoder jsonEncoder;

    public UsersRouteHandler(UserService userService, JsonEncoder jsonEncoder) {
        this.userService = userService;
        this.jsonEncoder = jsonEncoder;
    }

    @Override
    public ExerisServerResponse handle(ExerisServerRequest request) {
        return ExerisServerResponse.ok()
                .contentType(MediaType.APPLICATION_JSON)
                .body(jsonEncoder.encode(userService.findFrozenContractUsers()));
    }
}
