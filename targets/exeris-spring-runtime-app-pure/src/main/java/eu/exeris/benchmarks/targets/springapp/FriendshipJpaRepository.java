package eu.exeris.benchmarks.targets.springapp;

import org.springframework.data.domain.Pageable;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import java.util.List;

public interface FriendshipJpaRepository extends JpaRepository<FriendshipEntity, FriendshipId> {

    interface FriendRowProjection {
        Long getFriendId();

        String getFriendUsername();
    }

    interface FriendByUserRowProjection {
        Long getUserId();

        Long getFriendId();

        String getFriendUsername();
    }

    @Query(
            """
            select f.friend.id as friendId, f.friend.username as friendUsername
            from FriendshipEntity f
            where f.id.userId = :userId
            order by f.id.friendUserId asc
            """)
    List<FriendRowProjection> findFriendRowsForUser(@Param("userId") Long userId, Pageable pageable);

            @Query(
                value = """
                          SELECT ranked.user_id AS userId,
                              ranked.friend_user_id AS friendId,
                              ranked.friend_username AS friendUsername
                    FROM (
                    SELECT f.user_id,
                           f.friend_user_id,
                           u.username AS friend_username,
                           ROW_NUMBER() OVER (PARTITION BY f.user_id ORDER BY f.friend_user_id ASC) AS rn
                    FROM friendships f
                    JOIN users u ON u.id = f.friend_user_id
                    WHERE f.user_id IN (:userIds)
                    ) ranked
                    WHERE ranked.rn <= :friendLimit
                    ORDER BY ranked.user_id ASC, ranked.friend_user_id ASC
                    """,
                nativeQuery = true)
            List<FriendByUserRowProjection> findFriendRowsForUsers(@Param("userIds") List<Long> userIds, @Param("friendLimit") int friendLimit);
}
