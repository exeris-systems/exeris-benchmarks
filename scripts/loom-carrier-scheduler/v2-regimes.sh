# v2-regimes.sh — the two regimes of the scheduler-v2 runs, sourced by run-v2-equivalence.sh,
# run-v2-pilot.sh and run-v2-sequence.sh so that all three drive the same configuration.
#
# The regime configuration is a parameter, not a constant: the values below are the capacity
# ladders' (Regimes in the scenario README); the pilot decides whether the campaign changes them,
# and the campaign is then started with the registered values in the environment. A variable set in
# the environment (even to the empty string) replaces its default here.
#
#   CPU_LOAD_ARGS   run-trial.sh options of the CPU-bound regime (default: none, i.e. 1 ms backend,
#                   100 connections, pool 128)
#   IO_LOAD_ARGS    run-trial.sh options of the I/O-bound regime
#   BASE_CPU, BASE_IO   A_iso's saturation in each regime, the base of the pilot's rates
#   EQUIV_RATE_CPU, EQUIV_RATE_IO   the rate at which D from two kernel builds is compared

# Options every trial of the track passes.
COMMON_TRIAL_ARGS=(--poller-mode 3 --warmup-mode open --warmup 30)

CPU_LOAD_ARGS="${CPU_LOAD_ARGS-}"
IO_LOAD_ARGS="${IO_LOAD_ARGS---think-ms 30 --connections 5000 --pool 2048 --max-connections 16384 --duration 60}"

# A_iso's median saturation in the capacity ladders, which the 85 % rates below come from.
BASE_CPU="${BASE_CPU:-74531}"
BASE_IO="${BASE_IO:-62063}"
EQUIV_RATE_CPU="${EQUIV_RATE_CPU:-63400}"
EQUIV_RATE_IO="${EQUIV_RATE_IO:-52800}"
SLO_CPU_MS="${SLO_CPU_MS:-5}"
SLO_IO_MS="${SLO_IO_MS:-80}"

# regime_load_args <cpu|io>: the regime's options as words, one per array element, in REGIME_ARGS.
regime_load_args() {
  case "$1" in
    cpu) read -r -a REGIME_ARGS <<<"$CPU_LOAD_ARGS" ;;
    io)  read -r -a REGIME_ARGS <<<"$IO_LOAD_ARGS" ;;
    *) echo "regime must be cpu or io, was '$1'" >&2; return 2 ;;
  esac
}
regime_value() {  # <cpu|io> <CPU-name> <IO-name>: the variable that belongs to the regime
  local name; [[ "$1" == "cpu" ]] && name="$2" || name="$3"
  echo "${!name}"
}
