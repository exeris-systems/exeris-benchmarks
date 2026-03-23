teraz tak, jako ze tworzymy powoli benchmarks to, mamy tutaj jeszcze taki temat pod research + benchmarks:


Francesco Nigro
Kontakt 1. stopnia · 1.
Senior Principal software Performance Engineer presso Red Hat
6 mar
Francesco Nigro wysłał(a) następujące wiadomości o 09:09
Wyświetl profil użytkownika Francesco Nigro Francesco Nigro
Francesco Nigro 09:09

Hi! Thanks for the comments! ❤️
I was curious about the different thread pools on your case because what I didn't said is that I am working with the Oracle Loom team to improve loom and on the presentation I didn't shared other recent findings around the fork join pool. If I got it right in your case you still have 2 separate pools; I/O carrier threads which start virtual threads on the default loom scheduler pool?
Wyświetl profil użytkownika Francesco Nigro Francesco Nigro
Francesco Nigro 09:13

And fyi these are the more detailed perf analysis I made on this topic https://github.com/franz1981/Netty-VirtualThread-Scheduler/tree/affinity/benchmark-runner/analysis

In the Findings part you can see the Linux perf analysis by using IBS w Linux perf mem and c2c

Which shows that at light load the FJ pool is causing an excess of Dram accesses due to cache pollution/trashing

Which is currently the work I am doing, to fix it
Arkadiusz Przychocki wysłał(a) następującą wiadomość o 09:39
Wyświetl profil użytkownika Arkadiusz Przychocki Arkadiusz Przychocki
Arkadiusz Przychocki 09:39

Hi Francesco. Yes — to be precise: two pools, different handoff mechanic. My native carrier threads (epoll / io_uring CQ) have zero ForkJoinPool involvement. They're dedicated OS threads whose sole job is reaping completions and calling unpark(). The VT then resumes on the default ForkJoinPool. So I avoid the task-queue submission handoff, but the VTs still run on FJ.

Which means your c2c / IBS finding hits me too. I don't have the double-queue ρ split, but I'm still subject to FJ work-stealing cache pollution at light load — I just can't observe it at the layer I'm operating at.

That's exactly what makes your custom scheduler interesting to me: if you're running VT continuations directly on the submitting EventLoop, you're collapsing both problems simultaneously — the queuing handoff AND the locality. I'm solving only the first.

One concrete question: does your scheduler's pinning approach still hold when the I/O source is a pure native thread (not an EventLoop worker) — i.e., can a io_uring CQ reaper act as a "home" for VT continuation affinity, or does the EventLoop model require the submitter to itself be a JVM managed thread?
Francesco Nigro wysłał(a) następujące wiadomości o 09:54
Wyświetl profil użytkownika Francesco Nigro Francesco Nigro
Francesco Nigro 09:54

Yesss, the custom scheduler I built is now tied to the Netty event loop with native transport API (which to be fair has very little API methods) and is built to use epoll and Uring in their native version, which means, prone to VT pinning.
In order to work as intended, with Uring, is highly suggested to use the task run flag in order to be notified, if single issuer is setup, of pending CQEs which need to enter the ring, but assuming this to be more of a problem of ZC tasks, usually, you can reap the CQEs without issuing any syscalls. The logic of the Netty scheduler can (and highly suggest you to do it) reused and modify to adhere to your API user face for I/O
Wyświetl profil użytkownika Francesco Nigro Francesco Nigro
Francesco Nigro 09:56

Right now I am not caring of fairness in any form and the scheduler is not implemention work stealing, but the mpsc queue I have implemented could be changed to become mpmc if needed and perform work stealing by monitoring the utilization of each carrier

The scheduler as said, is really few lines of code and just requires you to adapt to an imperative I/O API to command I/O

Which I believe you already have if you have your own transport

This is the core class of each scheduler worker https://github.com/franz1981/Netty-VirtualThread-Scheduler/blob/master/core/src/main/java/io/netty/loom/FifoEventLoopScheduler.java

Netty-VirtualThread-Scheduler/core/src/main/java/io/netty/loom/FifoEventLoopScheduler.java at master · franz1981/Netty-VirtualThread-Scheduler
github.com

Whilst the coordinator (the proper scheduler) is https://github.com/franz1981/Netty-VirtualThread-Scheduler/blob/master/core/src/main/java/io/netty/loom/NettyScheduler.java

Netty-VirtualThread-Scheduler/core/src/main/java/io/netty/loom/NettyScheduler.java at master · franz1981/Netty-VirtualThread-Scheduler
github.com

The latter has an addition "trick" coming from collaborating with Oracle

We implemented in loom a so called per carrier poller (pollerMode=3)

Which enables to run on the scheduler carriers not only normal virtual threads with zero cost local handoff but loom I/O as well

And the NettyScheduler there just take care of intercepting the creation of these pollers, check which VT has created it and just "bind" it to the same carrier scheduler thread

As it is now, I didn't prioritize (via CFS like scheduling) the interleave of the 3 types of works:
- VT issued via specialized factory
- I/O on Uring
- I/O of loom via pollers

But I strongly suggest to do it because it would avoid weird HOL blocking issues

Let me know if I have missed something 🙏
Wyświetl profil użytkownika Francesco Nigro Francesco Nigro
Francesco Nigro 10:02

In case you find this API and Impl to fit and you have chances to run some benchmark please 🙏 let's talk about it to the loom jdk list. The only way to convince Oracle Atm to open this Api Is to make evident how the current loom state doesn't allow for libraries and use cases like yours to fully benefits of Loom

Which I think this to be true for many high performance custom transports e.g. based on Aeron or dpdk

One thing I forgot to say: why I am running the native transport in a long running and controlled virtual thread?
Wyświetl profil użytkownika Francesco Nigro Francesco Nigro
Francesco Nigro 10:07

There are 2 reasons:
1. Deadlock of external shared libraries between the scheduler carrier and its own VTs: this happens with logging and many other cases...
2. Very soon loom would enable to preempt VTs: if the carrier has a shared data structure (e.g. a lock free queue as task queue) with its own VTs it runs, if the VTs suspends leaving the queue in some state which requires the VT to make progress, it will deadlock the carrier, unable to proceed because need the VT to be resumed (and it cannot happen forcibly)

These points are currently unavoidable and Alibaba spent quite long time trying to not do as I have done, but there are good reasons for that, very tied to how loom work under the hood. Said that it's a minor ^^
Wyświetl profil użytkownika Francesco Nigro Francesco Nigro
Francesco Nigro 10:11

I hope this kind of answer you in relation of the nature of the I/O layer. Atm the only strict requirement is to:
1. Be able to know when you can safely pin the carrier (I have a can block method)
2. Have some wakeup mechanism on it which allows non native I/O to resume it and consume/run any VTs

In netty w Uring we use the typical eventFd write
Arkadiusz Przychocki wysłał(a) następującą wiadomość o 10:49
Wyświetl profil użytkownika Arkadiusz Przychocki Arkadiusz Przychocki
Arkadiusz Przychocki 10:49

Now I understand the full picture — and the Alibaba reference makes the constraints concrete.

The preemption deadlock you're describing requires a carrier that both owns a task queue and schedules VTs onto itself. In Exeris, my CQ reapers are pure native OS threads — not VTs, not carriers in the Loom sense. There's no shared data structure between the carrier and its own VTs because, from Loom's perspective, the carrier doesn't exist. It just calls unpark() and goes back to polling the ring. So I pay a different price (FJ locality loss), but I'm immune to those specific failure modes by construction.

Looking at your two API requirements against my IoUringQuicCarrier:

canBlock() — The signal exists. My reaper knows it's safe to block when the CQ ring is empty before entering io_uring_enter with a wait. It just needs a formal interface wrapper to be pollerMode-compatible.

Wakeup mechanism — I have this implemented using wakeupPending.set(true) + LockSupport.unpark(thread) — JVM-level rather than kernel-level eventfd, but same semantics.

I'm absolutely in for the loom-dev discussion. Exeris represents a genuinely different point in the design space: a transport that meets your structural requirements but can't complete the locality chain because pollerMode=3 is internal. That is a clean, undeniable argument for the JDK list.

I've attach two core files from my R&D closed branch to make this concrete (feel free to ignore the TOCTOU race on the atomic counter in IoUringScheduler — it's a known prototype artifact!). I will adapt my architecture to your FifoEventLoopScheduler API and run the benchmarks.

https://gist.github.com/arkstack-dev/9a6f6494989cb360d48d3b33adc1e661

https://gist.github.com/arkstack-dev/e9f871dcaa144c425504bea9d41b9acc

When are you planning to bring this to the mailing list?

Francesco Nigro wysłał(a) następujące wiadomości o 11:02
Wyświetl profil użytkownika Francesco Nigro Francesco Nigro
Francesco Nigro 11:02

Nice one! Re the deadlock remember the case of preemption too, more for the future than a PoC and the other reasons are class loaders: you need to be 100% there will never be a concurrent class load shared between a VT (which would block on it for some reason) and the carrier in itself, which will make them sharing some locked impl of JDK class loader...that said, I am already having meetings with Oracle to find the sweet spot between API surface exposed and wider audience benefits...so I don't need to open my same effort to them, as they are involved already
Wyświetl profil użytkownika Francesco Nigro Francesco Nigro
Francesco Nigro 11:03

But if you have benchmarks and results, coming from an outer source can have a more effective impact to them; I am certainly very interested into making Netty loom friendly but I am lone voice with a very specific use case

So. The more feedbacks the better
Wyświetl profil użytkownika Francesco Nigro Francesco Nigro
Francesco Nigro 11:05

Nice you use my library JCtools

❤️
Wyświetl profil użytkownika Francesco Nigro Francesco Nigro
Francesco Nigro 11:08

And you likely coming from the HFT world I see https://gist.github.com/arkstack-dev/9a6f6494989cb360d48d3b33adc1e661#file-iouringquiccarrier-java-L765

Exeris Kernel — IoUringQuicCarrier (R&D branch) True reactor-pattern QUIC carrier driven by io_uring CQEs. Pure native OS thread model — carrier exists outside JVM/Loom thread hierarchy. Wakeup mechanism: wakeupPending + LockSupport.unpark(). canBlock() signal implicit at CQ ring empty state (pre io_uring_enter). Prototype — not production.
gist.github.com

Certain patterns are very recognizable ^^
Wyświetl profil użytkownika Francesco Nigro Francesco Nigro
Francesco Nigro 11:10

And https://gist.github.com/arkstack-dev/e9f871dcaa144c425504bea9d41b9acc#file-iouringscheduler-java-L76 is the disruptive part while using a custom scheduler; this will eventually run on the same carrier

Exeris Kernel — IoUringScheduler (R&D branch) Direct handoff scheduler — no intermediate queue between io_uring reactor and VT. CQ reaper spawns VT immediately on completion. Known issue: TOCTOU race on atomic counter (get + incrementAndGet not atomic) — prototype artifact, architectural intent is the point.
gist.github.com

That's why you should try to have an imperative I/O api which bound for how long you drain I/O events, as it allows you bound the tail latencies before you pick the first VT on the same carrier (edytowano)

Using a virtual thread I/O event loop allows this thing too ^^ as suspend/resume is just a Thread.yield

So. You pay the mount/unmount (which is small) but you have suspendable event loops ootb
Wyświetl profil użytkownika Francesco Nigro Francesco Nigro
Francesco Nigro 11:21

In any case that's some seriously good eng work there, well done

Is a pleasure to read

Arkadiusz Przychocki wysłał(a) następującą wiadomość o 12:26
Wyświetl profil użytkownika Arkadiusz Przychocki Arkadiusz Przychocki
Arkadiusz Przychocki 12:26

Thank you — and the classloader point is one I hadn't fully mapped out. The preemption case I had modeled, but classloader locking between a parked VT and the carrier is a subtler failure mode. Noted.
The bounded drain insight is the piece I'm taking away from this conversation. Running the event loop itself in a VT rather than a native OS thread — getting suspendable drain via Thread.yield — that changes the design space significantly. I'd been treating the CQ reaper as necessarily outside Loom, but if the mount/unmount cost is acceptable at that granularity, it opens up the carrier affinity problem from a different angle entirely.
I'll run the benchmarks with that model and come back with numbers. And yes — JCTools is load-bearing infrastructure here.

Francesco Nigro wysłał(a) następujące wiadomości o 13:41
Wyświetl profil użytkownika Francesco Nigro Francesco Nigro
Francesco Nigro 13:41

👍
Copilot said: Tak — to jest **bardzo dobry kandydat

Tak — to jest bardzo dobry kandydat na osobny research + benchmark track w exeris-benchmarks, a nawet szerzej: na benchmark initiative, bo dotyka nie tylko liczb, ale też argumentacji architektonicznej wobec Loom teamu.

I szczerze: to nie jest “jeszcze jeden benchmark”.
To jest temat typu:
“Can Exeris demonstrate a measurable gap between default Loom/FJP scheduling and transport-affine VT continuation scheduling?”

To ma duży ciężar, bo może dać:

    konkretne benchmarki do repo,
    materiał do discussions z Loom/Oracle,
    argument za public API/custom scheduler support,
    lepsze zrozumienie, czy Exeris powinien iść w:
        native reaper + FJ continuation
        bounded-drain VT event loop
        custom scheduler with carrier affinity
        hybrydę.

Mój krótki werdykt
Tak:

to powinno wejść do exeris-benchmarks jako osobny research stream.
Nie:

nie wrzucałbym tego od razu jako zwykłego benchmarku obok hello-world wrk.

Bo to jest bardziej:

    scheduler/runtime research,
    micro + runtime + perf-counter analysis,
    design-space benchmark suite.

Jak bym to nazwał?

Masz kilka dobrych opcji.
Najbardziej praktyczna:
loom-scheduler-affinity

albo
vt-carrier-affinity

Ja bym wybrał:
loom-scheduler-affinity

bo dobrze komunikuje:

    Loom,
    scheduler behavior,
    locality/affinity problem.

Co to właściwie benchmarkuje?

