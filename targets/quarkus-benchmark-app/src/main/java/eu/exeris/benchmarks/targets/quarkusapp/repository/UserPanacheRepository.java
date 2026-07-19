package eu.exeris.benchmarks.targets.quarkusapp.repository;

import eu.exeris.benchmarks.targets.quarkusapp.dto.UserSummary;
import eu.exeris.benchmarks.targets.quarkusapp.entity.UserEntity;

import io.quarkus.hibernate.orm.panache.PanacheRepository;
import jakarta.enterprise.context.ApplicationScoped;

import java.util.ArrayList;
import java.util.List;

@ApplicationScoped
public class UserPanacheRepository implements PanacheRepository<UserEntity> {

    public List<UserSummary> findTopUsers(int limit) {
        if (limit <= 0) {
            return List.of();
        }

        List<UserEntity> entities = find("order by id asc").range(0, limit - 1).list();
        List<UserSummary> users = new ArrayList<>(entities.size());
        for (UserEntity entity : entities) {
            users.add(new UserSummary(Long.toString(entity.getId()), entity.getUsername()));
        }
        return users;
    }

    // Single-row PK read through the ORM (entity load + map) — the Hibernate counterpart
    // of the pure-JDBC target's WHERE id=? read; the ORM entity-hydration cost is the point.
    public UserSummary findUserById(long id) {
        UserEntity entity = findById(id);
        if (entity == null) {
            return null;
        }
        return new UserSummary(Long.toString(entity.getId()), entity.getUsername());
    }
}
