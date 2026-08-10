# XGC2 ROS1 Central Simulation

This app is the immutable ROS Noetic and Gazebo Classic runtime for the first
XGC2 centralized simulation mode. It runs the shared ROS master, Gazebo server,
VRPN bridge and all configured FS150, Scout Mini, and Mecanum UGV robots in one
disposable container. The matching current ROS1 semantic Adapters are baked in
for those three supported robot families.

Experiment orchestration and process ownership remain in XGC2 Core. The image
contains only the maintained, independently versioned simulator products; the
retired `gazebo-sim-manager`, `gazebo-sim-examples`, and umbrella packages are
not installed.

The image derives from the pinned amd64 manifest of `xgc-ros1-runtime:1.2.3`.
XGC2 products are installed
from `https://xgc2.apt.xiaokang.ink` only while the image is built. Container
startup never runs `apt update` or installs products.

Exact direct product versions live in `packages.lock`. Change the lock and bump
the app version whenever the simulation release set changes.

QGroundControl 4.4.4 is downloaded with a pinned SHA-256 and extracted while the
image is built. Runtime execution uses the extracted `AppRun` tree and never
requires FUSE inside the container. QGC configuration and cache data use a
dedicated persistent volume, while the simulation container remains disposable.

The Process Supervisor owns `/run/xgc/processes` and
`/var/log/xgc/processes`. Both are host-mounted by the catalog compose file so
Core can validate PID/PGID/start-ticks handles and resume stdout/stderr offsets
after either Core or the simulation container restarts.

Run QGroundControl after the container starts with:

```bash
qgroundcontrol
```

Set `HOST_XAUTHORITY` to the current desktop session's Xauthority file and set
`USER_UID`/`USER_GID` to the desktop user's IDs. The compose file mounts that
file read-only and QGC runs as the matching non-root user.

Set `QGC_FORCE_SOFTWARE_OPENGL=1` only when the host GPU/driver combination
cannot render QGC correctly through the container.

PX4 1.14, product source trees, Agent, Unitree B2, Mocap, and their catalogs are
intentionally excluded. This image is released and accepted for amd64 only.

## Local build

```bash
docker build -t xgc2-ros1-central-sim:local .
docker run --rm xgc2-ros1-central-sim:local \
  /usr/local/bin/xgc2-central-sim-healthcheck
docker run --rm xgc2-ros1-central-sim:local \
  /usr/local/bin/xgc2-central-sim-smoke
```

The repository build workflow pushes versioned and `latest` tags to GHCR. When
all domestic-registry secrets are configured, the same workflow also pushes
the same tags to the configured domestic registry.