Z tej rozmowy wynika kilka hipotez, które warto jawnie zapisać.
Hipoteza 1

Default Loom scheduler (ForkJoinPool) traci locality po unpark/resume VT, nawet jeśli Exeris eliminuje queue handoff między native reaperem a VT.

To jest Twój obecny stan:

    native CQ reaper
    no FJP task submission handoff
    ale continuation resume nadal na FJP
    czyli locality/cache effects nadal mogą boleć

Hipoteza 2

Carrier-affine scheduling może poprawić cache locality i ograniczyć light-load DRAM/cache pollution w porównaniu do default FJP resume path.

To jest blisko tego, co Francesco opisał.
Hipoteza 3

Bounded-drain event-loop running as a VT may open a different design point than pure native reaper threads, with acceptable mount/unmount cost and improved locality chain.

To jest nowy kierunek z rozmowy.
Hipoteza 4

The value of per-carrier pollers / pollerMode=3 is measurable for custom transport workloads like Exeris, and not just for Netty’s event-loop model.

To jest bardzo ważne, jeśli chcesz coś pokazać Loom teamowi.
To powinno być benchmarkowane jako 3 warstwy
I. Micro-level scheduler/locality benchmarks

Tu sprawdzasz mechanikę.
Co mierzyć?

    VT resume latency after unpark
    cost of handoff path
    cache locality proxy metrics
    light-load behavior
    single carrier / few carrier cases
    bounded-drain overhead
    mount/unmount overhead if event loop runs in VT

To może być:

    JMH
    custom harness
    perf counters / perf mem / c2c / IBS if available

II. Runtime transport benchmarks

Tu sprawdzasz, co to daje w realnym Exeris path.
Scenariusze:

    H1/H2 Community baseline
    Enterprise H1/H2/H3
    small payload steady-state
    low concurrency / light load
    moderate concurrency
    tail latency under burst
    completion-heavy scenarios

Szczególnie:

light load i low-to-moderate concurrency są ważne, bo właśnie tam locality issue może najbardziej wychodzić.
III. Research / perf-analysis layer

To nie są tylko benchmark numbers.
Tu chcesz zbierać:

    perf stat / perf mem / c2c if possible
    JFR
    CPU migrations maybe
    cache misses / LLC behavior
    DRAM access indicators
    maybe scheduler thread affinity observations

To jest warstwa, która robi z tego materiał researchowy, a nie tylko “RPS table”.
Jak bym to umieścił w repo?

Ja bym dodał osobną gałąź researchową:
Text

exeris-benchmarks/
research/
loom-scheduler-affinity/
README.md
hypotheses.md
methodology.md
scenarios/
micro/
runtime/
perf-analysis/
results/
reports/

To będzie dużo lepsze niż wciskanie tego do zwykłego runtime/h2/.
Proponowana struktura tego research streamu
Text

research/
loom-scheduler-affinity/
README.md
hypotheses.md
methodology.md
risks-and-validity.md
scenarios/
native-reaper-fjp-resume.md
vt-eventloop-bounded-drain.md
scheduler-affine-resume.md
micro/
jmh/
runtime/
community/
h1/
h2/
enterprise/
h1/
h2/
h3/
perf-analysis/
linux-perf/
jfr/
async-profiler/
results/
raw/
normalized/
comparisons/
reports/
fjp-vs-affine.md
loom-feedback-summary.md

Jakie warianty architektury benchmarkować?

To najważniejsze — musisz benchmarkować konkretne execution models.

Ja bym zdefiniował przynajmniej 4 warianty.
Variant A — current Exeris baseline
native-reaper + default-fjp-resume

Opis:

    CQ reaper is pure native OS thread
    completion triggers unpark
    VT resumes on default Loom scheduler/FJP

To jest punkt odniesienia.
Variant B — native reaper + bounded drain

Jeśli zrobisz taką wersję eksperymentalną.
native-reaper + bounded-drain + default-fjp-resume

Może być intermediate step.
Variant C — VT event loop
vt-event-loop + bounded-drain

Opis:

    event loop itself runs in VT
    suspend/resume via Loom
    bounded drain
    potentially different locality tradeoff

To jest bardzo ciekawe badawczo.
Variant D — carrier-affine/custom scheduler
affine-scheduler-resume

Opis:

    continuation stays on home carrier or equivalent
    local handoff semantics
    ideal locality-oriented path

To może być adapter/prototype inspired by Francesco’s scheduler.
Benchmark questions, które warto postawić wprost

Repo powinno mieć to zapisane jako research questions.
Q1

Czy Exeris current model eliminuje enough handoff cost, ale nadal traci locality przez default FJP?
Q2

Czy carrier-affine scheduling poprawia:

    p50/p95/p99 latency,
    DRAM/cache behavior,
    light-load efficiency?

Q3

Czy bounded-drain VT event loop daje lepszy trade-off niż native reaper outside Loom?
Q4

Czy zysk jest wystarczająco duży, by uzasadnić JDK API exposure / custom scheduler support?

To jest bardzo dobra rama.
Jakie benchmarki konkretnie zrobić?
A. Microbench / scheduler mechanics
1. vt-unpark-resume-latency

   measure unpark → useful work start latency

2. completion-to-handler-start

   io completion signal → handler continuation

3. bounded-drain-cost

   cost of draining N completions before switching to VT work

4. mount-unmount-cost

   if event loop in VT

5. same-carrier-vs-fjp-resume

   synthetic locality-sensitive workload

B. Runtime scenarios
1. light-load-plaintext

Bardzo ważny, bo tam cache pollution/trashing może być najbardziej widoczny.
2. light-load-json-1kb

Mały realistyczny app payload.
3. burst-32

Burst of requests, then quiet.
4. concurrent-128

Moderate load.
5. mixed-completion-latency

If you can simulate completion-heavy transport behavior.
C. Perf-analysis scenarios
For Linux perf:

    same low-load scenario
    same moderate-load scenario
    compare A/B/C/D variants

Collect:

    cache misses
    remote/DRAM indicators
    c2c if viable
    task migrations if possible

Najważniejsza rzecz metodologiczna

To trzeba benchmarkować przy:
light load

i nie tylko saturation throughput.

Bo dokładnie z rozmowy wynika, że problem FJP locality pollution wychodzi mocno przy lżejszym obciążeniu.
Więc nie rób tylko:

    max throughput wrk 256 threads 10 minutes

Zrób też:

    sparse steady load
    low connection count
    low/moderate concurrency
    bursty workload

Jak to połączyć z benchmark repo agentami?

Dla tego research streamu przyda się nawet osobny mini-stack lub przynajmniej osobne skills.
Skills, które bym dodał do benchmark repo
1. exeris-bench-research-hypothesis-review

Czy hipoteza jest benchmarkowalna i dobrze sformułowana?
2. exeris-bench-scheduler-methodology-review

Czy metodologia rozdziela:

    handoff cost
    locality cost
    protocol/runtime cost
    tool bias?

3. exeris-bench-perf-analysis-review

Czy perf/JFR/c2c evidence wspiera wnioski?
4. exeris-bench-loom-feedback-reporting

Czy wyniki są przedstawione w formie nadającej się do loom-dev / Oracle discussion?

To byłoby naprawdę przydatne.
Bardzo ważne: proprietary / publication angle

To, co chcesz prawdopodobnie pokazać na zewnątrz, to nie koniecznie cały enterprise code, tylko:

    benchmark design
    current baseline behavior
    measurable difference
    evidence that custom transport workloads need scheduler affinity support

Czyli można publikować:

    normalized benchmark results
    methodology
    architectural description at high level
    comparison charts

Nie trzeba publikować:

    proprietary enterprise internals
    full transport implementation
    internal code paths

To da się zrobić bardzo elegancko.
Co bym zrobił jako pierwszy krok?
1. Załóż research track

research/loom-scheduler-affinity/
2. Napisz 3 pliki

   README.md
   hypotheses.md
   methodology.md

3. Zdefiniuj baseline variants

   current Exeris model
   VT event-loop prototype
   affine scheduler prototype if feasible

4. Zrób najpierw 2 benchmark families

   micro: completion→resume latency
   runtime: light-load plaintext/json-1kb

5. Dopiero potem dodaj perf mem/c2c/JFR layer

To będzie zdrowa kolejność.
Mój finalny werdykt
Tak:

to jest bardzo wartościowy temat pod research + benchmarks i powinien dostać własne miejsce w repo benchmarkowym.
Najlepsza forma:
osobny research stream:

research/loom-scheduler-affinity/
Najważniejsze benchmark question:

czy Exeris może pokazać mierzalny koszt default FJP locality loss i zysk z carrier-affine / bounded-drain scheduling modelu?

To jest mocne i praktyczne.

Jeśli chcesz, mogę teraz zrobić jeden z trzech konkretnych kroków:

    rozpisać gotową strukturę research/loom-scheduler-affinity/ z plikami,
    napisać hypotheses.md i methodology.md dla tego research tracku,
    zaprojektować benchmark matrix dla wariantów A/B/C/D.

AdmissionController.java
PaqsScheduler.java
StreamLoadShedder.java
You said: Czyli tak naprawdę clue jest taki że
Czyli tak naprawdę clue jest taki że podmieniam mój PaqsScheduler na ten który on udostępnił (bo nie mam dostepu do pullermode3)

/*
* Copyright 2025 The Netty VirtualThread Scheduler Project
*
* The Netty VirtualThread Scheduler Project licenses this file to you under the Apache License,
* version 2.0 (the "License"); you may not use this file except in compliance with the
* License. You may obtain a copy of the License at:
*
*   https://www.apache.org/licenses/LICENSE-2.0
*
* Unless required by applicable law or agreed to in writing, software distributed under the
* License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND,
* either express or implied. See the License for the specific language governing permissions
* and limitations under the License.
  */
  package io.netty.loom;

/**
* Global Netty scheduler proxy for virtual threads.
*
* <p>
* Inheritance rule (exact): a newly started virtual thread inherits the
* caller's {@code EventLoopScheduler} only when both conditions are true:
* <ol>
* <li>{@code jdk.pollerMode} is {@code 3} (per-carrier pollers); and</li>
* <li>the thread performing the start/poller I/O is itself running under an
* {@code EventLoopScheduler} (i.e.
* {@code EventLoopScheduler.currentThreadSchedulerContext().scheduler()}
* returns a non-null {@code SharedRef}).</li>
* </ol>
*
* <p>
* The current implementation only attempts scheduler inheritance for
* poller-created virtual threads (recognized by the {@code "-Read-Poller"} name
* suffix). If either condition above is not met (or the thread kind is
* unrecognized) the virtual thread falls back to the default JDK scheduler.
*
* <p>
* This class is a proxy/dispatcher and does not implement a standalone
* scheduling policy. See {@link EventLoopScheduler} for details about scheduler
* attachment and execution.
  */

public class NettyScheduler implements Thread.VirtualThreadScheduler {

	static volatile NettyScheduler INSTANCE;

	private final Thread.VirtualThreadScheduler jdkBuildinScheduler;

	private final boolean perCarrierPollers;

	private static NettyScheduler ensureInstalled() {
		var instance = INSTANCE;
		if (instance != null) {
			return instance;
		}
		Thread.ofVirtual().unstarted(new Runnable() {
			@Override
			public void run() {

			}
		});
		// we expect VirtualThread clinit to have loaded it by now
		return INSTANCE;
	}

	public NettyScheduler(Thread.VirtualThreadScheduler jdkBuildinScheduler) {
		this.jdkBuildinScheduler = jdkBuildinScheduler;
		perCarrierPollers = Integer.getInteger("jdk.pollerMode", -1) == 3;
		INSTANCE = this;
	}

	public boolean expectsPerCarrierPollers() {
		return perCarrierPollers;
	}

	Thread.VirtualThreadScheduler jdkBuildinScheduler() {
		return jdkBuildinScheduler;
	}

	@Override
	public void onStart(Thread.VirtualThreadTask virtualThreadTask) {
		if (virtualThreadTask.attachment() instanceof EventLoopScheduler.SchedulingContext context) {
			var eventLoop = context.schedulerRef.get();
			if (eventLoop != null && eventLoop.execute(virtualThreadTask)) {
				return;
			}
			// the v thread has been rejected by its assigned scheduler or its scheduler is
			// gone
			virtualThreadTask.attach(null);
		} else {
			if (perCarrierPollers) {
				// Read-Poller threads should always inherit the event loop scheduler from the
				// caller thread
				if (Thread.currentThread().isVirtual()) {
					// TODO
					// https://github.com/openjdk/loom/blob/12ddf39bb59252a8274d8b937bd075b2a6dbc3f8/src/java.base/share/classes/java/lang/VirtualThread.java#L270C18-L270C33
					// in theory should be easy to provide a VirtualThreadTask::current method to
					// avoid the ScopedValue lookup
					var schedulerRef = EventLoopScheduler.currentThreadSchedulerContext().scheduler();
					// See
					// https://github.com/openjdk/loom/blob/12ddf39bb59252a8274d8b937bd075b2a6dbc3f8/src/java.base/share/classes/sun/nio/ch/Poller.java#L723C48-L723C59
					if (schedulerRef != null) {
						var scheduler = schedulerRef.get();
						if (scheduler != null && virtualThreadTask.thread().getName().endsWith("-Read-Poller")) {
							virtualThreadTask.attach(new EventLoopScheduler.SchedulingContext(
									virtualThreadTask.thread().threadId(), schedulerRef, true));
							if (scheduler.execute(virtualThreadTask)) {
								return;
							}
							virtualThreadTask.attach(null);
						}
					}
				}
			}
		}
		jdkBuildinScheduler.onStart(virtualThreadTask);
	}

	@Override
	public void onContinue(Thread.VirtualThreadTask virtualThreadTask) {
		if (virtualThreadTask.attachment() instanceof EventLoopScheduler.SchedulingContext context) {
			var eventLoop = context.schedulerRef.get();
			if (eventLoop != null && eventLoop.execute(virtualThreadTask)) {
				return;
			}
			// the v thread has been rejected by its assigned scheduler or its scheduler is
			// gone
			virtualThreadTask.attach(null);
		}
		jdkBuildinScheduler.onContinue(virtualThreadTask);
	}

