package eu.exeris.benchmarks.targets.quarkusapp.entity;

import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.Id;
import jakarta.persistence.Table;

@Entity
@Table(name = "users")
public class UserEntity {

    @Id
    @Column(name = "id", nullable = false)
    Long id;

    @Column(name = "username", nullable = false)
    String username;

    public Long getId() {
        return id;
    }

    public String getUsername() {
        return username;
    }
}
