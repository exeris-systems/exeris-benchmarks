package eu.exeris.benchmarks.targets.springapp;

import jakarta.persistence.Column;
import jakarta.persistence.Embeddable;

import java.io.Serializable;
import java.util.Objects;

@Embeddable
public class FriendshipId implements Serializable {

    @Column(name = "user_id", nullable = false)
    private Long userId;

    @Column(name = "friend_user_id", nullable = false)
    private Long friendUserId;

    public FriendshipId() {
    }

    public FriendshipId(Long userId, Long friendUserId) {
        this.userId = userId;
        this.friendUserId = friendUserId;
    }

    public Long getUserId() {
        return userId;
    }

    public Long getFriendUserId() {
        return friendUserId;
    }

    @Override
    public boolean equals(Object other) {
        if (this == other) {
            return true;
        }
        if (!(other instanceof FriendshipId that)) {
            return false;
        }
        return Objects.equals(userId, that.userId) && Objects.equals(friendUserId, that.friendUserId);
    }

    @Override
    public int hashCode() {
        return Objects.hash(userId, friendUserId);
    }
}
