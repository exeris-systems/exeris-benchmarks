#!/usr/bin/env bash
# Build and stage the app artifacts for the kernel-version axis
# (0.10.2 vs 0.11.0 vs preview/0.11.0 vs preview/0.11.1).
#
# WHY SIX JARS FOR ONE APP
# The three kernel coordinates are not interchangeable at runtime. Class-file major version plus
# the preview bit pin each one to a JDK:
#
#   eu.exeris:0.10.2          major 70,  9/285 preview classes  -> JDK 26 only, +preview
#   eu.exeris:0.11.0          major 69,  0     preview classes  -> JDK 25/26/27/28, no flag
#   eu.exeris.preview:0.11.0  major 72, 95/306 preview classes  -> JDK 28 EA only, +preview
#   eu.exeris.preview:0.11.1  major 72, preview classes         -> JDK 28 EA only, +preview
#
# There is no mainline 0.11.1. The preview line advanced alone, for a change the distributed line
# does not carry, so 0.11.1 can only ever appear on the preview side of a leg.
#
# Only mainline 0.11.0 moves across JDKs, so it is the bridge that separates "new kernel" from
# "new JDK" from "Valhalla + StructuredTaskScope". To keep every leg of the ladder single-variable,
# the app's OWN bytecode has to be held constant across each comparison - and one jar cannot serve
# every arm, because the app's class-file version follows --release. A jar built at release 28 does
# not load on JDK 25.
#
#   staged jar                              serves arms   holds constant for
#   exeris-community-app-k0.10.2-r26p.jar   A             A vs B: app bytecode + JDK + flag
#   exeris-community-app-k0.11.0-r26p.jar   B                     (only the kernel version moves)
#   exeris-community-app-k0.11.0-r25.jar    C, C', D, D'  C'/C/D: JDK moves, nothing else
#                                                         D vs D': only the JVM flag moves
#   exeris-community-app-k0.11.0-r28p.jar   D''           D'' vs E: app build + JDK + flag held
#   exeris-community-app-kpv0.11.0-r28p.jar E                      (only the kernel coordinate moves)
#   exeris-community-app-kpv0.11.1-r28p.jar F             E vs F: coordinate, JDK, flag and app
#                                                                 build all held; the 159 JEP 401
#                                                                 value carriers are the variable
#
# The staged jar is verified after each build: class-file version and preview bit of the app's own
# classes AND of the shaded kernel classes must match what the arm claims. A build that silently
# produced the wrong target would otherwise give the campaign several numbers for one binary, pass
# every gate, and report a version effect that does not exist.
#
# Usage: scripts/build-kernel-version-axis-jars.sh [arm-id ...]      (default: all)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

POM="targets/exeris-community-app/pom.xml"
STAGING="targets/_staging"
BUILT_JAR="targets/exeris-community-app/target/exeris-community-app-1.0.0-SNAPSHOT.jar"
GPR_SETTINGS="${GPR_SETTINGS:-.github/maven-settings-gpr.xml}"

# JDK homes. Override any of these to point at a different build of the same feature release.
JDK25_HOME="${JDK25_HOME:-$HOME/.sdkman/candidates/java/25.0.3-tem}"
JDK26_HOME="${JDK26_HOME:-$HOME/.sdkman/candidates/java/26-oracle}"
JDK28_HOME="${JDK28_HOME:-$HOME/Pobrane/openjdk-28-ea+10_linux-x64_bin/jdk-28}"