	public static boolean perCarrierPollers() {
		return ensureInstalled().perCarrierPollers;
	}

	public static boolean isAvailable() {
		return ensureInstalled() != null;
	}
}

/*
* Copyright 2025 The Netty VirtualThread Scheduler Project
*
* The Netty VirtualThread Scheduler Project licenses this file to you under the Apache License,
* version 2.0 (the "License"); you may not use this file except in compliance with the
* License. You may obtain a copy of the License at:
*
*   https://www.apache.org/licenses/LICENSE-2.0
*
* Unless required by applicable law or agreed to in writing, software distributed under the
* License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND,
* either express or implied. See the License for the specific language governing permissions
* and limitations under the License.
  */
  package io.netty.loom;

import java.util.concurrent.ThreadFactory;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.locks.LockSupport;

import io.netty.channel.IoEventLoopGroup;
import io.netty.channel.IoHandlerFactory;
import io.netty.channel.ManualIoEventLoop;
import io.netty.loom.jfr.VirtualThreadTaskSubmitEvent;
import io.netty.util.concurrent.FastThreadLocalThread;

final class FifoEventLoopScheduler implements EventLoopScheduler {

	private static final long MAX_WAIT_TASKS_NS = TimeUnit.HOURS.toNanos(1);
	// These are the soft-guaranteed yield times for the event loop whilst
	// Thread.yield() is called.
	// Based on the status of the event loop (resuming from blocking or
	// non-blocking, controlled by the running flag)
	// a different limit is applied.
	private static final long RUNNING_YIELD_US = TimeUnit.MICROSECONDS
			.toNanos(Integer.getInteger("io.netty.loom.running.yield.us", 1));
	private static final long IDLE_YIELD_US = TimeUnit.MICROSECONDS
			.toNanos(Integer.getInteger("io.netty.loom.idle.yield.us", 1));
	private final MpscUnboundedStream<Thread.VirtualThreadTask> runQueue;
	private final ManualIoEventLoop ioEventLoop;
	private final Thread eventLoopThread;
	private final Thread carrierThread;
	private volatile Thread parkedCarrierThread;
	private volatile Thread.VirtualThreadTask eventLoopContinuatioToRun;
	private final ThreadFactory vThreadFactory;
	private final AtomicBoolean eventLoopIsRunning;
	private final SharedRef sharedRef;

	public FifoEventLoopScheduler(IoEventLoopGroup parent, ThreadFactory threadFactory,
			IoHandlerFactory ioHandlerFactory, int resumedContinuationsExpectedCount) {
		sharedRef = new SharedRef(this);
		eventLoopIsRunning = new AtomicBoolean(false);
		runQueue = new MpscUnboundedStream<>(resumedContinuationsExpectedCount);
		carrierThread = threadFactory.newThread(this::virtualThreadSchedulerLoop);
		vThreadFactory = newEventLoopSchedulerFactory(sharedRef);
		eventLoopThread = vThreadFactory
				.newThread(() -> FastThreadLocalThread.runWithFastThreadLocal(this::nettyEventLoop));
		ioEventLoop = new ManualIoEventLoop(parent, eventLoopThread,
				ioExecutor -> new AwakeAwareIoHandler(eventLoopIsRunning, ioHandlerFactory.newHandler(ioExecutor))) {
			@Override
			public boolean canBlock() {
				return runQueue.isEmpty();
			}
		};
		carrierThread.start();
	}

	private static ThreadFactory newEventLoopSchedulerFactory(SharedRef sharedRef) {
		// in the future we could create a SchedulerAssignment object a with modifiable
		// SharedRef into
		// and share it between the thread attachment and the SchedulingContext,
		// enabling
		// work-stealing to change it for both
		var unstartedBuilder = Thread.ofVirtual();
		NettyScheduler scheduler = NettyScheduler.INSTANCE;
		return runnable -> {
			var schedulingContext = new SchedulingContext(sharedRef);
			var vTask = scheduler.newThread(unstartedBuilder, null,
					() -> EventLoopScheduler.runWithContext(runnable, schedulingContext));
			schedulingContext.vThreadId = vTask.thread().threadId();
			vTask.attach(schedulingContext);
			return vTask.thread();
		};
	}

	@Override
	public int externalContinuationsCount() {
		return runQueue.size();
	}

	@Override
	public ThreadFactory virtualThreadFactory() {
		return vThreadFactory;
	}

	@Override
	public Thread carrierThread() {
		return carrierThread;
	}

	@Override
	public ManualIoEventLoop ioEventLoop() {
		return ioEventLoop;
	}

	private void nettyEventLoop() {
		eventLoopIsRunning.set(true);
		assert ioEventLoop.inEventLoop(Thread.currentThread()) && Thread.currentThread().isVirtual();
		boolean canBlock = false;
		while (!ioEventLoop.isShuttingDown()) {
			canBlock = runIO(canBlock);
			if (!runQueue.isEmpty()) {
				Thread.yield();
			}
			// try running leftover write tasks before checking for I/O tasks
			canBlock &= runNonBlockingTasks(RUNNING_YIELD_US) == 0;
			if (!runQueue.isEmpty()) {
				Thread.yield();
			}
		}
		// we are shutting down, it shouldn't take long so let's spin a bit :P
		while (!ioEventLoop.isTerminated()) {
			ioEventLoop.runNow();
			if (!runQueue.isEmpty()) {
				Thread.yield();
			}
		}
	}

	private boolean runIO(boolean canBlock) {
		var event = SchedulerJfrUtil.beginRunIoEvent();
		int ioEventsHandled;
		boolean ranBlocking = false;
		if (canBlock) {
			// try to go to sleep waiting for I/O tasks
			eventLoopIsRunning.set(false);
			// StoreLoad barrier: see
			// https://www.scylladb.com/2018/02/15/memory-barriers-seastar-linux/
			if (canBlock()) {
				ranBlocking = true;
				try {
					ioEventsHandled = ioEventLoop.run(MAX_WAIT_TASKS_NS, RUNNING_YIELD_US);
				} finally {
					eventLoopIsRunning.set(true);
				}
			} else {
				eventLoopIsRunning.set(true);
				ioEventsHandled = ioEventLoop.runNow(RUNNING_YIELD_US);
			}
		} else {
			ioEventsHandled = ioEventLoop.runNow(RUNNING_YIELD_US);
		}
		if (event != null) {
			SchedulerJfrUtil.commitRunIoEvent(event, carrierThread, ranBlocking, ioEventsHandled);
		}
		return ioEventsHandled == 0;
	}

	private int runNonBlockingTasks(long deadlineNs) {
		var event = SchedulerJfrUtil.beginRunTasksEvent();
		if (event == null) {
			return ioEventLoop.runNonBlockingTasks(deadlineNs);
		}
		int queueDepthBefore = runQueue.size();
		int tasksHandled = ioEventLoop.runNonBlockingTasks(deadlineNs);
		int queueDepthAfter = runQueue.size();
		SchedulerJfrUtil.commitRunTasksEvent(event, carrierThread, tasksHandled, queueDepthBefore, queueDepthAfter);
		return tasksHandled;
	}

	private boolean runEventLoopContinuation() {
		assert Thread.currentThread() == carrierThread;
		var eventLoopContinuation = this.eventLoopContinuatioToRun;
		if (eventLoopContinuation != null) {
			this.eventLoopContinuatioToRun = null;
			runContinuation(eventLoopContinuation);
			return true;
		}
		return false;
	}

	private void virtualThreadSchedulerLoop() {
		// start the event loop thread
		var eventLoop = this.ioEventLoop;
		eventLoopThread.start();
		assert eventLoopContinuatioToRun != null;
		// we keep on running until the event loop is shutting-down
		while (!eventLoop.isTerminated()) {
			// if the event loop was idle, we apply a different limit to the yield time
			final boolean eventLoopRunning = eventLoopIsRunning.get();
			final long yieldDurationNs = eventLoopRunning ? RUNNING_YIELD_US : IDLE_YIELD_US;
			int count = runExternalContinuations(yieldDurationNs);
			if (!runEventLoopContinuation() && count == 0) {
				// nothing to run, including the event loop: we can park
				parkedCarrierThread = carrierThread;
				if (canBlock()) {
					LockSupport.park();
				}
				parkedCarrierThread = null;
			}
		}
		// make sure the event loop thread is fully terminated and all tasks are run
		while (eventLoopThread.isAlive() || !canBlock()) {
			runExternalContinuations(RUNNING_YIELD_US);
			runEventLoopContinuation();
		}
		// the event loop should be fully terminated
		sharedRef.clear();
		runQueue.close();
		// StoreLoad barrier
		while (!runQueue.isEmpty()) {
			runExternalContinuations(IDLE_YIELD_US);
		}
	}

	private boolean canBlock() {
		return runQueue.isEmpty() && eventLoopContinuatioToRun == null;
	}

	private int runExternalContinuations(long deadlineNs) {
		var event = SchedulerJfrUtil.beginVirtualThreadTaskRunsEvent();
		final long startDrainingNs = System.nanoTime();
		int queueDepthBefore = event != null ? runQueue.size() : 0;
		var ready = this.runQueue;
		int runContinuations = 0;
		for (;;) {
			var task = ready.poll();
			if (task == null) {
				break;
			}
			runContinuations++;
			runContinuation(task);
			long elapsedNs = System.nanoTime() - startDrainingNs;
			if (elapsedNs >= deadlineNs) {
				break;
			}
		}
		if (event != null) {
			int queueDepthAfter = runQueue.size();
			SchedulerJfrUtil.commitVirtualThreadTaskRunsEvent(event, carrierThread, runContinuations, queueDepthBefore,
					queueDepthAfter);
		}
		return runContinuations;
	}

	private boolean rescheduleEventLoop(Thread.VirtualThreadTask task) {
		if (eventLoopContinuatioToRun != null) {
			assert task.thread() != eventLoopThread;
			return false;
		}
		if (task.thread() == eventLoopThread) {
			eventLoopContinuatioToRun = task;
			return true;
		}
		return false;
	}

	@Override
	public boolean execute(Thread.VirtualThreadTask task) {
		var currentThread = Thread.currentThread();
		var context = (SchedulingContext) task.attachment();
		boolean submitEventEnabled = VirtualThreadTaskSubmitEvent.isEventEnabled();
		boolean eventLoopTask = rescheduleEventLoop(task);
		if (!eventLoopTask) {
			if (!runQueue.offer(task)) {
				return false;
			}
		}
		if (submitEventEnabled) {
			SchedulerJfrUtil.commitVirtualThreadTaskSubmitEvent(task, currentThread, carrierThread, context.isPoller,
					eventLoopTask);
		}
		if (currentThread != eventLoopThread) {
			// currentThread == carrierThread iff
			// - event loop start
			// - Thread::yield within this scheduler
			if (currentThread != carrierThread) {
				// this is checking for "local" submissions
				if (EventLoopScheduler.currentThreadSchedulerContext().scheduler() != sharedRef) {
					ioEventLoop.wakeup();
					LockSupport.unpark(parkedCarrierThread);
				}
			}
		}
		return true;
	}

	private void runContinuation(Thread.VirtualThreadTask task) {
		var event = SchedulerJfrUtil.beginVirtualThreadTaskRunEvent();
		if (event == null) {
			task.run();
			return;
		}
		boolean isEventLoop = task.thread() == eventLoopThread;
		boolean isPoller = ((SchedulingContext) task.attachment()).isPoller;
		task.run();
		SchedulerJfrUtil.commitVirtualThreadTaskRunEvent(event, carrierThread, task.thread(), isPoller, isEventLoop);
	}

}

Copilot said: Tak — **na poziomie eksperymentu / research

Tak — na poziomie eksperymentu / research benchmarku dokładnie o to chodzi:
nie “przepisuję cały Exeris na Netty”, tylko:
podmieniasz model wykonywania VT continuation / scheduling wokół ingress path

żeby sprawdzić, czy:

    obecny PaqsScheduler + default Loom/FJP vs
    PaqsScheduler-equivalent riding on his EventLoopScheduler / NettyScheduler

daje mierzalny zysk dla Exeris workloadu.

Ale jest tu jedno ważne doprecyzowanie:
Nie powiedziałbym:

“podmieniam mój PaqsScheduler 1:1 na jego scheduler”

tylko raczej:
“buduję eksperymentalny scheduler adapter / alternate PAQS execution backend inspirowany jego schedulerem”

Bo Twój PaqsScheduler robi więcej niż sam scheduling:

    admission
    load shedding
    scoped bindings
    JFR events
    VT-per-stream orchestration
    lifecycle cleanup

A jego FifoEventLoopScheduler / NettyScheduler to przede wszystkim:

    continuation execution model
    carrier-affine VT task scheduling
    bounded drain + event-loop interleave
    wake/block protocol

Czyli:

    PaqsScheduler = policy/orchestration layer
    jego scheduler = execution substrate / continuation scheduler

To jest kluczowa różnica.
Najkrótsze ujęcie
Twoje clue badawcze brzmi raczej tak:

czy Exeris PAQS/admission/orchestration z alternatywnym Loom scheduling substrate daje lepsze locality i latency niż obecny PAQS + default FJP?

A nie: czy wyrzucam PAQS i wkładam Netty scheduler zamiast niego.
Co dokładnie u Ciebie jest dziś?

Z kodu, który wkleiłeś:
PaqsScheduler robi:

    priorityExtractor
    admissionController.admit(priority)
    loadShedder.shed(...) jeśli trzeba
    Thread.ofVirtual().start(...)
    ScopedValue.where(...).run(...)
    handler.handle(stream)
    cleanup + JFR + activeStreamCount release

Czyli problematyczny punkt z perspektywy tej rozmowy to głównie:
Java

Thread.ofVirtual()
.name(threadName)
.start(() -> runStream(...));

