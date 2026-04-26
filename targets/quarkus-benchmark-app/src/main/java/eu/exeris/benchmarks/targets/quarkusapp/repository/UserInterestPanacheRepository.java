package eu.exeris.benchmarks.targets.quarkusapp.repository;

import eu.exeris.benchmarks.targets.quarkusapp.dto.InterestView;
import eu.exeris.benchmarks.targets.quarkusapp.entity.UserInterestEntity;

import io.quarkus.hibernate.orm.panache.PanacheRepository;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.persistence.Tuple;
import jakarta.persistence.TypedQuery;

import java.util.ArrayList;
import java.util.List;

@ApplicationScoped
public class UserInterestPanacheRepository implements PanacheRepository<UserInterestEntity> {

    public List<InterestView> findInterestsForUser(String userId, int limit) {
        if (limit <= 0) {
            return List.of();
        }

        long numericUserId = parseNumericId(userId);
        TypedQuery<Tuple> query = getEntityManager().createQuery(
                """
                select ui.interest.id as interestId,
                       ui.interest.name as interestName,
                       ui.interest.category as interestCategory
                from UserInterestEntity ui
                where ui.id.userId = :userId
                order by ui.id.interestId asc
                """,
                Tuple.class);
        query.setParameter("userId", numericUserId);
        query.setMaxResults(limit);

        List<Tuple> rows = query.getResultList();
        List<InterestView> interests = new ArrayList<>(rows.size());
        for (Tuple row : rows) {
            Long interestId = row.get("interestId", Long.class);
            String interestName = row.get("interestName", String.class);
            String interestCategory = row.get("interestCategory", String.class);
            interests.add(new InterestView(Long.toString(interestId), interestName, interestCategory));
        }
        return interests;
    }

    private static long parseNumericId(String id) {
        try {
            return Long.parseLong(id);
        } catch (NumberFormatException exception) {
            throw new IllegalStateException("Invalid user id: " + id, exception);
        }
    }
}
