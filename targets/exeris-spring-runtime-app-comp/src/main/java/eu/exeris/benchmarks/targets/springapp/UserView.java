package eu.exeris.benchmarks.targets.springapp;

import java.util.List;

public record UserView(
        String id,
        String username,
        List<FriendSummary> friends,
        List<InterestView> interests
) {
}