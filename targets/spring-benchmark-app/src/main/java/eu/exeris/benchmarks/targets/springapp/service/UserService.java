package eu.exeris.benchmarks.targets.springapp;

import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

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

    @Transactional(readOnly = true)
    public List<UserView> findFrozenContractUsers() {
        return userRepository.findTopUsersWithDetails(USERS_LIMIT, FRIENDS_LIMIT, INTERESTS_LIMIT);
    }
}