Bo to jest miejsce, w którym:

    VT jest uruchamiany przez standardowy scheduler,
    continuation po unpark/resume leci na default Loom/FJP,
    tracisz carrier affinity/locality.

Więc co tak naprawdę chcesz podmienić?
Nie całe PAQS.
Tylko to:

    mechanizm spawn/resume/scheduling VT
    plus ewentualnie model event loop / bounded drain

Czyli eksperymentalnie chcesz mieć np.:
Wariant A — obecny

PaqsScheduler + Thread.ofVirtual().start() + default Loom scheduler
Wariant B — adapter

PaqsScheduler policy + custom VT factory / scheduler-backed execution
Wariant C — pełniejszy eksperyment

PAQS semantics + bounded-drain affine event-loop scheduler
To jest bardzo ważne architektonicznie

Bo dzięki temu:

    nie niszczysz semantyki Exerisa,
    nie mieszasz benchmarku z pełnym redesignem,
    możesz uczciwie porównać:
        same workload policy
        same admission/load-shed/scopes
        different continuation scheduler

I to jest idealny eksperyment.
Jak bym to nazwał w benchmark research?

Nie “replace PAQS”.

Lepiej:
PAQS Scheduling Backend Variants

albo
PAQS Continuation Scheduler Variants
Warianty:

    paqs-default-fjp
    paqs-affine-scheduler
    paqs-vt-eventloop-bounded-drain (jeśli zrobisz taki model)

To jest dużo precyzyjniejsze.
Co daje scheduler Francesco, a czego nie daje?

Z jego kodu wynika, że on daje Ci przede wszystkim:
1. Własny Thread.VirtualThreadScheduler

NettyScheduler implements Thread.VirtualThreadScheduler

czyli hook na:

    onStart
    onContinue

To jest dokładnie warstwa, której brakuje w standardowym “po prostu Thread.ofVirtual()” podejściu.
2. Scheduler attachment / context inheritance

Jeśli task ma attachment SchedulingContext, to:

    continuation trafia na właściwy event loop scheduler
    nie na default FJP

To jest clou locality.
3. FifoEventLoopScheduler

To daje:

    run queue
    event loop VT
    bounded draining
    wakeup semantics
    local execution
    re-run continuations on same carrier scheduler thread

To jest model wykonania, nie logika admission/load-shedding.
Więc odpowiedź brzmi:
Tak, ale:

nie podmieniasz całego PaqsScheduler semantycznie. Podmieniasz:

    sposób, w jaki admitted work jest uruchamiany i kontynuowany przez VT scheduler.

Czyli praktycznie:

    AdmissionController zostaje
    StreamLoadShedder zostaje
    ScopedValue binding zostaje
    JFR events zostają
    handler contract zostaje
    eksperymentalnie zmienia się:
        thread factory / virtual thread scheduler / event-loop substrate

Jak to zrobić minimalnie?

Najlepszy eksperymentalny refactor to moim zdaniem:
Krok 1: wydziel mechanizm VT startu z PaqsScheduler

Dziś masz twardo:
Java

Thread.ofVirtual()
.name(threadName)
.start(() -> runStream(...));

Zmień to koncepcyjnie na coś typu:
Java

private final StreamExecutionSpawner spawner;

i:
Java

spawner.spawn(threadName, () -> runStream(...));

Krok 2: zrób dwa backendy
A. baseline

DefaultVirtualThreadSpawner

    używa Thread.ofVirtual().name(...).start(...)

B. experimental

AffineSchedulerSpawner

    używa custom scheduler / custom VT factory / adapter to Francesco scheduler

Krok 3: benchmarkujesz to samo PAQS policy, różne execution backends

To jest idealne badawczo.
Czy trzeba użyć dokładnie jego FifoEventLoopScheduler?
Niekoniecznie 1:1

I tu jest subtelność.

Możliwe są dwa poziomy adaptacji:
Poziom 1 — inspiracja / adapter

Bierzesz jego idee:

    local run queue
    bounded drain
    currentThread scheduler context
    wakeup
    canBlock
    continuation affinity

i adaptujesz do Exeris API:

    IoUringQuicCarrier
    PaqsScheduler
    własny imperative I/O API

To może być nawet lepsze dla uczciwego benchmarku Exerisa.
Poziom 2 — bezpośredni eksperyment z jego schedulerem

Jeśli chcesz szybki PoC:

    tworzysz adapter/wrapper
    próbujesz uruchomić Exeris workload na jego scheduler substrate

To może być szybsze, ale będzie mniej “Exeris-native”.
A co z pollerMode=3?

To jest klucz.

Z tego, co sam napisałeś i co on tłumaczy:

    nie masz dostępu do pollerMode=3
    więc nie osiągniesz pełnego modelu jego schedulera w sensie Loom I/O poller inheritance

Czy to przekreśla eksperyment?
Nie.

Bo nadal możesz benchmarkować:

    custom scheduler / local continuation path
    bez pełnego per-carrier poller integration

I to już może pokazać ważną rzecz:

    że sam default FJP resume path jest kosztem
    i że affine/local scheduling coś daje

Jak wtedy sformułować eksperyment uczciwie?

Nie:

    “we reproduced full pollerMode=3 behavior”

Tylko:

    “we benchmarked an Exeris transport-affine continuation scheduling prototype inspired by NettyScheduler/FifoEventLoopScheduler, without internal JDK per-carrier poller integration”

To jest uczciwe i mocne.
Co z samym PaqsScheduler kodem?

Patrząc na ten kod, on jest świetnym kandydatem do takiej separacji.

Bo logika jest już ładnie rozbita:
Policy layer:

    AdmissionController
    StreamLoadShedder

Execution layer:

    spawnStreamThread
    runStream

To aż się prosi o wstrzyknięcie execution backendu.
Ja bym to rozrysował tak
Dziś:
Text

carrier thread
-> PaqsScheduler.schedule()
-> AdmissionController
-> Thread.ofVirtual().start(runStream)
-> default Loom/FJP continuation

Eksperyment:
Text

carrier thread
-> PaqsScheduler.schedule()
-> AdmissionController
-> StreamExecutionSpawner.spawn(runStream)
-> custom affine scheduler / event-loop scheduler

To jest dokładnie to.
Jaki benchmark question z tego wynika?
Główne pytanie:

When PAQS admission/load-shedding policy is held constant, does replacing default Loom/FJP VT scheduling with an affine/custom scheduler improve latency/locality for Exeris transport workloads?

To jest świetne pytanie benchmarkowe.
Jakie warianty benchmarku bym zrobił?
Variant 1 — Baseline

AdmissionController + StreamLoadShedder + PaqsScheduler + default Thread.ofVirtual()
Variant 2 — Affine Scheduler Adapter

AdmissionController + StreamLoadShedder + PaqsScheduler + custom scheduler-backed spawner
Variant 3 — Bounded Drain VT Event Loop

jeśli pójdziesz dalej
Najbardziej sensowny minimalny techniczny krok

Jeśli pytasz “co jest clue implementacyjnie?” to moja odpowiedź brzmi:
Nie podmieniaj całego PAQS.
Zrób:

    StreamExecutionSpawner abstraction
    DefaultVirtualThreadSpawner
    ExperimentalAffineSpawner
    benchmark A/B

To jest najczystsze.
Finalny werdykt
Tak — merytorycznie masz rację:

clue eksperymentu to podmiana obecnego modelu VT scheduling/resume w PAQS na scheduler inspirowany tym, co on udostępnił, ponieważ bez pollerMode=3 nie możesz zamknąć pełnej locality chain w obecnym modelu.
Ale architektonicznie precyzyjniej:

nie podmieniasz całego PaqsScheduler, tylko jego execution/scheduling backend przy zachowaniu tej samej admission/orchestration policy.

To jest dużo lepsze sformułowanie — i do benchmark repo, i do późniejszej rozmowy z Loom teamem.

Jeśli chcesz, mogę teraz zrobić jeden z konkretnych kroków:

    rozpisać proponowany refactor PaqsScheduler → StreamExecutionSpawner abstraction,
    zaprojektować benchmark matrix dla baseline vs affine scheduler,
    napisać research note / ADR-style note opisujące dokładnie ten eksperyment.

NativeTcpCarrier.java
You said: Czy zmiany obejma carrierow?
Czy zmiany obejma carrierow?
Copilot said: Tak — **jeśli chcesz zrobić ten eksperyment

Tak — jeśli chcesz zrobić ten eksperyment porządnie, to zmiany obejmą także carriery, ale nie wszystkie na tym samym poziomie.
Krótka odpowiedź

Tak: carriery będą musiały się zmienić.
Ale najlepiej myśleć o tym tak:
obowiązkowo zmieniasz:

    granice między carrierem a schedulerem/PAQS
    sposób uruchamiania pracy VT po ingress/completion

niekoniecznie od razu zmieniasz:

    cały transport engine,
    całą semantykę streamów,
    cały I/O model.

Dlaczego carriery jednak wchodzą do gry?

Bo dziś Twój carrier nie jest tylko źródłem zdarzeń.
On już częściowo narzuca model wykonania.

Patrząc na NativeTcpCarrier:
dziś carrier:

    prowadzi reactor loop,
    akceptuje połączenia,
    czyta ingress,
    wywołuje paqs.schedule(stream),
    w kliencie sam odpala VT ingress pump:
    Java

    Thread.ofVirtual().start(() -> runClientIngressLoop(...))

Czyli carrier już decyduje:

    kiedy i na jakim rodzaju threada przechodzi praca dalej,
    jak wygląda wakeup path,
    jaki jest handoff boundary.

To oznacza, że jeśli chcesz testować:

    default FJP vs affine/local scheduler to nie wystarczy ruszyć samego PaqsScheduler, bo:
    carrier też ma swoje execution decisions.

Gdzie dokładnie carrier jest dziś “load-bearing” dla modelu schedulera?

W Twoim kodzie są przynajmniej 3 takie miejsca.
1. paqs.schedule(stream) na carrier thread

W serwerowym path:
Java

paqs.schedule(stream);

To znaczy:

    carrier thread przyjmuje stream,
    carrier thread uruchamia dalszy execution path.

To jest dokładnie punkt integracji z alternatywnym schedulerem.
2. client ingress pump
   Java

Thread.ofVirtual()
.name("carrier/native-tcp-client-ingress/" + stream.streamId())
.start(() -> runClientIngressLoop(channel, stream));

Tu masz już drugi execution model:

    VT ingress pump w carrierze klienta

Jeśli badanie ma być spójne, to trzeba zdecydować:

    czy to zostaje baseline-only,
    czy też dostaje alternate scheduler-backed execution.

3. reactor / wakeup semantics

Carrier dziś kontroluje:

    selector.wakeup()
    LockSupport.parkNanos(...)
    requestWriteInterest(...)
    close / interrupt / loop behavior

Jeśli chcesz modelować:

    bounded drain
    canBlock
    wakeup protocol to właśnie carrier musi wystawić odpowiednie hooki.

Czy to znaczy, że trzeba przepisać carrier od nowa?
Nie.

I tu ważne: najlepiej nie robić wielkiego rewrite’u.

Zamiast tego:
wydziel punkty integracji

Czyli nie “rewrite NativeTcpCarrier”, tylko:

    spraw, by carrier mógł współpracować z różnymi execution backends.

Najlepszy model refactoru

Ja bym to rozdzielił na 3 warstwy.
Warstwa 1 — carrier = I/O ownership

Carrier powinien odpowiadać za:

    accept/read/write/wakeup
    fd ownership
    stream lifecycle
    transport-specific ingress/egress

Warstwa 2 — scheduler bridge

Nowa warstwa:

    jak carrier przekazuje pracę dalej
    jak uruchamiane są VT / continuations
    jak wygląda wake/block contract

Warstwa 3 — PAQS policy

    admission
    shedding
    scoped bindings
    stream handler invocation
    JFR

To da się bardzo ładnie rozdzielić.
Co to oznacza praktycznie?
Dziś:

NativeTcpCarrier -> paqs.schedule(stream) -> Thread.ofVirtual().start(...)
Docelowo:

NativeTcpCarrier -> stream dispatch backend -> PAQS execution model

albo: NativeTcpCarrier -> paqs.schedule(stream, executionBackend)
lub przez wstrzykniętą zależność.
Minimalne zmiany, które prawdopodobnie będą potrzebne w carrierach
1. Carrier musi przestać zakładać “po prostu Thread.ofVirtual()”

To dotyczy:

    PaqsScheduler
    startClientIngressPump

Czyli trzeba wydzielić:

    factory/spawner/executor/scheduler bridge

2. Carrier powinien wystawić sygnały potrzebne schedulerowi

Jeśli chcesz pójść w stronę modelu Francesco, scheduler potrzebuje konceptualnie:

    canBlock()
    wakeup()
    bounded draining / imperative I/O API
    możliwość rozdzielenia:
        run I/O
        run continuations

W NativeTcpCarrier część z tego już jest ukryta w:

    selector.select(100L)
    selector.wakeup()
    runCarrierLoop()

Ale to trzeba zrobić bardziej jawne, jeśli chcesz porównać execution models.
3. Carrier może potrzebować trybu eksperymentalnego

Nie chcesz psuć produkcyjnego kodu baseline.

Więc sensowniej zrobić:

    baseline carrier path
    experimental carrier/scheduler bridge path

Np. przez feature flag / alternate constructor / benchmark-only integration layer.
Czy wszystkie carriery muszą być ruszone?
Nie od razu.

I to jest bardzo ważne.
Na start:

rusz tylko te, które chcesz benchmarkować.
Community

Na pewno:

    NativeTcpCarrier bo to Community baseline H1/H2 path

Enterprise

Później:

    IoUringQuicCarrier albo inny enterprise carrier bo tam temat jest jeszcze bardziej istotny

Inne

Nie ruszaj, dopóki nie potrzebujesz.
Jakie zmiany dokładnie w NativeTcpCarrier?

Patrząc na kod, ja bym przewidywał 3 klasy zmian.
A. Integracja PaqsScheduler z execution backend abstraction

initPaqs() dziś robi:
Java