# javac marks a class file as preview (minor 0xffff) per-class, not per-compilation, so the preview
# bit does not follow the build line in any simple way. Each variant therefore declares the runtime
# contract its staged jar must satisfy, and the verifier derives that contract from the emitted
# bytecode rather than trusting what the build was asked for.
#
# Measured, not assumed: at release 26 the app emits 40 plain class files, but at release 28 with
# the preview flag 30 of those 40 come out preview-marked from the SAME source. JEP 401 changes how
# the class-file format is interpreted (ACC_IDENTITY), so javac marks the classes affected by it
# even though no preview language feature appears anywhere in the app. That marking is the reason
# arm D'' exists: it isolates the cost of preview-marked app bytecode from the cost of the preview
# kernel, which arm E adds on top.
#
# variant : jdk_home_var : release : enablePreview : kernel_groupId : kernel_version
#         : expected_app_major : app_preview ("none" | "some") : min_jdk
#         : preview_pinned_jdk ("-" = jar carries no preview classes)
VARIANTS=(
  "k0.10.2-r26p:JDK26_HOME:26:true:eu.exeris:0.10.2:70:none:26:26"
  "k0.11.0-r26p:JDK26_HOME:26:true:eu.exeris:0.11.0:70:none:26:-"
  "k0.11.0-r25:JDK25_HOME:25:false:eu.exeris:0.11.0:69:none:25:-"
  "k0.11.0-r28p:JDK28_HOME:28:true:eu.exeris:0.11.0:72:some:28:28"
  "kpv0.11.0-r28p:JDK28_HOME:28:true:eu.exeris.preview:0.11.0:72:some:28:28"
  "kpv0.11.1-r28p:JDK28_HOME:28:true:eu.exeris.preview:0.11.1:72:some:28:28"
)

log() { echo "[build-axis] $*"; }
die() { echo "[build-axis] ERROR: $*" >&2; exit 1; }

verify_staged_jar() {
  local jar="$1" expected_app_major="$2" app_preview="$3" min_jdk="$4" preview_pinned_jdk="$5" kernel_group="$6" kernel_version="$7"

  python3 - "$jar" "$expected_app_major" "$app_preview" "$min_jdk" "$preview_pinned_jdk" "$kernel_group" "$kernel_version" <<'PY'
import sys, zipfile, struct, collections

jar, want_app_major, want_app_preview, want_min_jdk, want_preview_jdk, kernel_group, kernel_version = sys.argv[1:8]
want_app_major = int(want_app_major)
want_min_jdk = int(want_min_jdk)
want_preview_jdk = None if want_preview_jdk == "-" else int(want_preview_jdk)

z = zipfile.ZipFile(jar)
# App classes carry the --release the build was asked for. The shaded kernel classes carry whatever
# the dependency shipped - and it is those, not the app build, that pin the arm to a JDK.
app, kernel = collections.Counter(), collections.Counter()
for info in z.infolist():
    if not info.filename.endswith(".class"):
        continue
    head = z.read(info.filename)[:8]
    if len(head) < 8:
        continue
    minor, major = struct.unpack(">HH", head[4:8])
    bucket = app if info.filename.startswith("eu/exeris/benchmarks/") else kernel
    bucket[(major, minor == 0xFFFF)] += 1

everything = app + kernel
problems = []
if not app:
    problems.append("no application classes found in jar")

for (major, preview), count in app.items():
    if major != want_app_major:
        problems.append(f"app classes at major {major}, expected {want_app_major} ({count} classes)")
    if preview and want_app_preview == "none":
        problems.append(f"app classes are preview-marked ({count}) but variant declares none")
if want_app_preview == "some" and not any(preview for _, preview in app):
    problems.append("variant declares preview-marked app classes but none were emitted")

# Derive the runtime contract from the bytecode, then assert it is the one the variant declares.
# A plain class file loads on any JVM at or above its major; a preview-marked one loads ONLY on a
# JVM whose major matches exactly, and only with the preview flag.
actual_min_jdk = max(major for major, _ in everything) - 44
preview_majors = {major for (major, preview) in everything if preview}
if len(preview_majors) > 1:
    problems.append(f"preview classes span several majors {sorted(preview_majors)}; no single JDK can load this jar")
actual_preview_jdk = (preview_majors.pop() - 44) if preview_majors else None

if actual_min_jdk != want_min_jdk:
    problems.append(f"jar needs JDK >= {actual_min_jdk}, variant declares {want_min_jdk}")
if actual_preview_jdk != want_preview_jdk:
    problems.append(
        f"jar preview pin is {actual_preview_jdk or 'none'}, variant declares {want_preview_jdk or 'none'}"
    )
if actual_preview_jdk is not None and actual_preview_jdk != actual_min_jdk:
    problems.append(f"preview classes pin JDK {actual_preview_jdk} but jar needs JDK >= {actual_min_jdk}")

def fmt(counter):
    return ", ".join(f"major {m}{' preview' if p else ''} x{c}" for (m, p), c in sorted(counter.items()))

print(f"    app classes    : {fmt(app)}")
print(f"    kernel classes : {fmt(kernel)}")
print(f"    kernel pinned  : {kernel_group}:{kernel_version}")
if actual_preview_jdk is not None:
    print(f"    runtime contract: JDK {actual_preview_jdk} EXACTLY, preview flag REQUIRED")
else:
    print(f"    runtime contract: JDK >= {actual_min_jdk}, preview flag not required")
if problems:
    for p in problems:
        print(f"    FAIL: {p}")
    sys.exit(1)
print("    VERIFIED")
PY
}

