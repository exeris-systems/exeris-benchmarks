package eu.exeris.benchmarks.targets.quarkusapp.dto;

import jakarta.persistence.Column;
import jakarta.persistence.Embeddable;

import java.io.Serializable;
import java.util.Objects;

@Embeddable
public class UserInterestId implements Serializable {

    @Column(name = "user_id", nullable = false)
    Long userId;

    @Column(name = "interest_id", nullable = false)
    Long interestId;

    public UserInterestId() {
    }

    public UserInterestId(Long userId, Long interestId) {
        this.userId = userId;
        this.interestId = interestId;
    }

    @Override
    public boolean equals(Object other) {
        if (this == other) {
            return true;
        }
        if (!(other instanceof UserInterestId that)) {
            return false;
        }
        return Objects.equals(userId, that.userId) && Objects.equals(interestId, that.interestId);
    }

    @Override
    public int hashCode() {
        return Objects.hash(userId, interestId);
    }
}