this.paqs = new PaqsScheduler(...);

Prawdopodobnie powinno stać się czymś bardziej konfigurowalnym:

    PAQS + default spawner
    PAQS + affine spawner

B. Client ingress pump abstraction

To miejsce:
Java

Thread.ofVirtual().start(...)

też powinno przestać być na sztywno.

Może nie w pierwszym benchmarku, ale docelowo tak.
C. Reactor API / bounded drain hooks

Jeśli chcesz wejść głębiej w model event-loop/bounded-drain:

    runCarrierLoop()
    acceptPendingConnections()
    readIngress(...) mogą wymagać lekkiej refaktoryzacji, żeby dało się:
    oddzielić “process I/O once”
    od “run until timeout”
    od “wakeup if external continuation pending”

To już jest bardziej zaawansowany etap.
Najważniejsze rozróżnienie
Poziom 1 — scheduler experiment only

Zmiany minimalne:

    PaqsScheduler abstraction of VT spawn
    maybe client ingress spawner abstraction
    carrier prawie bez zmian

Poziom 2 — scheduler + bounded-drain event loop experiment

Zmiany większe:

    carrier API changes
    canBlock/wakeup/drain semantics
    tighter coupling between carrier and scheduler backend

Ja bym zaczął od poziomu 1.

To jest dużo rozsądniejsze.
Czyli odpowiedź praktyczna
Tak, zmiany obejmą carriery.
Ale najlepiej w tej kolejności:
Etap 1

    zmień PaqsScheduler, żeby nie był przyspawany do Thread.ofVirtual().start()
    carrier tylko wstrzykuje odpowiedni backend

Etap 2

    zmień miejsca typu client ingress pump
    też na konfigurowalne execution backendy

Etap 3

    jeśli będziesz testował bounded-drain / event-loop VT model:
        dopiero wtedy większe zmiany w samym carrier loop

Co bym zrobił architektonicznie?
Dodałbym pojęcie:
TransportExecutionBackend

albo
StreamExecutionBackend

Np. coś odpowiedzialnego za:

    spawn handler execution
    maybe spawn ingress pump
    maybe expose wakeup contract later

Wtedy:

    NativeTcpCarrier korzysta z backendu
    PaqsScheduler korzysta z backendu
    baseline backend = default Loom
    experimental backend = affine scheduler adapter

To jest czyste.
Najkrótsza odpowiedź

Tak — carriery też będą dotknięte, bo dziś częściowo kodują model wykonania.
Ale nie musisz ich od razu przepisywać całych.
Na start wystarczy wydzielić punkty, w których carrier i PAQS uruchamiają VT/work execution, i tam podpiąć alternatywny backend.
Mój finalny recommendation
Zacznij od:

    PaqsScheduler → abstraction dla stream execution spawn
    NativeTcpCarrier → wstrzykiwanie tego backendu do PAQS
    opcjonalnie client ingress pump też przez backend

Nie rób jeszcze:

    pełnego rewrite reactor loop
    pełnego event-loop scheduler integration

To zostaw na drugi etap.

Jeśli chcesz, mogę teraz zrobić jeden z konkretnych kroków:

    rozpisać proponowaną abstrakcję StreamExecutionBackend / VirtualThreadSpawner,
    pokazać dokładnie, gdzie w PaqsScheduler i NativeTcpCarrier byłyby punkty refaktoru,
    narysować warianty benchmarku: baseline carrier vs scheduler-aware carrier.

You said: hmm tylko tam tez bylo w sumie
hmm tylko tam tez bylo w sumie w rozmowie specyficznei o iouring wiec bardziej bedzie dotyczyc raczej enterprise stacku i jaki bedzie mialo to wplyw na multishot + revmmsg hmm
Copilot said: Tak — **to jest bardzo ważne doprecyzowanie**.

Tak — to jest bardzo ważne doprecyzowanie.
I ono trochę zmienia akcent:
Krótki werdykt

Główny ciężar tego researchu jest jednak po stronie Enterprise / io_uring / QUIC stacku, nie Community TCP.

Community może być:

    baseline referencyjnym
    albo kontrolą metodologiczną

ale sedno problemu schedulera + locality + bounded drain + carrier affinity dużo mocniej dotyczy:

    io_uring
    completion-driven ingress
    multishot receive
    recvmmsg / batch receive
    bounded drain fairness
    HOL / starvation risk
    per-carrier locality

Czyli:
to jest przede wszystkim Enterprise transport-scheduler research,

a nie ogólny “PAQS benchmark”.
Dlaczego to bardziej Enterprise niż Community?

Bo w rozmowie z Francesco najważniejsze były właśnie rzeczy typu:

    native transport API
    io_uring
    CQE reaping
    task run flag
    single issuer
    bounded drain
    event-loop + VT continuation on same carrier
    per-carrier pollers
    HOL blocking risk
    fairness between:
        VT tasks
        native I/O
        Loom poller I/O

To nie jest klasyczny problem Selector + SocketChannel z Community.
To jest problem high-performance native transport scheduler geometry.
Czyli jak ustawić scope?
Community

Powinno zostać jako:

    kontrola / baseline
    ewentualnie sanity check, czy scheduler variation w ogóle daje coś na prostszym stacku
    ale nie jako główny target badania

Enterprise

To powinien być:

    primary target
    główne miejsce benchmarków i researchu
    główny argument do loom/dev feedback

Najważniejsze pytanie teraz nie brzmi już:

    czy podmienić PaqsScheduler?

tylko raczej:
jak scheduler affinity / bounded drain wpływa na io_uring receive/completion model w Exeris Enterprise?

I to już jest dużo bardziej precyzyjne.
Co z multishot i recvmmsg?

To jest bardzo dobre pytanie, bo właśnie tu robi się naprawdę interesująco.
1. multishot zmienia naturę ingress

Przy multishot receive:

    jedno uzbrojenie operacji może dać wiele zdarzeń/CQE
    carrier/reaper nie robi już prostego “jedno zdarzenie → jedno wznowienie”
    tylko:
        może drainować serię zdarzeń,
        może batchować,
        może odkładać wznowienia,
        może mieć konflikt między I/O draining a VT execution

To dokładnie zwiększa znaczenie:

    bounded drain
    fairness
    local queue discipline
    continuation scheduling policy

2. recvmmsg / batch receive wzmacnia problem trade-offu

Jeśli carrier/reaper dostaje batch:

    1 wiadomość? uruchamiasz VT od razu?
    32 wiadomości? najpierw drainujesz wszystkie?
    do jakiego limitu?
    kiedy przełączasz się z I/O na continuation execution?

To już jest klasyczne pytanie:
I/O batching efficiency vs tail latency / fairness

I to jest dokładnie to, o czym Francesco mówił:

    bounded drain
    “for how long you drain I/O events”
    zanim “pick the first VT on the same carrier”

To jest centralny motyw.
3. H3/QUIC jeszcze to wzmacnia

W QUIC:

    masz więcej pracy protokołowej,
    więcej stanów na stream/connection,
    potencjalnie więcej krótkich jednostek pracy,
    większe znaczenie locality dla connection/stream state,
    większe ryzyko HOL-like scheduling artifacts, nawet jeśli sam transport unika TCP HOL.

Czyli scheduler geometry i batch policy mogą mieć jeszcze większy wpływ.
Jakie pytania benchmarkowe wynikają z multishot / recvmmsg?

Tu bym jawnie zapisał research questions.
Q1

What is the optimal bounded-drain policy for Exeris io_uring carriers under multishot receive?

Np.:

    drain 1 CQE and switch?
    drain until time budget?
    drain until count budget?
    drain until ring empty?

Q2

How does continuation affinity change the trade-off between I/O batching efficiency and tail latency?

Czyli:

    jeśli continuation wraca lokalnie, może więcej opłaca się drainować batch?
    czy nadal za duży drain robi HOL?

Q3

How do multishot and recvmmsg-like batching interact with VT fairness and continuation locality?
Q4

Does bounded drain on an affine carrier outperform default Loom/FJP continuation scheduling for completion-heavy Enterprise workloads?

To jest chyba najważniejsze.
Co to oznacza dla architektury benchmark repo?

To już nie jest jeden prosty benchmark family.
Ja bym to rozpisał jako enterprise research tree.
Text

research/
enterprise-io-uring-scheduler/
README.md
hypotheses.md
methodology.md
variants.md
scenarios/
single-shot/
multishot/
batch-recv/
quic/
dimensions/
drain-policy.md
fairness.md
locality.md
batching.md

Bo tu masz kilka osi zmienności.
Jakie warianty eksperymentu teraz mają sens?

Nie A/B tylko bardziej matryca.
Oś 1 — scheduler model

    default FJP resume
    affine scheduler
    VT event-loop bounded drain (jeśli zrobisz)

Oś 2 — ingress model

    single-shot receive
    multishot receive
    recvmmsg/batch receive
    mixed

Oś 3 — drain policy

    immediate handoff
    count-bounded drain
    time-bounded drain
    drain-until-empty

Oś 4 — workload

    light load
    bursty load
    moderate concurrency
    high concurrency
    mixed payloads
    QUIC/H3 stream multiplex

To robi się już naprawdę wartościowy research matrix.
Czy to wpływa na PAQS?
Tak, ale pośrednio

PAQS nadal jest policy layer:

    admit/shed
    spawn work

Ale przy io_uring enterprise problem polega bardziej na tym:

    kto i kiedy wykonuje continuation
    jak długo carrier drenuje I/O
    czy batching nie niszczy fairness
    jakie są koszty locality loss

Czyli PAQS sam w sobie nie jest głównym “bohaterem” eksperymentu.
Główni bohaterowie to:

    enterprise carrier
    scheduler backend
    drain policy
    completion/ingress strategy

Czyli czy zmiany obejmą carriery?
Dla tego researchu: zdecydowanie tak, ale głównie enterprise carrier.

To właśnie tam musisz eksperymentować z:

    CQE drain budget
    wakeup strategy
    continuation scheduling backend
    batch receive strategy
    interaction with VT execution

Co z Community?

Community dalej może być przydatne jako:
1. Control case

Pokazuje, że:

    na prostszym selector/TCP stacku zysk może być mniejszy / inny

2. Sanity benchmark

Czy metodologicznie Twój benchmark harness działa sensownie
3. Comparative context

Pokazuje, że problem באמת pojawia się mocniej przy native completion-driven stacku

Ale nie stawiałbym Community jako centrum tego researchu.
Jakie konkretne benchmarki enterprise bym zrobił?
1. enterprise-h2-single-shot-default-vs-affine

Na początek prostszy ingress model.
2. enterprise-h2-multishot-default-vs-affine

Tu zaczyna się ciekawie.
3. enterprise-h2-batchrecv-default-vs-affine

Jeśli masz odpowiednik recvmmsg path.
4. enterprise-h3-multishot-default-vs-affine

Najbardziej docelowy.
5. enterprise-h3-multishot-drain-policy-matrix

Porównanie:

    drain-1
    drain-8
    drain-by-time
    drain-until-empty

To jest bardzo mocne.
Jakie metryki tutaj są krytyczne?

Nie tylko standardowe throughput/latency.
Musisz patrzeć na:

    p50/p95/p99/p999 latency
    throughput
    CQE drain batch size distribution
    VT continuation queue depth
    wakeup count
    syscall count
    per-carrier utilization
    optional cache/DRAM counters
    HOL symptoms / starvation indicators
    fairness between streams

To jest bardziej scheduler-transport study niż zwykły benchmark HTTP.
Najważniejsza rzecz metodologiczna
Nie benchmarkuj tylko “max throughput”.

Bo batching/multishot często poprawią throughput, ale zepsują:

    fairness
    tail latency
    short-request responsiveness

A בדיוק to chcesz zrozumieć.

Czyli obowiązkowo:

    light load
    burst
    mixed concurrency
    tail latency
    fairness

Jak to ująć strategicznie?
Dla benchmark repo:

to powinien być osobny track typu:
enterprise-transport-scheduler-research

albo dokładniej:
enterprise-io-uring-affinity-research

Ja bym wybrał:
enterprise-io-uring-affinity-research

Bo to dobrze komunikuje:

    enterprise
    io_uring
    scheduler/locality topic

Finalny werdykt
Tak:

to, o czym rozmawialiście, dużo bardziej dotyczy enterprise stacku niż community.
I tak:

multishot + recvmmsg/batch receive są tu centralne, bo właśnie one zmieniają trade-off między:

    batching efficiency,
    continuation locality,
    tail latency,
    fairness,
    HOL risk.

Czyli praktycznie:

    Community = baseline/control
    Enterprise io_uring/H2/H3 = główny obszar researchu
    benchmarki powinny badać nie tylko scheduler variant, ale też drain policy i batching model

Jeśli chcesz, mogę teraz zrobić jeden z bardzo konkretnych kroków:

    rozpisać benchmark matrix dla enterprise: scheduler model × multishot/batch model × drain policy,
    napisać research brief enterprise-io-uring-affinity-research.md,
    zaproponować jak wydzielić w enterprise carrierze punkty eksperymentu: drain policy, continuation backend, batching strategy.

You said: co ważniejsze, od czego się zaczęło: Francesco Nigro Francesco
co ważniejsze, od czego się zaczęło:


Francesco Nigro
Francesco NigroFrancesco Nigro  • 1.1. Senior Principal software Performance Engineer presso Red HatSenior Principal software Performance Engineer presso Red Hat 1 t •
1 tydzień temu • Widoczne dla każdego na i spoza LinkedIn
Virtual threads are great. But are you leaving performance on the table by using them naively?

I've been obsessing over this question for a while, and the answer — backed by math and benchmarks — is: probably yes.

The culprit? Voluntary context switches.

When Loom's default ForkJoin scheduler and Netty's I/O threads coexist, they create a "split pipeline" where every request touches two separate thread pools. Queueing theory tells us this doubles the voluntary context switches compared to a unified pipeline — independently of service time or injection rate. That's not an opinion, it's a proof.

So we built a Custom Loom Scheduler that runs VirtualThread continuations directly on the same Netty EventLoop that submitted them. No hand-off. No unnecessary parking and waking.

