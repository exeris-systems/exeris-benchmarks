package eu.exeris.benchmarks.micro.tls;

import jdk.jfr.Category;
import jdk.jfr.Description;
import jdk.jfr.Enabled;
import jdk.jfr.Event;
import jdk.jfr.Label;
import jdk.jfr.Name;
import jdk.jfr.StackTrace;

/**
 * JFR marker event emitted at the start of each JMH measurement iteration.
 *
 * <p>Used by {@code extract-jfr-metrics.sh} to isolate measurement-window JFR events
 * from setup-phase events (e.g. GC triggered by {@code @Setup(Level.Trial)}).
 * Only events occurring after the first {@code eu.exeris.bench.PhaseMarkerEvent}
 * are included in metric aggregation.
 */
@Name("eu.exeris.bench.PhaseMarkerEvent")
@Label("Benchmark Phase Marker")
@Description("Emitted at the start of each JMH measurement iteration to mark the measurement window boundary")
@Category({"Exeris", "Benchmark"})
@StackTrace(false)
@Enabled(true)
public class PhaseMarkerEvent extends Event {

    @Label("Phase")
    @Description("JMH lifecycle phase: measurement|warmup")
    public String phase;

    @Label("Iteration")
    @Description("JMH iteration sequence number within the phase (0-based)")
    public int iteration;

    @Label("Benchmark Class")
    @Description("Simple name of the benchmark class emitting this event")
    public String benchmarkClass;
}
