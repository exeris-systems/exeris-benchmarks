package eu.exeris.benchmarks.targets.springapp;

import org.springframework.data.domain.PageRequest;
import org.springframework.stereotype.Repository;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

@Repository
public class UserRepository {
    private final BenchmarkUserJpaRepository benchmarkUserJpaRepository;
    private final FriendshipJpaRepository friendshipJpaRepository;
    private final UserInterestJpaRepository userInterestJpaRepository;

    public UserRepository(
            BenchmarkUserJpaRepository benchmarkUserJpaRepository,
            FriendshipJpaRepository friendshipJpaRepository,
            UserInterestJpaRepository userInterestJpaRepository) {
        this.benchmarkUserJpaRepository = benchmarkUserJpaRepository;
        this.friendshipJpaRepository = friendshipJpaRepository;
        this.userInterestJpaRepository = userInterestJpaRepository;
    }

    public List<UserSummary> findTopUsers(int limit) {
        if (limit <= 0) {
            return List.of();
        }

        List<BenchmarkUserEntity> users = benchmarkUserJpaRepository.findTopUsers(PageRequest.of(0, limit));
        List<UserSummary> summaries = new ArrayList<>(users.size());
        for (BenchmarkUserEntity user : users) {
            summaries.add(new UserSummary(Long.toString(user.getId()), user.getUsername()));
        }
        return summaries;
    }

    public List<FriendSummary> findFriendsForUser(String userId, int limit) {
        if (limit <= 0) {
            return List.of();
        }

        long numericUserId = parseNumericId(userId);
        List<FriendshipJpaRepository.FriendRowProjection> rows =
                friendshipJpaRepository.findFriendRowsForUser(numericUserId, PageRequest.of(0, limit));
        List<FriendSummary> friends = new ArrayList<>(rows.size());
        for (FriendshipJpaRepository.FriendRowProjection row : rows) {
            friends.add(new FriendSummary(Long.toString(row.getFriendId()), row.getFriendUsername()));
        }
        return friends;
    }

    public List<InterestView> findInterestsForUser(String userId, int limit) {
        if (limit <= 0) {
            return List.of();
        }

        long numericUserId = parseNumericId(userId);
        List<UserInterestJpaRepository.InterestRowProjection> rows =
                userInterestJpaRepository.findInterestRowsForUser(numericUserId, PageRequest.of(0, limit));
        List<InterestView> interests = new ArrayList<>(rows.size());
        for (UserInterestJpaRepository.InterestRowProjection row : rows) {
            interests.add(new InterestView(
                    Long.toString(row.getInterestId()),
                    row.getInterestName(),
                    row.getInterestCategory()));
        }
        return interests;
    }

    public List<UserView> findTopUsersWithDetails(int userLimit, int friendLimit, int interestLimit) {
        List<UserSummary> users = findTopUsers(userLimit);
        if (users.isEmpty()) {
            return List.of();
        }

        List<Long> userIds = new ArrayList<>(users.size());
        for (UserSummary user : users) {
            userIds.add(parseNumericId(user.id()));
        }

        Map<String, List<FriendSummary>> friendsByUser = findFriendsForUsers(userIds, friendLimit);
        Map<String, List<InterestView>> interestsByUser = findInterestsForUsers(userIds, interestLimit);

        List<UserView> views = new ArrayList<>(users.size());
        for (UserSummary user : users) {
            views.add(new UserView(
                    user.id(),
                    user.username(),
                    friendsByUser.getOrDefault(user.id(), List.of()),
                    interestsByUser.getOrDefault(user.id(), List.of())
            ));
        }
        return views;
    }

    private Map<String, List<FriendSummary>> findFriendsForUsers(List<Long> userIds, int friendLimit) {
        if (userIds.isEmpty() || friendLimit <= 0) {
            return Map.of();
        }

        List<FriendshipJpaRepository.FriendByUserRowProjection> rows =
            friendshipJpaRepository.findFriendRowsForUsers(userIds, friendLimit);
        Map<String, List<FriendSummary>> friendsByUser = new HashMap<>(userIds.size());
        for (FriendshipJpaRepository.FriendByUserRowProjection row : rows) {
            String userId = Long.toString(row.getUserId());
            String friendId = Long.toString(row.getFriendId());
            String friendUsername = row.getFriendUsername();
            friendsByUser.computeIfAbsent(userId, ignored -> new ArrayList<>())
                    .add(new FriendSummary(friendId, friendUsername));
        }
        return friendsByUser;
    }

    private Map<String, List<InterestView>> findInterestsForUsers(List<Long> userIds, int interestLimit) {
        if (userIds.isEmpty() || interestLimit <= 0) {
            return Map.of();
        }

        List<UserInterestJpaRepository.InterestByUserRowProjection> rows =
            userInterestJpaRepository.findInterestRowsForUsers(userIds, interestLimit);
        Map<String, List<InterestView>> interestsByUser = new HashMap<>(userIds.size());
        for (UserInterestJpaRepository.InterestByUserRowProjection row : rows) {
            String userId = Long.toString(row.getUserId());
            String interestId = Long.toString(row.getInterestId());
            String interestName = row.getInterestName();
            String interestCategory = row.getInterestCategory();
            interestsByUser.computeIfAbsent(userId, ignored -> new ArrayList<>())
                    .add(new InterestView(interestId, interestName, interestCategory));
        }
        return interestsByUser;
    }

    private static long parseNumericId(String id) {
        try {
            return Long.parseLong(id);
        } catch (NumberFormatException exception) {
            throw new IllegalStateException("Invalid user id: " + id, exception);
        }
    }
}
