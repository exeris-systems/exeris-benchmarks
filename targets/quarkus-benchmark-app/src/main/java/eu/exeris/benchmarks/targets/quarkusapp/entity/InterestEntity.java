package eu.exeris.benchmarks.targets.quarkusapp.entity;

import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.Id;
import jakarta.persistence.Table;

@Entity
@Table(name = "interests")
public class InterestEntity {

    @Id
    @Column(name = "id", nullable = false)
    Long id;

    @Column(name = "name", nullable = false)
    String name;

    @Column(name = "category", nullable = false)
    String category;
}