build_variant() {
  local spec="$1"
  IFS=':' read -r name jdk_var release preview group version exp_app_major app_preview min_jdk preview_pinned_jdk <<< "$spec"

  local jdk_home="${!jdk_var}"
  [[ -x "$jdk_home/bin/javac" ]] || die "no javac at $jdk_home (set $jdk_var); required by variant $name"

  local staged="${STAGING}/exeris-community-app-${name}.jar"

  log "building ${name}: release ${release}, preview=${preview}, ${group}:${version}"
  log "  javac: $("$jdk_home/bin/javac" -version 2>&1)"

  # eu.exeris* lives on GitHub Packages. Resolving without these credentials silently falls
  # back to Central and only succeeds for versions already cached in ~/.m2.
  local -a mvn_settings=()
  if [[ -f "$GPR_SETTINGS" ]]; then
    mvn_settings=(-s "$GPR_SETTINGS")
    # Only demand the env vars when the settings file actually interpolates them. The
    # perf-box copy carries literal credentials instead, and failing it for an unset
    # GITHUB_TOKEN would block a build that needs no such variable.
    if grep -q "env.GITHUB_TOKEN" "$GPR_SETTINGS"; then
      [[ -n "${GITHUB_TOKEN:-}" ]] || die "$GPR_SETTINGS interpolates \${env.GITHUB_TOKEN} but it is unset; eu.exeris* resolves from GitHub Packages, not Central"
      : "${GITHUB_ACTOR:?GITHUB_ACTOR is unset (GitHub Packages needs a username alongside the token)}"
    fi
  fi

  JAVA_HOME="$jdk_home" mvn -q "${mvn_settings[@]}" -f "$POM" clean package -DskipTests \
    -Dmaven.compiler.release="$release" \
    -Dexeris.compiler.enablePreview="$preview" \
    -Dexeris.kernel.groupId="$group" \
    -Dexeris.kernel.version="$version" \
    || die "maven build failed for variant $name"

  [[ -f "$BUILT_JAR" ]] || die "expected artifact missing after build: $BUILT_JAR"

  mkdir -p "$STAGING"
  cp -f "$BUILT_JAR" "$staged" || die "could not stage $name to $staged"

  if ! verify_staged_jar "$staged" "$exp_app_major" "$app_preview" "$min_jdk" "$preview_pinned_jdk" "$group" "$version"; then
    rm -f "$staged"
    die "staged artifact for $name failed class-file verification; jar removed so no campaign can pick it up"
  fi
  log "  staged -> ${staged}"
  echo ""
}

selected=("$@")
built=0
for spec in "${VARIANTS[@]}"; do
  name="${spec%%:*}"
  if [[ ${#selected[@]} -gt 0 ]]; then
    match=0
    for s in "${selected[@]}"; do [[ "$s" == "$name" ]] && match=1; done
    [[ $match -eq 1 ]] || continue
  fi
  build_variant "$spec"
  built=$((built + 1))
done

[[ $built -gt 0 ]] || die "no variants matched: ${selected[*]:-<none>}"
log "staged ${built} variant(s) under ${STAGING}/"
