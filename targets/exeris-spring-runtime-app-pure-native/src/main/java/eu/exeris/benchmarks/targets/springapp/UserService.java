package eu.exeris.benchmarks.targets.springapp;

import org.springframework.stereotype.Service;

import java.util.List;

@Service
public class UserService {

    private static final int USERS_LIMIT = 10;
    private static final int FRIENDS_LIMIT = 10;
    private static final int INTERESTS_LIMIT = 10;

    private final UserRepository userRepository;

    public UserService(UserRepository userRepository) {
        this.userRepository = userRepository;
    }

    // No @Transactional here, unlike the ORM arm. The read boundary is inside the repository:
    // TransactionalExecutor#inReadSession opens one connection, runs all three queries on it and
    // closes it. Layering Spring's ExerisPlatformTransactionManager on top would demarcate a
    // second, outer transaction and acquire a second connection per request — a measurement
    // artefact, not a fair analogue of the ORM arm's single-EntityManager boundary.
    public List<UserView> findFrozenContractUsers() {
        return userRepository.findTopUsersWithDetails(USERS_LIMIT, FRIENDS_LIMIT, INTERESTS_LIMIT);
    }

    // Light single-read counterpart of findFrozenContractUsers. Same transactional boundary as
    // the heavy contract so the light/heavy delta is the query shape, not the tx demarcation.
    // Same reasoning as above; TransactionalExecutor#query is the boundary.
    public UserSummary findUserById(long id) {
        return userRepository.findUserById(id);
    }
}
