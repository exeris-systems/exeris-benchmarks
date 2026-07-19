package eu.exeris.benchmarks.targets.quarkusapp.service;

import eu.exeris.benchmarks.targets.quarkusapp.dto.UserSummary;
import eu.exeris.benchmarks.targets.quarkusapp.dto.UserView;
import eu.exeris.benchmarks.targets.quarkusapp.repository.UserRepository;

import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;
import jakarta.transaction.Transactional;

import java.util.List;

@ApplicationScoped
public class UserService {

    private static final int USERS_LIMIT = 10;
    private static final int FRIENDS_LIMIT = 10;
    private static final int INTERESTS_LIMIT = 10;

    @Inject
    UserRepository userRepository;

    @Transactional(Transactional.TxType.REQUIRED)
    public List<UserView> findFrozenContractUsers() {
        return userRepository.findTopUsersWithDetails(USERS_LIMIT, FRIENDS_LIMIT, INTERESTS_LIMIT);
    }

    @Transactional(Transactional.TxType.REQUIRED)
    public UserSummary findUserById(long id) {
        return userRepository.findUserById(id);
    }
}
