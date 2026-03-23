package eu.exeris.kernel.benchmark.target.seed;

public interface BenchmarkSeeder {

    BenchmarkSeedResult seed(BenchmarkSeedPlan plan) throws Exception;
}