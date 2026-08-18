package eu.exeris.benchmarks.targets.springapp;

import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.util.List;
import java.util.Map;

@RestController
public class SpringBenchmarkController {

    private final UserService userService;
    private final JdbcTemplate jdbcTemplate;
    private final GraphBackendProbeService graphBackendProbeService;

    public SpringBenchmarkController(
            UserService userService,
            JdbcTemplate jdbcTemplate,
            GraphBackendProbeService graphBackendProbeService
    ) {
        this.userService = userService;
        this.jdbcTemplate = jdbcTemplate;
        this.graphBackendProbeService = graphBackendProbeService;
    }

    @GetMapping(value = "/api/v1/users", produces = "application/json")
    public List<UserView> readUsers() {
        return userService.findFrozenContractUsers();
    }

    // Lightweight single-row read (runtime-bound scenario): GET /api/v1/user?id=N -> {id, username}.
    // Counterpart of quarkus-benchmark-app UserResource.readUser and exeris-community-app
    // CommunityBenchmarkRouteHandler.handleUserById, including the 404-on-missing-row shape.
    @GetMapping(value = "/api/v1/user", produces = "application/json")
    public ResponseEntity<UserSummary> readUser(@RequestParam("id") long id) {
        UserSummary user = userService.findUserById(id);
        if (user == null) {
            return ResponseEntity.notFound().build();
        }
        return ResponseEntity.ok(user);
    }

    @GetMapping("/health")
    public Map<String, String> health() {
        return Map.of("status", "ok");
    }

    @GetMapping("/db/ping")
    public ResponseEntity<Map<String, String>> dbPing() {
        Integer one = jdbcTemplate.queryForObject("SELECT 1", Integer.class);
        if (one != null && one == 1) {
            return ResponseEntity.ok(Map.of("status", "ok"));
        }
        return ResponseEntity.status(HttpStatus.SERVICE_UNAVAILABLE).body(Map.of("status", "down"));
    }

    @GetMapping("/graph/ping")
    public ResponseEntity<Map<String, Object>> graphPing() {
        Map<String, Object> status = graphBackendProbeService.status();
        boolean graphUp = Boolean.TRUE.equals(status.get("graph_up"));
        if (graphUp) {
            return ResponseEntity.ok(status);
        }
        return ResponseEntity.status(HttpStatus.SERVICE_UNAVAILABLE).body(status);
    }
}
