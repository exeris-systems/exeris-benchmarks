package eu.exeris.benchmarks.targets.quarkusapp.controller;

import eu.exeris.benchmarks.targets.quarkusapp.repository.UserRepository;
import eu.exeris.benchmarks.targets.quarkusapp.service.GraphBackendProbeService;

import io.smallrye.common.annotation.RunOnVirtualThread;
import jakarta.inject.Inject;
import jakarta.ws.rs.GET;
import jakarta.ws.rs.Path;
import jakarta.ws.rs.Produces;
import jakarta.ws.rs.core.MediaType;
import jakarta.ws.rs.core.Response;

import java.util.Map;

@Path("/")
@Produces(MediaType.APPLICATION_JSON)
@RunOnVirtualThread
public class ProbeResource {

    @Inject
    UserRepository userRepository;

    @Inject
    GraphBackendProbeService graphBackendProbeService;

    @GET
    @Path("health")
    public Map<String, String> health() {
        return Map.of("status", "ok");
    }

    @GET
    @Path("db/ping")
    public Response dbPing() {
        if (userRepository.ping()) {
            return Response.ok(Map.of("status", "ok")).build();
        }
        return Response.status(Response.Status.SERVICE_UNAVAILABLE).entity(Map.of("status", "down")).build();
    }

    @GET
    @Path("graph/ping")
    public Response graphPing() {
        Map<String, Object> status = graphBackendProbeService.status();
        boolean graphUp = Boolean.TRUE.equals(status.get("graph_up"));
        if (graphUp) {
            return Response.ok(status).build();
        }
        return Response.status(Response.Status.SERVICE_UNAVAILABLE).entity(status).build();
    }
}
