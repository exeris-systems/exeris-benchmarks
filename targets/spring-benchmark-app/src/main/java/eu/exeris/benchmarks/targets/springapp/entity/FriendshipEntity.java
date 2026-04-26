package eu.exeris.benchmarks.targets.springapp;

import jakarta.persistence.EmbeddedId;
import jakarta.persistence.Entity;
import jakarta.persistence.FetchType;
import jakarta.persistence.JoinColumn;
import jakarta.persistence.ManyToOne;
import jakarta.persistence.MapsId;
import jakarta.persistence.Table;

@Entity
@Table(name = "friendships")
public class FriendshipEntity {

    @EmbeddedId
    private FriendshipId id;

    @ManyToOne(fetch = FetchType.LAZY, optional = false)
    @MapsId("userId")
    @JoinColumn(name = "user_id", nullable = false)
    private BenchmarkUserEntity user;

    @ManyToOne(fetch = FetchType.LAZY, optional = false)
    @MapsId("friendUserId")
    @JoinColumn(name = "friend_user_id", nullable = false)
    private BenchmarkUserEntity friend;
}
