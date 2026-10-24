# Onboard baseline checks

The robot base contains third-party Ubuntu/ROS runtime dependencies and its
profile's account. Product installation is separate from the base image.

Run the nonprivileged checks from the image repository root:

```bash
python3 -m unittest discover -s onboard-baseline/tests -p test_base_boundary.py -v
python3 -m unittest discover -s onboard-baseline/tests -p test_baseline.py -v
python3 -m unittest discover -s onboard-baseline/tests -p test_local_image.py -v
bash -n onboard-baseline/onboard-baseline.sh
bash -n onboard-baseline/build-local-image.sh
git diff --check
```

Package, ROS and Docker command doubles run in disposable directories. The base
boundary suite exercises installed-product/physical-driver rejection, each
profile's package list and the shell-only Dockerfiles. Local image tests reject
product inputs and retain a stable `latest` tag. These tests do not establish
real ROS, image publication, source-built product runtime or physical-device readiness.

The downstream Agent entrypoint has separate real chroot/account-switching
checks. Run these as root inside a disposable Linux container or test runner:

```bash
python3 -m unittest discover -s onboard-baseline/tests -p test_image_entrypoint.py -v
```

`freeze-check.sh` runs the shell syntax, baseline and base-boundary suites.
Some baseline tests require working unprivileged namespaces and skip when unavailable.

Build and inspect an actual base without starting any robot task:

```bash
./onboard-baseline/build-local-image.sh fs150-focal-noetic linux/amd64
./onboard-baseline/tests/smoke-image.sh onboard-sim-fs150-focal-noetic:latest
```

The image smoke uses a private network, a read-only root and temporary caches.
It checks repeated base preparation, package state and ROS as the robot account.
Agent, adapters, XSim, controllers and algorithms are absent from this base; their
source-built artifacts are installed through an explicit Builder/Deployer workflow.