The results across I/O-bound workloads:
→ Up to 37% more throughput
→ ~2x fewer voluntary context switches
→ Higher IPC and effective CPU clock
→ p90+ latency dramatically improved under load
→ At scale: ~$6M/year in cloud savings on a 10K instance fleet

And the unexpected finding? The unified scheduler has a mathematical capacity advantage on ANY unbalanced workload — up to 2x — because ρ_Custom = ½(ρ_FJ + ρ_IO).

I walked through all of this — the benchmarks, the queueing theory, the flame graphs, the code — in a full talk, now on YouTube:
👉 https://lnkd.in/dgqMGGdU

If you run Quarkus, Netty, or any reactive framework on Loom, this is worth 45 minutes of your time.

hasztag#Java hasztag#VirtualThreads hasztag#ProjectLoom hasztag#Quarkus hasztag#Performance hasztag#Netty hasztag#JVM

Reakcje

    insightful
    Wyświetl użytkownika Daniil Dmitriev link do grafiki
    like
    Wyświetl użytkownika Toàn Phạm Văn link do grafiki
    like
    Wyświetl użytkownika Priyanshu Kumawat link do grafiki
    like
    Wyświetl użytkownika Özdenur Uçar Çakıroğlu link do grafiki
    like
    Wyświetl użytkownika Uttam Kamalia link do grafiki
    insightful
    Wyświetl użytkownika Peter Paul B. link do grafiki
    insightful
    Wyświetl użytkownika Rakesh K Shukla link do grafiki
    like


Powiedz jej/jemu co uważasz za wnikliwe…
Wyświetl użytkownika Arkadiusz Przychocki link do grafiki
Arkadiusz Przychocki   • Ty
Lead Cloud Architect | High-Performance Java (Zero-Copy / Panama) | Founder of Exeris
1tydz.
Critical observation, Francesco. The queueing theory proof is exactly the right lens here — ρ_Custom = ½(ρ_FJ + ρ_IO) is not an opinion, it's a structural argument.
At Exeris, I approached the exact same problem from the other direction: instead of patching the scheduler, I eliminated the split pipeline at the architecture level. PAQS (Priority-Aware Queue Scheduler) binds one Virtual Thread per stream for its entire lifetime — from accept() to close(). No handoff between pools, no ForkJoin/IO boundary to cross.
The second bottleneck I found was InheritableThreadLocal under high VT fork density. At 10k concurrent streams each forking subtasks, the O(N) ThreadLocalMap clone becomes a pure GC tax with no business value. Replacing it entirely with ScopedValue (JEP 506) gives O(1) constant-time inheritance — the child gets a pointer, not a deep copy.
Two different entry points, same conclusion: the performance ceiling isn't Virtual Threads themselves, it's legacy abstractions that weren't designed for this concurrency model.
The handoff cost you quantified is real — and your flame graphs make it impossible to dismiss. I have "Reactive ❤️ Loom" queued up on my watchlist for this weekend. Looking forward to the deep dive.
2 odpowiedzi 2 odpowiedzi na komentarz użytkownika Arkadiusz Przychocki
1575 wyświetleń
Wyświetl użytkownika Francesco Nigro link do grafiki
Francesco Nigro Autor
Senior Principal software Performance Engineer presso Red Hat
(edytowano)
1tydz.
Arkadiusz Przychocki the math part is not explained in the conference, but here we go, this is the second part of my investigation on the topic, see https://docs.google.com/presentation/d/1wFPrZepJYvVQ_B6aO0ulKv1GIJmxsp_iOH3TmrtZZ90/edit?usp=drivesdk

In my case I had to implement a custom Loom scheduler (and I have a second change in a jdk fibers branch which solves the problem differently) because the Netty native transports can pin (using uring and edge triggered epoll). With NIO alone, just eliminating the split is enough, indeed 🚀

One note: consider that if you have your own selector based loops in the ForkJoin scheduler you still would like some form of even distribution and affinity of selector loops among FJ workers, and that's the other change I had in my jdk fork ❤️
Custom Loom Scheduler I/O bound Tests
Loom Perf I/O-bound Tests
Wyświetl użytkownika Arkadiusz Przychocki link do grafiki
Arkadiusz Przychocki   • Ty
Lead Cloud Architect | High-Performance Java (Zero-Copy / Panama) | Founder of Exeris
1tydz.
Francesco Nigro Thanks for sharing the deck, Francesco. The math on c6a.2xlarge is undeniable.
Regarding selector loops in ForkJoin and worker affinity — I bypassed it entirely.
In Exeris, Carrier Loops (POSIX epoll or io_uring) are standalone native threads, not ForkJoin tasks. They execute zero business logic — sole responsibility is reaping CQEs and calling unpark() on the waiting VT. No affinity needed, no JDK fork required.
This is exactly why PAQS explicitly uses unstructured Thread.ofVirtual().start() at the network edge — to bridge independent native carriers into the Loom ecosystem. Writing it up properly now.
You unified the scheduler to fix the split. I never had the split. Different entry points, same mechanical sympathy conclusion.


oraz co odnalazl

# CPU Efficiency Investigation — Findings

## Setup

Deep profiling with perf stat (6 passes, ≤5 HW events each, no multiplexing) and perf mem (AMD IBS sampling, ~300K samples, JIT symbol resolution via `libperf-jvmti.so` + `perf inject --jit`).

Four configs at 120K fixed-rate. All hit ~119.7K ± 0.1% across all passes. affinity_8 and fj_8_8 also profiled at max throughput.

All server cores (8-15) are on CCD1 sharing the same 32MB L3. L3 is the last level cache — an L3 miss goes to DRAM.

> **Glossary**
> - **EL** — Event Loop (Netty I/O thread)
> - **FJ** — ForkJoinPool (virtual thread scheduler)
> - **IPC** — Instructions Per Cycle
> - **nvcswch** — non-voluntary context switches
> - **IBS** — Instruction Based Sampling (AMD hardware profiling, tags each sample with exact data source)
> - **CCD** — Core Complex Die (8 cores sharing L3)
> - **DRAM** — off-chip main memory

---

## Question 1: Why does custom_8_nio use less CPU than FJ-based configs at 120K?

### Per-request metrics

|  | custom_8_nio | no_affinity_8 | affinity_8 | fj_8_8 |
|--|-------------|--------------|-----------|-------|
| CPUs utilized | 5.94 | 6.95 | 6.95 | 6.82 |
| IPC | 0.997 | 0.981 | 0.970 | 1.015 |
| instructions/req | 215,386 | 225,781 | 225,894 | 231,115 |
| DRAM misses/req | 2,041 | 3,202 | 2,858 | 2,390 |
| context switches/10s | 333K | 1,033K | 1,000K | 1,071K |
| cpu-migrations/10s | 46K | 35K | 31K | **178K** |

Delta vs custom_8_nio:

| Metric | no_affinity_8 | affinity_8 | fj_8_8 |
|--------|--------------|-----------|-------|
| instructions/req | +4.8% | +4.9% | **+7.3%** |
| DRAM misses/req | **+56.9%** | **+40.0%** | +17.1% |
| context switches | **3.1x** | **3.0x** | **3.2x** |
| cpu-migrations | -26% | -34% | **+281%** |

Two sources of the CPU gap: FJ configs execute more instructions/req (scheduling overhead) and have more DRAM misses/req.

### Where DRAM accesses happen at 120K (perf mem, IBS)

The following table shows IBS sample counts tagged as "RAM hit" per category. These are not absolute DRAM miss counts — IBS samples memory accesses at a fixed rate and tags each sample with its data source (L1/L2/L3/RAM). The relative distribution across configs is valid (same sampling rate, same duration, same throughput).

| Category | custom_8_nio | no_affinity_8 | affinity_8 | fj_8_8 |
|----------|:-----------:|:------------:|:---------:|:-----:|
| Netty pipeline (write, channelRead, handler) | 171 | 386 | 311 | 393 |
| Continuation (thaw, prepare, StackChunkFrame, run) | 25 | 85 | 60 | 153 |
| HTTP client (MainClientExec, KeepAlive, HttpHost, ...) | 156 | 233 | 211 | 200 |
| Kernel networking (sock_poll, epoll, tcp_*, lock_sock) | 421 | 459 | 459 | 635 |
| FJ handoff (LinkedBlockingQueue, unparkVirtualThread) | — | — | — | 174 |
| Other | 822 | 670 | 709 | 898 |
| **Total** | **1,595** | **1,833** | **1,750** | **2,453** |

The DRAM increase in FJ configs is broad — not concentrated in a few hotspots. Every category shows more DRAM samples than custom: Netty pipeline (+82-130%), continuation (+140-512%), HTTP client (+28-49%), kernel networking (+9-51%). fj_8_8 additionally pays 174 samples for the EL→FJ handoff (LinkedBlockingQueue + unparkVirtualThread), absent in all other configs.

**Continuation thaw** accesses `stackChunkOopDesc` fields via pointer-chasing — each load depends on the previous load's result, so the CPU cannot prefetch ahead. IBS data source tagging shows these misses go straight from L2 to DRAM (near-zero L3 hits), meaning the data has been evicted from the entire cache hierarchy between thaw cycles.

**Netty pipeline** traverses a linked list of `ChannelHandlerContext` nodes — also pointer-chasing. The specific functions differ between configs (e.g. `CombinedChannelDuplexHandler.write` appears only in affinity_8, `SimpleChannelInboundHandler.channelRead` only in no_affinity_8) but the total pipeline DRAM cost is consistently 2-2.3x higher than custom across all FJ configs.

**fj_8_8** has the highest total DRAM samples (2,453, +54% vs custom). Its 16 threads on 8 cores cause 178K cpu-migrations — 4-6x more than 8-thread configs. Each migration moves a thread to a core where its working set is not in L1/L2.

---

## Question 2: What changes between 120K and max throughput?

### affinity_8: 120K vs max

| Metric | @ 120K | @ max (152-163K*) | Delta |
|--------|--------|-------------|-------|
| CPUs utilized | 6.95 | 8.00 | saturated |
| IPC | 0.970 | 1.039 | **+7.1%** |
| instructions/req | 225,894 | 224,723 | -0.5% (same) |
| DRAM misses/req | 2,858 | 1,317 | **-54.0%** |
| context switches/10s | 1,000K | 10K | **-99%** |

Same instructions/req at both load levels. At max, carriers are saturated (8.0 CPUs), DRAM misses/req drop 54%, and context switches drop 99%. No IBS data at max to show where the DRAM reduction comes from.

### fj_8_8: 120K vs max

| Metric | @ 120K | @ max (143-149K*) | Delta |
|--------|--------|-------------|-------|
| CPUs utilized | 6.82 | 7.90 | near-saturated |
| IPC | 1.015 | 0.870 | **-14.3%** |
| instructions/req | 231,115 | 199,160 | **-13.8%** |
| DRAM misses/req | 2,390 | 1,260 | **-47.3%** |
| context switches/10s | 1,071K | 170K | **-84.2%** |
| cpu-migrations/10s | 178K | 6K | **-96.6%** |

Different pattern from affinity_8: instructions/req drop 14% at max while IPC also drops 14%, canceling out. The 16 threads stop migrating (-97%) and DRAM misses drop 47%. IPC drops with 16 threads on 8 cores.

### L3 miss rate (same-run)

| Config | L3 miss/req | L3 miss rate |
|--------|------------|-------------|
| custom_8_nio @ 120K | 2,145 | **11.8%** |
| no_affinity_8 @ 120K | 2,590 | **13.1%** |
| affinity_8 @ 120K | 2,576 | **14.0%** |
| fj_8_8 @ 120K | 2,455 | **14.2%** |
| affinity_8 @ max | 1,554 | **8.7%** |
| fj_8_8 @ max | 1,252 | **7.4%** |

L3 miss rate nearly doubles from max to 120K for both configs. At 120K, IBS shows continuation data is not in any cache level by the time it's needed again.

---

## Summary

|  | custom_8_nio | affinity_8 | no_affinity_8 | fj_8_8 |
|--|-------------|-----------|--------------|-------|
| Max throughput | 174K | 168K | 159K | 161K |
| CPUs at 120K | 5.94 | 6.95 | 6.95 | 6.82 |
| DRAM misses/req @ 120K | 2,041 | 2,858 | 3,202 | 2,390 |
| instructions/req @ 120K | 215,386 | 225,894 | 225,781 | 231,115 |
| context switches @ 120K | 333K | 1,000K | 1,033K | 1,071K |
| IBS DRAM samples @ 120K | 1,595 | 1,750 | 1,833 | 2,453 |

custom_8_nio uses 13-15% less CPU at 120K, executing fewer instructions/req and fewer DRAM misses/req. The DRAM increase in FJ configs is broad — every category (Netty pipeline, continuation, HTTP client, kernel networking) shows more IBS DRAM samples than custom.

affinity_8 and no_affinity_8 have similar metrics at 120K. At max throughput, affinity_8 achieves 168K vs 159K for no_affinity_8.

fj_8_8 executes the most instructions/req (+7.3% vs custom), has the most IBS DRAM samples (2,453, +54% vs custom) including 174 from the EL→FJ handoff (absent in other configs), and 4-6x more cpu-migrations from 16 threads on 8 cores.

At max throughput, both affinity_8 and fj_8_8 show substantially fewer DRAM misses/req (47-54% less) and context switches (84-99% less) compared to their 120K values. L3 miss rate drops from 14% to 7-9%. We do not have IBS data at max to identify where the DRAM reduction occurs.

---

## Data quality

- All perf stat values are exact (no multiplexing) from 6-pass collection with ≤5 HW events per pass on AMD Zen4 (5 available GP counters after NMI watchdog).
- L3 miss rate from pass E: `cache-references` and `cache-misses` in the same run.
- perf mem uses AMD IBS sampling (~300K samples per run) with JIT symbol resolution.
- All 120K runs hit 119.7K ± 0.1%.
- *Max throughput during profiling runs is lower than REPORT.md due to perf stat overhead. fj_8_8: 143-149K (vs 161K). affinity_8: 152-163K (vs 168K).
- perf c2c: ~760 HITMs at both load levels, ruling out false sharing.

