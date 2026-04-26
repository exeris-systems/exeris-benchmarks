package eu.exeris.benchmarks.targets.quarkusapp.dto;

public record RegisterRequest(String username, String email, String password) {
}