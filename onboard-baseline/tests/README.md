# W06 baseline verification

Task: [xgc2-harness#171](https://github.com/XGC-Team/xgc2-harness/issues/171).
Source starting point: `70c4165f28eb73bbc93425fdda79f4b89f041ec5` in
`XGC-Team/xgc2-images`. Contract: `xgc2-dev-memory` commit
`a5f23ceaf716c2afddf0f792d6722ac0cd0f3d20`,
`now/experiment-deployment-{architecture,implementation,work-packages}.md`.

These tests are explicit maintenance/review operations, not Power, Run,
entrypoint or healthcheck hooks. They never contact a robot or the production
station. `image-entrypoint.sh` is unchanged.

## Profile and user-space boundary

| Profile | Ubuntu / ROS | Existing image operator |
| --- | --- | --- |
| fs150-focal-noetic | 20.04 / Noetic | marvsmart |
| scout-bionic-melodic | 18.04 / Melodic (Xavier) | agilex |
| scout-focal-noetic | 20.04 / Noetic (Orin NX) | nvidia |
| wheeltec-bionic-melodic | 18.04 / Melodic (Nano) | wheeltec |

This mapping was checked against the fixed design and the committed Dockerfiles,
not a newly collected field snapshot. Root must confirm each real asset's OS,
ROS, architecture and existing account. Profiles accept amd64 (local simulation)
and arm64; this is not proof of an arm64 build. Select the profile from the asset,
not from a menu of all robot models or an inferred CPU type.

The package lists stay in `baselines.json`; no second dependency list is added.
The default parent changes from ROS `ros-base` to `ros-core`, avoiding the
upstream ros-base image's extra build-essential/rosdep bootstrap layer. The shared
`apply` still installs the profile's `ros-*-ros-base` runtime metapackage.
ROS's own transitive dependencies are not purged. The metadata reader can use the
existing Melodic Python 2 before `apply` installs the listed Python 3 package.
Bash, an existing Python interpreter and dpkg are prerequisites; this is not a
bare-OS bootstrapper. No apt runs before a valid profile/OS/architecture is known.

`check` loads the selected installed ROS under a clean, temporary HOME. It checks
Debian package status, ROS package resolution, Python imports and, for FS150,
MAVROS executable/shared-library availability, launch-file resolution and a real
GeoidEval read. It starts no nodes and uses no ROS master. Only disposable caches
under the temporary directory are written. It does not certify kernel, GPU,
USB/serial, CAN, radio, vendor drivers, firmware or control behavior.

## Offline regression (Python 3.8+ and Bash)

Run from the repository root:

```bash
python3 -m unittest discover -s onboard-baseline/tests -p 'test_*.py' -v
bash onboard-baseline/freeze-check.sh
bash -n onboard-baseline/onboard-baseline.sh
bash -n onboard-baseline/tests/smoke-image.sh
git diff --check
```

These process/fixture tests exercise the real shell script in a disposable tree,
with explicit package/service/ROS command doubles. They cover rejection before
installation, clean-shell loading, interpreter selection, corrupt/missing runtime
dependencies, repeated apply, local-DEB Agent installation, existing identities,
snapshot/manualdiff and the unchanged entrypoint's installed-Agent restart path.
They are not ROS functionality or actual Python 2 execution evidence. The existing
freeze-check also requires user/mount namespaces and its existing empty bind-mount
targets; run it on a disposable review host, not a production robot. Its original
assertions remain unchanged; only the OS/ROS command fixtures are updated.

## Local image build and functional replay (Docker required)

On a local review machine with Docker, build each required profile once per
actual target platform. No registry push, remote CI dispatch or G runner is
needed. Example for the local amd64 FS150 image:

```bash
profile=fs150-focal-noetic
platform=linux/amd64
image=local/w06-${profile}:review
docker build --platform "$platform" \
  -f "apps/onboard-sim-${profile}/Dockerfile" -t "$image" .
bash onboard-baseline/tests/smoke-image.sh "$image"
```

Repeat with the other three profiles. For arm64 use a matching local builder
and `platform=linux/arm64`; report whether execution was native or emulated.
The existing build helper remains owned separately; this is a test invocation,
not another product build entrypoint. **W08/Root integration:** the existing helper
currently passes explicit `ros:*-ros-base-*` parents and overrides Dockerfile
defaults. Migrate its four parent values to the matching `ros:*-ros-core-*` parents
(or consume the Dockerfile defaults) within W08's write scope. Until then, that
helper still inherits the upstream builder layer; the command above does not.
The build's `check` runs as the existing
robot operator, whereas package installation runs as root.

The smoke script only consumes an already local image (`--pull=never`). It prints
image ID/platform/profile/user and uses disposable containers with no network
except private loopback, a read-only root, temporary `/tmp`, no added devices,
no capabilities and no-new-privileges. It verifies:

1. Two real `apply` calls cause no apt/download and leave the real package/config
   snapshot identical; unexpected installers are trapped as failures.
2. The ordinary operator passes the same `check` and a real ROS pub/sub round-trip.
3. FS150 additionally runs installed MAVROS, feeds an unarmed synthetic MAVLink
   heartbeat over private loopback and requires the decoded ROS State
   (`connected=true`, `armed=false`, `system_status=3`). This is a decoder/runtime
   check, not a real FCU, PX4 SITL, flight, ground-vehicle driver or motion test.

Missing Docker/daemon returns **77 (NOT RUN)**, not success. A nonzero build,
check, package/config comparison, ROS round-trip or MAVROS result is a failed
acceptance item, not an invitation to weaken an assertion or change algorithms.
The offline restart test is not W07's actual Agent registration acceptance.

## Root field replay and integration handoff

Transfer the reviewed baseline script and JSON by the existing maintenance
channel. Run the following **as the asset's existing robot account**, with the
profile already confirmed from that asset. Do not create an `xgc2` account.

```bash
id -un
cat /etc/os-release
dpkg --print-architecture
bash ./onboard-baseline.sh check --profile "$profile"
```

Capture output/exit status and compare the profile runtime checks with the
matching image. Full package versions may differ; `check` does not claim a
byte-for-byte clone of the robot filesystem. `snapshot`/`manualdiff` remain
explicit export tools; snapshot contents may include deployment addresses and
should be reviewed before publishing logs.

Only if Root separately authorizes an installation window, use the same `apply`
as root and include the existing `scripts/build/install-ros-apt-source.sh` beside
the script (or in its normal repository location). Re-run `check` as the ordinary
user afterwards. Never put apply into Power/Run or infer hardware success from
this script. Do not run the container smoke script against a host network/device.

W07 continues to consume `install-agent` and owns real Agent startup/registration;
W08 owns the build helper; W11 consumes snapshot/manualdiff. The product repo's
duplicate `robot-container/fs150/Dockerfile` and dependency copies must be removed
by Root/the owning consumer after migration. They are outside this PR's write
scope; this PR does not claim that migration or final issue closure is complete.

## Evidence at submission

The worker's isolated Debian x86_64 environment ran 31 offline tests successfully,
and the existing namespace-based `freeze-check.sh` (exit 0), plus shell syntax
and whitespace checks. The freeze-check intentionally exercises the missing-Agent
error before printing `freeze-check: passed`. An actual smoke invocation returned 77
because Docker was unavailable. No image build, actual ROS/MAVROS run, native or
emulated arm64 run, current field snapshot, vendor-driver check or robot motion
was performed. Root's Docker and field results remain required before acceptance.