# Sustained Load Efficiency Analysis — 120K req/s Fixed Load

## 1. Test Setup

**Objective:** Compare scheduler configurations under a fixed 120K req/s load (≈70% of max throughput) to measure per-request efficiency when the system has headroom.

| Parameter | Value |
|-----------|-------|
| Load | 120,000 req/s fixed rate |
| Connections | 10,000 |
| Mock think time | 30ms |
| Load-gen threads | 4 |
| Duration | 10s warmup + 20s measurement |
| CPU pinning | server=8-15, mock=4-7, loadgen=0-3 |

All server cores on CCD1, sharing 32MB L3.

> **Glossary**
> - **EL** — Event Loop (Netty I/O thread)
> - **FJ** — ForkJoinPool (virtual thread scheduler)
> - **IPC** — Instructions Per Cycle
> - **nvcswch** — non-voluntary context switches (thread yielded CPU involuntarily)

## 2. Configurations tested

| Config | Event Loop | Scheduler | I/O | Threads | Affinity | Poller |
|--------|-----------|-----------|-----|---------|----------|--------|
| **custom_8_nio** | VirtualMultithreadIoELG | NettyScheduler | NIO | 8 | structural | POLLER_PER_CARRIER |
| **affinity_8** | ManualIoELG | ForkJoinPool | NIO | 8 | roundRobin + inherit | VTHREAD_POLLERS |
| **no_affinity_8** | ManualIoELG | ForkJoinPool | NIO | 8 | none | VTHREAD_POLLERS |
| **fj_8_8** | MultiThreadIoELG | ForkJoinPool | NIO | 8+8 | none | VTHREAD_POLLERS |

All configs achieved the target rate (119,695-119,810 req/s, within 0.1%).

---

## 3. Latency

At 120K, latency does not differentiate the configs. All four are identical up to p90 (~30.5-32.8ms = mock delay + overhead). p90+ tail latency is not stable on this machine across runs.

---

## 4. CPU Usage and Per-Request Cost

From deep profiling (6 perf stat passes, ≤5 HW events each). See [FINDINGS.md](FINDINGS.md) for full methodology.

|  | custom_8_nio | no_affinity_8 | affinity_8 | fj_8_8 |
|--|-------------|--------------|-----------|-------|
| **CPUs utilized** | **5.94** | 6.95 | 6.95 | 6.82 |
| **IPC** | 0.997 | 0.981 | 0.970 | 1.015 |
| **instructions/req** | **215,386** | 225,781 | 225,894 | 231,115 |
| **DRAM misses/req** | **2,041** | 3,202 | 2,858 | 2,390 |

custom_8_nio uses 13-15% less CPU to serve the same 120K req/s. Two sources ([FINDINGS.md](FINDINGS.md)):
1. Fewer instructions/req — no FJ scheduling overhead
2. Fewer DRAM misses/req — perf mem (IBS) shows the DRAM increase in FJ configs is broad across every category (Netty pipeline, continuation, HTTP client, kernel networking)

fj_8_8 has the highest IPC (1.015) but executes the most instructions/req (+7.3% vs custom). See section 7 for fj_8_8-specific costs.

---

## 5. Context Switches

| Config | context switches (max) | context switches (120K) | nvcswch/s @ 120K | nvcswch spread @ 120K |
|--------|-------------|---------------|-----------------|---------------------|
| custom_8_nio | 1,151 | 333,017 | 291 | 1.14x |
| affinity_8 | 11,727 | 1,000,118 | 1,556 | 1.09x |
| no_affinity_8 | 164,813 | 1,033,285 | 1,299 | 1.15x |
| fj_8_8 | 144,578 | 1,071,409 | 1,631 (FJ workers) | 1.04x |

At 120K, all configs show dramatically more context switches as threads park between requests. custom_8_nio still has 3x fewer than others.

The non-voluntary context switch imbalance observed at max load (no_affinity: 8.6x spread) has vanished at 120K — all configs are balanced (1.04-1.15x). custom_8_nio still has 4-5x fewer non-voluntary context switches/s.

---

## 6. Affinity at 120K vs Max Load

**At 120K, affinity has no measurable effect.** affinity_8 vs no_affinity_8 metrics are within 2-3% — within run-to-run variance.

At 120K, carriers are not saturated (6.95 CPUs out of 8). affinity_8 and no_affinity_8 produce similar metrics at this load level (both 6.95 CPUs, DRAM misses/req within 12%). At max throughput, affinity_8 achieves 168K vs 159K for no_affinity_8. See [FINDINGS.md](FINDINGS.md) for affinity_8's 120K-vs-max comparison.

---

## 7. fj_8_8 at 120K

fj_8_8 (standard Netty, 8 EL + 8 FJ workers) has unique overhead at 120K:
- **+7.3% instructions/req** vs custom — EL→FJ handoff adds scheduling work
- **178K cpu-migrations** — 4-6x more than 8-thread configs (16 threads on 8 cores)
- **174 IBS DRAM samples** in LinkedBlockingQueue + unparkVirtualThread — the handoff queue cost, absent in other configs
- **Highest total IBS DRAM samples** (2,453, +54% vs custom) — increase is broad across all categories (see [FINDINGS.md](FINDINGS.md))

At max throughput, migrations drop 97% and DRAM misses drop 47%, but IPC drops 14% (16 threads on 8 cores), giving fj_8_8 the lowest max throughput among 8-EL configs (161K vs 168K affinity, 174K custom).

---

## 8. Key Takeaways

1. **custom_8_nio is the most efficient at every load level** — 13-15% less CPU, fewer instructions/req (no FJ overhead), fewer DRAM misses/req.

2. **Affinity has no measurable effect at sub-maximal load.** affinity_8 and no_affinity_8 produce similar metrics at 120K. At max throughput, affinity_8 achieves higher throughput (168K vs 159K).

3. **Non-voluntary context switch imbalance disappears at sub-maximal load.** The 8.6x spread seen at max load drops to 1.04-1.15x at 120K.

4. **fj_8_8 is the least efficient 8-EL FJ config** — most instructions/req, most migrations, unique handoff queue DRAM costs, lowest max throughput among 8-EL configs.
   Copilot said: Tak — i to **bardzo ważnie zmienia

Tak — i to bardzo ważnie zmienia framing całego researchu.

Bo jeśli wrócić do źródła, to temat nie zaczął się od io_uring, tylko od bardziej ogólnej tezy Francesco:
punkt wyjścia:

naive Loom + split pipeline między I/O threads i default ForkJoin scheduler zostawia performance na stole

czyli:

    dwa poole,
    dobrowolne context switche,
    handoff,
    locality loss,
    DRAM/cache penalties,
    capacity penalty na unbalanced workloads.

Dopiero potem w rozmowie zeszliście na:

    io_uring,
    native reapers,
    pollerMode=3,
    custom scheduler API,
    bounded drain,
    multishot.

To oznacza, że masz tak naprawdę dwie warstwy problemu:
1. Warstwa bazowa — scheduler split / handoff / locality

To jest temat ogólny:

    Loom default scheduler vs unified/affine scheduler
    I/O pool vs FJ pool
    continuation locality
    context switches
    DRAM/cache pollution
    queueing theory argument

To nie jest jeszcze specyficznie io_uring.
2. Warstwa Exeris-specific / Enterprise-specific

To jest:

    native carrier outside Loom
    CQ reaper only unparks
    no classic EL→FJ queue handoff
    ale nadal FJP locality loss
    plus enterprise concerns:
        io_uring
        multishot
        batching
        bounded drain
        H3/QUIC
        poller constraints

To jest Wasz szczególny przypadek.
Najważniejszy wniosek
Twój research nie powinien być opisany wyłącznie jako:

“io_uring scheduler experiment”

bo to za wcześnie zawęża problem.
Lepiej:

to jest najpierw:
Loom continuation locality / split-pipeline efficiency research

a dopiero potem jedna z gałęzi to:
enterprise io_uring transport implications

To jest dużo mocniejsze, bo:

    lepiej oddaje genezę,
    lepiej pasuje do materiałów Francesco,
    pozwala zacząć od benchmarków prostszych,
    a potem schodzić w enterprise-specific paths.

Co dokładnie Francesco pokazał?

Z tego, co wkleiłeś, jego główne twierdzenia są mniej więcej takie:
A. Split pipeline kosztuje strukturalnie

    EL + FJ = dwa poole
    więcej voluntary context switches
    wyższy scheduling overhead
    capacity penalty

B. Unified scheduler daje przewagę

    continuations on same EventLoop
    mniej handoffów
    mniej context switches
    lepsza IPC / CPU efficiency
    lepsze p90+
    cloud cost impact

C. Na lekkim/średnim obciążeniu problem jest mocno cache/DRAM/locality-related

To bardzo ważne. Z findings:

    wzrost DRAM misses/req
    broad increase across categories
    continuation thaw pointer chasing
    pipeline pointer chasing
    light load = working set wypada z cache hierarchy
    FJ configs mają dużo więcej context switches i więcej broad DRAM cost

To jest super istotne, bo dokładnie pokazuje, że:
problem nie jest tylko “więcej instrukcji schedulerowych”

ale też gorsza pamięciowa geometria wykonania.
Gdzie tu jest Exeris?

Ty odpowiedziałeś wtedy:

    “u mnie split pipeline nie wygląda jak w Netty”
    “carrier loops są native threads”
    “no FJ task submission handoff”
    “only unpark”
    “PAQS binds one VT per stream”
    “different entry point, same conclusion”

I to jest dokładnie punkt, który warto zbadać benchmarkami.
Czyli właściwe research question dla Exerisa brzmi:
Nie:

“czy io_uring + multishot jest lepszy?”
Tylko najpierw:
“If Exeris removes the explicit queue handoff but still resumes VTs on default FJP, how much of the split-pipeline cost remains?”

To jest chyba Twoje najważniejsze pytanie.

Bo Twój model:

    usuwa jedną część problemu Francesco,
    ale niekoniecznie usuwa locality/cache/FJP continuation cost.

I to daje bardzo dobry podział researchu
Track A — General Loom locality / scheduler split

To powinien być główny track startowy.
Cel:

zbadać:

    default FJP continuation resume
    versus transport-affine / unified scheduler
    przy zachowaniu podobnego workloadu

Warianty:

    split EL→FJ baseline (if you build comparable harness)
    Exeris-style native reaper + FJP resume
    affine/unified scheduler
    maybe VT event-loop variant

To daje bardzo silne porównanie.
Track B — Exeris native carrier variant analysis

Tu pytasz:

    skoro nie ma classic double queue handoff,
    to ile kosztu zostaje przez sam FJP resume / locality loss?

To jest bardzo ciekawe i unikalne.

Bo to nie jest już dokładnie case Netty, tylko:
“partial elimination of the split”
Track C — Enterprise io_uring implications

Dopiero tutaj wchodzą:

    multishot
    batching
    bounded drain
    H3
    pollerMode=3 relevance
    carrier-affine scheduling for native transport

To jest kolejna warstwa.
Czyli od czego powinieneś zacząć?
Moja odpowiedź:
od Track A + B, nie od pełnego multishot/H3 matrix.

Bo geneza i najmocniejsza teza są prostsze:

    czy continuation locality i unified scheduling dają mierzalny zysk, nawet gdy Exeris już usunął klasyczny queue handoff?

To jest bardzo mocne, a dużo prostsze do benchmarkowania niż od razu:

    io_uring multishot H3 drain policy matrix.

Co z findings Francesco jest dla Ciebie najbardziej load-bearing?

Ja bym wyciągnął 5 rzeczy.
1. Voluntary context switch count

To jest łatwe do mierzenia i mocne.
2. CPU utilization at fixed rate

Bardzo ważne. Nie tylko max throughput.
3. instructions/req

Pokazuje scheduler overhead.
4. DRAM misses / broad cache pollution

To jest super ważne, bo może pokazać, że problem jest deeper than queue handoff.
5. Light-load / sub-max behavior

To jest wręcz krytyczne. Bo findings pokazują, że przy 120K fixed load:

    custom scheduler był dużo bardziej efektywny
    affinity alone at submax didn’t matter much
    split/FJ effect nadal był wyraźny

To jest ważne, bo wiele benchmarków patrzy tylko na max throughput.
To zmienia benchmark plan
Zamiast zaczynać od:

    H3
    multishot
    complex enterprise matrix

Zacznij od:
fixed-rate efficiency benchmarks

dla wariantów execution model.
Najlepszy pierwszy benchmark matrix dla Exerisa

Ja bym zrobił tak:
Oś 1 — execution model

    exeris-native-reaper-fjp
    exeris-affine-scheduler-prototype
    ewentualnie exeris-vt-eventloop-prototype

Oś 2 — transport path

    Community NIO / selector baseline
    Enterprise native transport baseline later

Oś 3 — load level

    fixed submax load
    moderate/high load
    max throughput

Oś 4 — metrics

    throughput
    CPUs utilized
    instructions/req
    context switches
    DRAM misses/req
    p90/p99
    maybe migrations

To jest świetny start.
Gdzie wchodzi io_uring?
Po tym, jak pokażesz bazowy efekt.

Dopiero wtedy enterprise track robi się:

    “does the same effect amplify / change under io_uring multishot batching and H3?”

To jest dużo lepsza kolejność.
Jak bym nazwał research stream?

Skoro patrzymy od źródła problemu, a nie od najwęższego przypadku, to lepiej nazwać to szerzej.
Zamiast:

enterprise-io-uring-affinity-research
Dałbym:
loom-continuation-locality-research

albo
split-pipeline-efficiency-research

Ja bym wybrał:
loom-continuation-locality-research

Bo obejmuje:

    source problem,
    Exeris variant,
    później enterprise/io_uring branch.

A potem subtracks:
Text

research/
loom-continuation-locality/
baseline/
exeris-native-reaper/
enterprise-io-uring/

