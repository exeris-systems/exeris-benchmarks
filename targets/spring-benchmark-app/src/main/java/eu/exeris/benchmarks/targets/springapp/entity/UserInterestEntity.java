package eu.exeris.benchmarks.targets.springapp;

import jakarta.persistence.EmbeddedId;
import jakarta.persistence.Entity;
import jakarta.persistence.FetchType;
import jakarta.persistence.JoinColumn;
import jakarta.persistence.ManyToOne;
import jakarta.persistence.MapsId;
import jakarta.persistence.Table;

@Entity
@Table(name = "user_interests")
public class UserInterestEntity {

    @EmbeddedId
    private UserInterestId id;

    @ManyToOne(fetch = FetchType.LAZY, optional = false)
    @MapsId("userId")
    @JoinColumn(name = "user_id", nullable = false)
    private BenchmarkUserEntity user;

    @ManyToOne(fetch = FetchType.LAZY, optional = false)
    @MapsId("interestId")
    @JoinColumn(name = "interest_id", nullable = false)
    private InterestEntity interest;
}
