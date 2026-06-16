package eu.exeris.benchmarks.targets.springapp;

import org.springframework.data.domain.Pageable;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Query;

import java.util.List;

public interface BenchmarkUserJpaRepository extends JpaRepository<BenchmarkUserEntity, Long> {

    @Query("select u from BenchmarkUserEntity u order by u.id asc")
    List<BenchmarkUserEntity> findTopUsers(Pageable pageable);
}