To jest bardzo ładna struktura.
Co jest najważniejsze dla argumentacji do Loom teamu?

Nie tylko:

    “io_uring is special”

Ale raczej:
“custom transports and split-but-not-quite-split continuation models still leave measurable performance on the table because default FJP continuation locality is not enough.”

To jest dużo szerszy i mocniejszy argument.
Finalny werdykt
Tak:

to, od czego się zaczęło, jest ważniejsze niż samo późniejsze zejście na io_uring.
Główna rama researchu powinna być:
Loom continuation locality / split-pipeline efficiency
A Exeris wnosi do tego unikalny case:

    brak klasycznego queue handoff,
    ale nadal FJP resume/locality loss,
    a dopiero potem enterprise adds:
        io_uring
        multishot
        batching
        H3
        bounded drain

Czyli praktycznie:
start:

    fixed-rate efficiency study
    baseline Exeris current model vs affine/unified continuation scheduling

potem:

    enterprise io_uring deep dive

Jeśli chcesz, mogę teraz zrobić jeden z bardzo konkretnych kroków:

    napisać research/loom-continuation-locality/README.md,
    rozpisać benchmark plan fazami: baseline → Exeris native reaper → enterprise io_uring,
    zaprojektować pierwszą benchmark matrix opartą dokładnie o te findings Francesco.

You said: czyli tak naprawde rozbijamy to na
czyli tak naprawde rozbijamy to na  branche 2 research/loom-continuation-locality/core+community
oraz enterprise osobno
rozpisz plan benchmarku i wdrożenia
Copilot said: Tak — **to jest bardzo dobry podział**. ##

Tak — to jest bardzo dobry podział.
Finalny framing

Rozbiłbym to na dwa równoległe, ale powiązane nurty:
1. research/loom-continuation-locality/core-community

Cel:

    zbadać problem continuation locality / default FJP resume na prostszym, publicznym, łatwiej kontrolowalnym stacku
    zbudować metodologię, harness i baseline
    pokazać efekt bez pełnej złożoności enterprise/native/H3

2. research/loom-continuation-locality/enterprise

Cel:

    rozszerzyć tę samą hipotezę na:
        native carriers
        io_uring
        batching
        multishot
        H3
        bounded drain
    sprawdzić, jak efekt wygląda w docelowym high-performance stacku Exerisa

To jest bardzo zdrowe, bo:

    community/core daje Ci czystszy, łatwiejszy do publikacji proof,
    enterprise daje Ci realnie najważniejszy wynik techniczny.

Proponowana struktura
Text

research/
loom-continuation-locality/
README.md
shared/
hypotheses.md
metrics.md
methodology.md
environment-profiles.md
reporting-rules.md
core-community/
README.md
benchmark-plan.md
implementation-plan.md
scenarios/
results/
enterprise/
README.md
benchmark-plan.md
implementation-plan.md
scenarios/
results/

Co dokładnie benchmarkujemy?

Najprościej:
Główna hipoteza wspólna

Default Loom/FJP continuation scheduling leaves measurable efficiency and locality costs compared to transport-affine / unified continuation execution.
TRACK 1 — core-community

To nie jest pełny odpowiednik case’u Francesco, ale:

    jest łatwiej wdrażalny,
    publiczny,
    da Ci metodologię,
    pozwoli ustabilizować benchmark harness,
    i może pokazać część efektu.

A. Cel tracku core-community
Odpowiedzieć na pytania:

    Czy obecny model Exerisa w Community ma mierzalny koszt continuation locality?
    Czy zmiana execution backendu VT daje poprawę:
        CPU efficiency,
        context switches,
        throughput,
        p95/p99,
        maybe cache-related counters?
    Na ile Community może być sensownym proxy metodologicznym dla dalszych badań enterprise?

B. Co porównujemy?
Warianty
Variant C1 — baseline

community-current

    obecny NativeTcpCarrier
    obecny PaqsScheduler
    Thread.ofVirtual().start(...)
    default Loom/FJP resume path

Variant C2 — refactored baseline

community-spawner-baseline

    ten sam behavior co C1
    ale już przez abstrahowany StreamExecutionSpawner
    służy do upewnienia się, że sama refaktoryzacja nic nie zmieniła

Variant C3 — experimental scheduler backend

community-affine-prototype

    PaqsScheduler używa alternatywnego backendu/spawnera
    celem jest zbliżenie się do unified/affine execution

Variant C4 — opcjonalnie później

community-vt-eventloop-prototype

    jeśli będziesz chciał sprawdzić event loop in VT / bounded-drain concept na prostszym stacku

C. Benchmark scenarios dla core-community
Minimal MVP

    h1-plaintext-fixed-rate
    h1-json-1kb-fixed-rate
    h2-plaintext-fixed-rate
    h2-json-1kb-fixed-rate

Drugi etap

    h2-multiplex-small
    h1-burst-32
    h2-burst-32
    h2-concurrent-128

D. Load profiles
Obowiązkowo:

    fixed submax load
        np. 60–75% max throughput
        najważniejszy profil
    moderate load
    max throughput

Dlaczego?

Bo z findings Francesco wynika, że:

    przy submax/light load efekt locality/DRAM jest bardzo widoczny,
    przy max throughput część rzeczy się zmienia.

E. Metryki
Obowiązkowe:

    throughput
    CPU utilized
    instructions/req
    context switches
    p50/p95/p99 latency
    error rate

Recommended:

    cache misses / DRAM misses if environment allows
    cpu migrations
    JFR scheduler events if available

F. Cel wdrożeniowy dla core-community

Nie “zrobić idealny scheduler”. Tylko:
zbudować benchmark harness i abstraction seam

Czyli outcome tego tracku to:

    benchmark harness działa,
    PaqsScheduler ma execution backend seam,
    baseline vs experimental comparison jest możliwy,
    masz pierwsze liczby.

TRACK 2 — enterprise

To jest główny, docelowy research.
A. Cel tracku enterprise
Odpowiedzieć na pytania:

    Ile z problemu continuation locality zostaje w Exeris native carrier model?
    Czy affine/unified scheduling poprawia:
        CPU efficiency,
        tail latency,
        batching fairness,
        locality/cache behavior?
    Jak wpływają na to:
        io_uring,
        multishot,
        batch receive,
        bounded drain,
        H3?

B. Co porównujemy?
Warianty schedulerowe
E1 — baseline

enterprise-native-reaper-fjp

    CQ reaper native thread
    completion → unpark
    VT resumes on default FJP

E2 — experimental affine scheduler

enterprise-native-reaper-affine

    native transport
    alternate scheduler-backed continuation execution

E3 — opcjonalnie później

enterprise-vt-eventloop-bounded-drain

    event loop / poll / drain path reworked around VT/event-loop model

C. Osie eksperymentu enterprise
Oś 1 — protocol

    H1
    H2
    H3

Oś 2 — ingress model

    single-shot
    multishot
    batch receive / recvmmsg-like path

Oś 3 — drain policy

    immediate handoff
    count-bounded drain
    time-bounded drain
    drain-until-empty

Oś 4 — scheduler backend

    FJP
    affine
    maybe VT event-loop later

D. Enterprise benchmark phases
Phase E1 — baseline locality

Najpierw bez pełnej eksplozji złożoności:

    H2 fixed-rate
    H3 fixed-rate
    baseline FJP vs affine
    without exploring every drain policy yet

Phase E2 — multishot/batching

Potem:

    multishot receive
    batch receive
    bounded drain variants

Phase E3 — transport fairness / HOL risk

Na końcu:

    mixed workloads
    multiplex
    H3 stream-heavy scenarios
    fairness/tail latency trade-offs

E. Enterprise benchmark scenarios
Minimal start

    enterprise-h2-plaintext-fixed-rate
    enterprise-h2-json-1kb-fixed-rate
    enterprise-h3-plaintext-fixed-rate
    enterprise-h3-json-1kb-fixed-rate

Potem

    enterprise-h2-multishot-json-1kb
    enterprise-h3-multishot-json-1kb
    enterprise-h3-multiplex-32
    enterprise-h3-burst-32
    enterprise-h3-drain-policy-matrix

Plan wdrożenia — kolejność prac

Teraz najważniejsza część.
FAZA 0 — repo benchmarkowe i research scaffold
Cel:

postawić strukturę i dokumenty.
Zadania

    utworzyć:
        research/loom-continuation-locality/
        shared/
        core-community/
        enterprise/
    dodać dokumenty:
        README.md
        hypotheses.md
        methodology.md
        metrics.md
        reporting-rules.md
    zdefiniować naming convention scenariuszy i wariantów
    zdefiniować result schema

Deliverable

    gotowy research scaffold
    brak jeszcze benchmark code

FAZA 1 — execution seam w kodzie
Cel:

umożliwić A/B porównania bez wielkiego rewrite’u.
Zadania

    wydzielić z PaqsScheduler abstraction:
        StreamExecutionSpawner
        albo StreamExecutionBackend
    dodać baseline implementation:
        DefaultVirtualThreadSpawner
    podłączyć to do PaqsScheduler
    w NativeTcpCarrier wstrzyknąć backend/spawner
    upewnić się, że baseline działa identycznie jak dziś

Optional:

    zrefaktorować client ingress VT pump pod tę samą abstrakcję

Deliverable

    benchmarkable seam
    zero functional regression

FAZA 2 — core-community baseline benchmarks
Cel:

ustabilizować methodology i harness na prostszym stacku.
Zadania

    benchmark runner dla:
        H1 plaintext
        H1 json-1kb
        H2 plaintext
        H2 json-1kb
    fixed-rate load profiles
    capture:
        throughput
        CPU
        context switches
        latency
    baseline runs dla:
        community-current
        community-spawner-baseline

Deliverable

    potwierdzenie, że seam nic nie zepsuł
    first reproducible baseline

FAZA 3 — core-community experimental backend
Cel:

pierwszy realny benchmark porównawczy.
Zadania

    zaimplementować community-affine-prototype
        minimal experimental scheduler backend
    uruchomić A/B:
        baseline vs affine
    zebrać:
        fixed-rate efficiency
        max throughput
        context switch deltas
        CPU/req deltas

Deliverable

    pierwszy evidence package
    odpowiedź, czy na prostym stacku w ogóle widać efekt

FAZA 4 — enterprise seam
Cel:

przenieść mechanizm na enterprise stack.
Zadania

    w enterprise carrierze wydzielić:
        continuation backend hook
        ewentualnie drain-policy hook
    baseline enterprise path:
        current native reaper + FJP
    experimental enterprise path:
        native reaper + affine backend

Deliverable

    enterprise gotowy do A/B

FAZA 5 — enterprise baseline locality study
Cel:

najważniejszy pierwszy wynik enterprise.
Zadania

    benchmarki:
        H2 plaintext fixed-rate
        H2 json-1kb fixed-rate
        H3 plaintext fixed-rate
        H3 json-1kb fixed-rate
    warianty:
        baseline FJP
        affine
    metryki:
        throughput
        CPU
        latency
        context switches
        migrations
        cache/DRAM if possible

Deliverable

    odpowiedź, czy Exeris enterprise naprawdę zostawia performance na stole przez default FJP locality

FAZA 6 — multishot / batching / bounded drain
Cel:

wejść w właściwy enterprise design space.
Zadania

    dodać zmienną:
        single-shot vs multishot
        batch receive
    dodać drain policy variants:
        drain-1
        drain-count-N
        drain-time-budget
        drain-until-empty
    benchmark matrix:
        H2/H3 × scheduler × drain policy × ingress mode

Deliverable

    dane do decyzji architektonicznej
    czy bounded drain i affine scheduler naprawdę się opłacają

FAZA 7 — perf-analysis deep dive
Cel:

zrobić z tego materiał research-grade.
Zadania

    perf stat
    perf mem / IBS if available
    JFR runs
    maybe c2c / migrations / perf sched
    report:
        CPU efficiency
        DRAM/cache behavior
        context switch and migration behavior
        tail latency / fairness

Deliverable

    materiał do external discussion / loom feedback

Rekomendowana kolejność priorytetów

Jeśli chcesz wiedzieć co najpierw, to dokładnie tak:
Priorytet 1

Faza 1 — execution seam Bez tego nic nie porównasz porządnie.
Priorytet 2

Faza 2 — community baseline harness Bo ustabilizuje Ci benchmark repo i methodology.
Priorytet 3

Faza 5 — enterprise baseline locality study Bo to jest właściwy cel biznesowo-architektoniczny.
Priorytet 4

Faza 6 — multishot / bounded drain Bo to jest już deeper optimization/design-space exploration.
Co jest deliverablem końcowym?

Powinieneś wyjść z tego z trzema rzeczami.
1. Benchmark framework

   reproducible
   A/B capable
   shared methodology
   community + enterprise split

2. Architectural seam in code

   scheduler backend abstraction
   experimental backend plug point

3. Research outputs

   benchmark reports
   latency/CPU/context-switch results
   enterprise drain policy findings
   optional loom-dev discussion note

Proponowany milestone plan
M0 — Research scaffold

docs + structure
M1 — PAQS execution seam

refactor without behavioral change
M2 — Community baseline benchmark pack

fixed-rate H1/H2
M3 — Community experimental comparison

baseline vs affine
M4 — Enterprise baseline comparison

FJP vs affine on H2/H3
M5 — Enterprise multishot/drain study

batching + fairness + tail latency
M6 — Research report

external/internal findings package
Najkrótsza wersja planu
Branch 1: core-community

    zbudować harness
    wydzielić scheduler seam
    zrobić baseline
    zrobić pierwsze A/B

Branch 2: enterprise

    zaadaptować seam do native carrierów
    porównać FJP vs affine dla H2/H3
    dopiero potem wejść w multishot / recvmmsg / drain policy

Mój finalny recommendation
Tak:

ten podział na:

    core-community
    enterprise

jest bardzo dobry.
Najważniejsze:

nie zaczynaj od multishot i H3 matrixu. Najpierw:

    seam,
    baseline,
    first A/B,
    dopiero potem batching/drain complexity.

