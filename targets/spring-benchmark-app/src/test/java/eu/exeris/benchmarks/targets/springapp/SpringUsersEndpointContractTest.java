package eu.exeris.benchmarks.targets.springapp;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.junit.jupiter.api.Test;
import org.springframework.jdbc.core.JdbcTemplate;

import java.util.ArrayList;
import java.util.List;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.anyInt;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

class SpringUsersEndpointContractTest {

    private static final int USERS_LIMIT = 10;
    private static final int FRIENDS_LIMIT = 10;
    private static final int INTERESTS_LIMIT = 10;

    private final ObjectMapper objectMapper = new ObjectMapper();

    @Test
    void endpointPayloadKeepsShapeCardinalityOrderingAndDeterminism() throws Exception {
        UserRepository repository = mock(UserRepository.class);
        when(repository.findTopUsersWithDetails(anyInt(), anyInt(), anyInt())).thenReturn(fixtureUsersWithDetails(USERS_LIMIT));

        UserService service = new UserService(repository);
        SpringBenchmarkController controller = new SpringBenchmarkController(
            service,
            mock(JdbcTemplate.class),
            mock(GraphBackendProbeService.class)
        );

        String first = objectMapper.writeValueAsString(controller.readUsers());
        String second = objectMapper.writeValueAsString(controller.readUsers());

        assertEquals(first, second, "Payload should be deterministic across calls");
        assertContractShape(first);
    }

    private void assertContractShape(String payload) throws Exception {
        JsonNode root = objectMapper.readTree(payload);
        assertTrue(root.isArray());
        assertEquals(USERS_LIMIT, root.size());

        long previousUserId = Long.MIN_VALUE;
        for (JsonNode user : root) {
            assertTrue(user.hasNonNull("id"));
            assertTrue(user.hasNonNull("username"));
            assertTrue(user.has("friends"));
            assertTrue(user.has("interests"));

            long currentUserId = Long.parseLong(user.get("id").asText());
            assertTrue(currentUserId > previousUserId);
            previousUserId = currentUserId;

            JsonNode friends = user.get("friends");
            assertTrue(friends.isArray());
            assertEquals(FRIENDS_LIMIT, friends.size());

            long previousFriendId = Long.MIN_VALUE;
            for (JsonNode friend : friends) {
                assertTrue(friend.hasNonNull("id"));
                assertTrue(friend.hasNonNull("username"));

                long currentFriendId = Long.parseLong(friend.get("id").asText());
                assertTrue(currentFriendId > previousFriendId);
                previousFriendId = currentFriendId;
            }

            JsonNode interests = user.get("interests");
            assertTrue(interests.isArray());
            assertEquals(INTERESTS_LIMIT, interests.size());

            long previousInterestId = Long.MIN_VALUE;
            for (JsonNode interest : interests) {
                assertTrue(interest.hasNonNull("id"));
                assertTrue(interest.hasNonNull("name"));
                assertTrue(interest.hasNonNull("category"));

                long currentInterestId = Long.parseLong(interest.get("id").asText());
                assertTrue(currentInterestId > previousInterestId);
                previousInterestId = currentInterestId;
            }
        }
    }

    private static List<UserSummary> fixtureUsers(int limit) {
        List<UserSummary> users = new ArrayList<>(limit);
        for (int index = 1; index <= limit; index++) {
            users.add(new UserSummary(Integer.toString(index), "user-" + index));
        }
        return users;
    }

    private static List<UserView> fixtureUsersWithDetails(int limit) {
        List<UserSummary> users = fixtureUsers(limit);
        List<UserView> views = new ArrayList<>(users.size());
        for (UserSummary user : users) {
            views.add(new UserView(
                    user.id(),
                    user.username(),
                    fixtureFriends(user.id(), FRIENDS_LIMIT),
                    fixtureInterests(user.id(), INTERESTS_LIMIT)
            ));
        }
        return views;
    }

    private static List<FriendSummary> fixtureFriends(String userId, int limit) {
        long base = Long.parseLong(userId) * 100;
        List<FriendSummary> friends = new ArrayList<>(limit);
        for (int index = 1; index <= limit; index++) {
            long id = base + index;
            friends.add(new FriendSummary(Long.toString(id), "friend-" + id));
        }
        return friends;
    }

    private static List<InterestView> fixtureInterests(String userId, int limit) {
        long base = Long.parseLong(userId) * 1000;
        List<InterestView> interests = new ArrayList<>(limit);
        for (int index = 1; index <= limit; index++) {
            long id = base + index;
            interests.add(new InterestView(Long.toString(id), "interest-" + id, "benchmark"));
        }
        return interests;
    }
}
