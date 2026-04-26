package eu.exeris.benchmarks.targets.quarkusapp.controller;

import eu.exeris.benchmarks.targets.quarkusapp.dto.UserView;
import eu.exeris.benchmarks.targets.quarkusapp.service.UserService;

import io.smallrye.common.annotation.RunOnVirtualThread;
import jakarta.inject.Inject;
import jakarta.ws.rs.GET;
import jakarta.ws.rs.Path;
import jakarta.ws.rs.Produces;
import jakarta.ws.rs.core.MediaType;

import java.util.List;

@Path("/api/v1")
@Produces(MediaType.APPLICATION_JSON)
@RunOnVirtualThread
public class UserResource {

    @Inject
    UserService userService;

    @GET
    @Path("/users")
    public List<UserView> readUsers() {
        return userService.findFrozenContractUsers();
    }
}
