package eu.exeris.benchmarks.targets.springapp;

import org.springframework.data.domain.Pageable;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import java.util.List;

public interface UserInterestJpaRepository extends JpaRepository<UserInterestEntity, UserInterestId> {

    interface InterestRowProjection {
        Long getInterestId();

        String getInterestName();

        String getInterestCategory();
    }

    interface InterestByUserRowProjection {
        Long getUserId();

        Long getInterestId();

        String getInterestName();

        String getInterestCategory();
    }

    @Query(
            """
            select ui.interest.id as interestId,
                   ui.interest.name as interestName,
                   ui.interest.category as interestCategory
            from UserInterestEntity ui
            where ui.id.userId = :userId
            order by ui.id.interestId asc
            """)
    List<InterestRowProjection> findInterestRowsForUser(@Param("userId") Long userId, Pageable pageable);

            @Query(
                value = """
                          SELECT ranked.user_id AS userId,
                              ranked.interest_id AS interestId,
                              ranked.interest_name AS interestName,
                              ranked.interest_category AS interestCategory
                    FROM (
                    SELECT ui.user_id,
                           ui.interest_id,
                           i.name AS interest_name,
                           i.category AS interest_category,
                           ROW_NUMBER() OVER (PARTITION BY ui.user_id ORDER BY ui.interest_id ASC) AS rn
                    FROM user_interests ui
                    JOIN interests i ON i.id = ui.interest_id
                    WHERE ui.user_id IN (:userIds)
                    ) ranked
                    WHERE ranked.rn <= :interestLimit
                    ORDER BY ranked.user_id ASC, ranked.interest_id ASC
                    """,
                nativeQuery = true)
            List<InterestByUserRowProjection> findInterestRowsForUsers(@Param("userIds") List<Long> userIds, @Param("interestLimit") int interestLimit);
}
