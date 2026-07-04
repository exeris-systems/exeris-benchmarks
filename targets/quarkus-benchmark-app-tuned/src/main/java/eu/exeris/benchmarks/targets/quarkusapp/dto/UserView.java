package eu.exeris.benchmarks.targets.quarkusapp.dto;

import java.util.List;

public record UserView(
        String id,
        String username,
        List<FriendSummary> friends,
        List<InterestView> interests
) {
}