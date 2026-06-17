package eu.exeris.benchmarks.targets.springapp;

import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.Id;
import jakarta.persistence.Table;

@Entity
@Table(name = "users")
public class BenchmarkUserEntity {

    @Id
    @Column(name = "id", nullable = false)
    private Long id;

    @Column(name = "username", nullable = false)
    private String username;

    public Long getId() {
        return id;
    }

    public String getUsername() {
        return username;
    }
}
