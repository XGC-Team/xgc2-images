# W06 shared onboard baseline acceptance

Task: XGC-Team/xgc2-harness#171. PR target: `xgc2-images/master`.
Source start: `70c4165f28eb73bbc93425fdda79f4b89f041ec5`.
Design: `xgc2-dev-memory@a5f23ceaf716c2afddf0f792d6722ac0cd0f3d20`,
`now/experiment-deployment-{architecture,implementation,interaction,work-packages}.md`.

This is **not a hardware-acceptance or release claim**. Root independently
reviews, integrates, performs field checks, and closes the engineering issue.

## Scope and target identity

The fixed design and the corresponding field `onboard-truth.md` records were
read without contacting a robot. Keep the existing mapping; an asset selects
one profile, not an arbitrary menu of other robot families:

| Profile | Actual board user space | Existing operator |
| --- | --- | --- |
| `fs150-focal-noetic` | RK3566, Ubuntu 20.04 / Noetic, arm64 | `marvsmart` |
| `scout-bionic-melodic` | Xavier, Ubuntu 18.04 / Melodic, arm64 | `agilex` |
| `scout-focal-noetic` | Orin NX, Ubuntu 20.04 / Noetic, arm64 | `nvidia` |
| `wheeltec-bionic-melodic` | Nano, Ubuntu 18.04 / Melodic, arm64 | `wheeltec` |

amd64 is the local-image target; arm64 is the corresponding onboard user space.
This does not assert kernel, JetPack, hardware-driver or actuator equivalence.
Actual user accounts on physical targets are preserved, never created by apply.

Only the baseline script/table, four base Dockerfiles and these tests change.
`image-entrypoint.sh`, the build-local-image script, SITL layer, hardware drivers,
algorithms, product manifests and shared publishing files do not change. The
SITL/Agent installation body (from the optional-simulator comment to EOF) stays
byte-identical to the source start. Its shared argument/JSON parsing is hardened.

## What changes

Profile parsing now propagates the Python producer's failure before `eval`,
rejects incomplete options/empty package lists, and checks Ubuntu identity,
version and the supported Debian architecture. An installed held package is
accepted; failed/partial dpkg status is not. Melodic's Python-2-only starting
image can use its interpreter **only for the JSON bootstrap of explicit apply**;
Python 3 remains an installed baseline dependency and the other modes' prerequisite.

`check` loads the selected ROS setup without shell overlays, uses temporary
ROS cache storage, resolves ROS packages, imports the matching ROS Python
runtime, and checks rosout's ELF dependencies and executable bit. FS150 also
checks MAVROS core/extras libraries, the executable, and loads egm96-5 through
GeoidEval. It starts no ROS master, node, Agent, driver or actuator. Temporary
cache files are removed; persistent user/system configuration is not changed.

`apply` still installs only missing packages and never removes/upgrades the
whole environment. It now runs the same check before reporting success.
Each base Dockerfile also runs that check as its existing ordinary robot user.
These checks run during explicit maintenance/build, **not normal Power**.

The single package table gains `util-linux` for runuser and, for FS150,
`ros-noetic-mavros-extras`, `wget`, and `bzip2`. Extras supplies the existing
mocap/vision/odometry plugin library; GeographicLib's geoid installer downloads
with wget and extracts tar.bz2. No compiler toolchain or SITL package is added.

## Offline regression (safe; no Docker, sudo or network)

Use a host with Bash and Python 3.8 or newer:

```sh
python3 -m unittest discover -s onboard-baseline/tests -v
bash -n onboard-baseline/onboard-baseline.sh
bash -n onboard-baseline/tests/smoke-image.sh
git diff --check
```

The tests run the real Bash control flow in a temporary copy. Only literal
OS/ROS paths and the clean PATH are remapped; dpkg/apt/ROS/GeoidEval are explicit
fakes. The architecture cases exercise selection, not ARM execution. The
Python 2 shim exercises bootstrap routing, not a real Python 2 interpreter.
No fake is included in a product image or exposed through a product API.

Observed in the worker's isolated Debian amd64 environment on 2026-09-27:

| Check | Observed result |
| --- | --- |
| Final offline suite | 26 test methods, OK; includes all four profiles and both architecture selections |
| Bash syntax | Baseline, smoke runner and all four Docker RUN heredocs passed |
| Python AST / JSON parsing | Passed |
| Whitespace/diff check | Passed |
| Untouched SITL/Agent installation body | Byte-equal to the source start |
| Regression sensitivity, first 25-method suite against original script | Exit 1, 22 failure records (includes subtests) |
| Real image smoke invocation | Exit 77: Docker unavailable, **NOT RUN** |

To reproduce sensitivity with the current suite (failure count can differ
because a further setup/executable test was added):

```sh
git show 70c4165f28eb73bbc93425fdda79f4b89f041ec5:onboard-baseline/onboard-baseline.sh > /tmp/w06-original.sh
BASELINE_UNDER_TEST=/tmp/w06-original.sh python3 -m unittest discover -s onboard-baseline/tests -v
```

## Real image replay (Root, isolated local Docker only)

Build from the repository root with a local tag; do not publish. Repeat for each
of the four profiles and both platforms on suitable native/emulated builders.
No new image builder or workflow is introduced by this acceptance command:

```sh
set -o pipefail
profile=fs150-focal-noetic
platform=linux/amd64
image=xgc2-w06:fs150-focal-noetic-amd64
mkdir -p /tmp/w06-evidence
docker build --platform "$platform" \
  -f "apps/onboard-sim-$profile/Dockerfile" -t "$image" . \
  2>&1 | tee /tmp/w06-evidence/build.log
bash onboard-baseline/tests/smoke-image.sh "$profile" "$image" "$platform" \
  2>&1 | tee /tmp/w06-evidence/smoke.log
```

The smoke runner requires an already-built local image of the requested
architecture. It creates a disposable container with **no external network,
ports, host mounts or hardware devices**. It checks repeated apply with apt and
geoid-download tripwires, package/configuration preservation, ordinary-user
check, and a real ROS publish/subscribe roundtrip. On FS150 it launches MAVROS
with loopback-only UDP, observes service registration and receives disconnected
State output. It never requests a mode change or motion. These observations
prove local messaging/initialization only, not FCU connectivity or task success.
Exit 77 is missing test infrastructure, not a pass. Nonzero build/smoke output
must be investigated, not replaced by the offline suite.

## Field check and integration still required

Root runs only the shared read-only check as the actual logged-in robot user,
with the asset's matching profile, after explicitly approved installation:

```sh
bash /opt/xgc2/onboard-baseline/onboard-baseline.sh check --profile fs150-focal-noetic
```

Use the corresponding profile for other boards. Do not change their account,
ROS overlay, UART/CAN setup, startup services, network or experimental settings
merely to make a test green. A failed check reports an installation gap; it does
not automatically apply, install Agent, or start a driver.

Pending evidence: clean amd64/arm64 image builds, actual Python 2 bootstrap,
real ROS/MAVROS/GeoidEval loads, image/physical-user-space check parity, driver
and FCU functionality, and W07 normal container restart with the real Agent
(no apt). This worker has no Docker/Podman, ROS, Python 2, ARM execution or robot
access and did not run those checks or produce a tested image. Hardware motion
and the formal station are exclusively Root's acceptance responsibility.

W07/W08/W11 consume the unchanged mode interfaces and this same package table.
No product duplicate was deleted across ownership boundaries: after consumers
migrate, Root removes the old product `robot-container/fs150/Dockerfile` and any
copied dependency table. No parallel version/lock/deployment framework is added.
