# XGC2 Images

Container images for XGC2 simulation, deployment, development, and CI builds.

GitHub hosts the catalog; GitHub Container Registry hosts the images.

## Apps

App categories:

- `simulation`: SITL, Gazebo, QGroundControl and simulator support images.
- `deployment`: multi-architecture images intended for robot or field hosts.
- `development`: source development and debugging workstations.
- `build`: layered CI compile images. Product CI should `FROM` these and compile
  only. They never install XGC2 APT packages (`xgc2-*`, `libxgc2-*`,
  `ros-*-xgc2-*`); those are build products, not image dependencies.

| App | Type | Image | Purpose |
| --- | --- | --- | --- |
| `xgc-ros1-runtime` | `simulation` | `ghcr.io/xgc-team/xgc2-images/xgc-ros1-runtime` | Curated multi-architecture ROS Noetic simulation toolkit for ROS1, MAVROS, VRPN, Gazebo Classic and core robot visualization. |
| `xgc2-ros1-central-sim` | `simulation` | `ghcr.io/xgc-team/xgc2-images/xgc2-ros1-central-sim` | Version-locked zero-Agent amd64 ROS1 simulation runtime with three robot simulators, semantic Adapters, ROS1 Tools, ROS Image RTP, Media Edge, shared worlds, VRPN and QGroundControl 4.4.4 preinstalled. |
| `xgc1-focal-noetic-qt-builder` | `development` | `ghcr.io/xgc-team/xgc2-images/xgc1-focal-noetic-qt-builder` | Multi-architecture XGC1 packaging image with ROS Noetic dependencies and source-built Qt 5.15.2. |
| `px4-sitl-gazebo` | `simulation` | `ghcr.io/xgc-team/xgc2-images/px4-sitl-gazebo` | PX4 software-in-the-loop simulation toolkit for Gazebo Classic and ROS Noetic. |
| `gazebo-harmonic-ros2` | `simulation` | `ghcr.io/xgc-team/xgc2-images/gazebo-harmonic-ros2` | Gazebo Harmonic with ROS 2 Jazzy integration. |
| `px4-ros2-sitl-qgc` | `simulation` | `ghcr.io/xgc-team/xgc2-images/px4-ros2-sitl-qgc` | PX4 ROS 2 SITL image with Micro XRCE-DDS Agent and QGroundControl AppImage included. |
| `ros-noetic-robot-focal` | `deployment` | `ghcr.io/xgc-team/xgc2-images/ros-noetic-robot-focal` | Official ROS Noetic robot-focal image mirrored for amd64, arm/v7 and arm64 deployments. |
| `ros-noetic-desktop-full` | `development` | `ghcr.io/xgc-team/xgc2-images/ros-noetic-desktop-full` | Official OSRF ROS Noetic desktop-full image mirrored for amd64 development use. |
| `ros2-jazzy-dev-base` | `development` | `ghcr.io/xgc-team/xgc2-images/ros2-jazzy-dev-base` | ROS 2 Jazzy desktop base with ground-station development tools. |
| `xgc2-dev-workstation` | `development` | `ghcr.io/xgc-team/xgc2-images/xgc2-dev-workstation` | ROS 2 Jazzy workstation with Qt development packages and Docker CLI. |
| `ros-jazzy-desktop-full` | `development` | `ghcr.io/xgc-team/xgc2-images/ros-jazzy-desktop-full` | Official OSRF ROS 2 Jazzy desktop-full image mirrored for amd64 development use. |
| `ros-jazzy-ros-base-noble` | `deployment` | `ghcr.io/xgc-team/xgc2-images/ros-jazzy-ros-base-noble` | Official ROS 2 Jazzy ros-base image mirrored for amd64 and arm64 deployments. |

CI compile images use a fixed name:

```text
xgc2-build-<ubuntu>-<layer>[-<ros>]
```

Layers are `base` → `dev` → `ros` → `full`. Ubuntu trees are `bionic`, `focal`,
`jammy`, and `noble`. ROS is only stacked where the distro matches:
Melodic on Bionic, Noetic on Focal, Humble on Jammy, Jazzy on Noble.
Every build image is amd64 and arm64.

| App | Layer | FROM / contains |
| --- | --- | --- |
| `xgc2-build-bionic-base` | `base` | `ubuntu:18.04` + apt hygiene |
| `xgc2-build-bionic-dev` | `dev` | compilers, CMake, dpkg, common C++/Python libs |
| `xgc2-build-bionic-ros-melodic` | `ros` | official ROS Melodic core |
| `xgc2-build-bionic-full-melodic` | `full` | Gazebo 9, RViz, PCL, OpenCV |
| `xgc2-build-focal-base` | `base` | `ubuntu:20.04` + apt hygiene |
| `xgc2-build-focal-dev` | `dev` | compilers, packaging, protobuf/grpc, desktop smoke libs |
| `xgc2-build-focal-ros-noetic` | `ros` | official ROS Noetic core |
| `xgc2-build-focal-full-noetic` | `full` | Gazebo 11, RViz, PCL, OpenCV, MAVROS |
| `xgc2-build-jammy-base` | `base` | `ubuntu:22.04` + apt hygiene |
| `xgc2-build-jammy-dev` | `dev` | same toolchain family as focal |
| `xgc2-build-jammy-ros-humble` | `ros` | official ROS 2 Humble core |
| `xgc2-build-jammy-full-humble` | `full` | RViz2, ros-gz, PCL, OpenCV |
| `xgc2-build-noble-base` | `base` | `ubuntu:24.04` + apt hygiene |
| `xgc2-build-noble-dev` | `dev` | same toolchain family as jammy |
| `xgc2-build-noble-ros-jazzy` | `ros` | official ROS 2 Jazzy core |
| `xgc2-build-noble-full-jazzy` | `full` | RViz2, ros-gz, PCL, OpenCV |

CI runs one chain per Ubuntu × architecture in parallel (eight jobs when the
full matrix is dirty). Each chain is `base` → `dev` → `ros` → `full` on the
same runner. After a layer is loaded locally, registry pushes run
in the background in parallel with the next layer's compile; the child `FROM`s
the local parent, not a registry round-trip. The job waits for those pushes
before it succeeds. Unrelated distros never wait on each other. Multi-arch
`:version` / `:latest` manifests are published per Ubuntu after that distro's
amd64 and arm64 tags exist. A change to `scripts/build/` rebuilds the whole
matrix. A change to one layer rebuilds that layer and its descendants.

## Catalog

XGC can sync the static catalog from:

```text
https://raw.githubusercontent.com/XGC-Team/xgc2-images/master/catalog/index.yml
```

The catalog points to app files in this repository and GHCR images built by CI.

## Image Build

Images rebuild on change, and on a daily schedule that refreshes `latest` tags. Only app definitions changed by a commit are built or mirrored. The detector looks for changes under `apps/<app-key>/`. Changes under
`scripts/build/` or the layered build workflows rebuild every `type: build`
image. `type: build` images run as independent Ubuntu × architecture chains
(`base → dev → ros → full` on the same runner) so a child `FROM`s the parent
just loaded locally. Registry pushes for that layer run in the
background and do not block the next compile. Unrelated distros never wait on
each other. Multi-arch `:version` / `:latest` manifests are published on
`master` per Ubuntu after that distro's amd64 and arm64 tags exist.

An app without `apps/<app-key>/Dockerfile` is treated as an external-image app.
CI reads `upstreamImage` from `app.yml` and mirrors that image into the XGC app
registry tags. If the app declares multiple architectures, CI copies the full
manifest list so deployment hosts can pull the matching architecture.

Deleting an `apps/<app-key>/` directory is detected and reported by CI, but
registry tag deletion is intentionally not automated. Remove old image tags
manually after confirming no deployment still references them.

For buildable apps, CI uses native GitHub-hosted runners for each architecture:
`ubuntu-latest` for amd64 and `ubuntu-24.04-arm` for arm64. QEMU is not used for
the production image build path. For pull requests, CI builds changed images
without pushing. Content changes on `master` push version and latest tags:

```text
ghcr.io/xgc-team/xgc2-images/<app-key>:latest
ghcr.io/xgc-team/xgc2-images/<app-key>:<version>
```

The daily schedule rebuilds every app and overwrites `latest` / `latest-<arch>` only. Version numbers stay as declared in `app.yml`.

Multi-architecture buildable apps also push architecture tags before manifest
assembly:

```text
ghcr.io/xgc-team/xgc2-images/<app-key>:latest-amd64
ghcr.io/xgc-team/xgc2-images/<app-key>:latest-arm64
ghcr.io/xgc-team/xgc2-images/<app-key>:<version>-amd64
ghcr.io/xgc-team/xgc2-images/<app-key>:<version>-arm64
```

## Image Garbage Collection

Stale image deletion is separated from the normal build workflow. Pushes and
pull requests never delete registry content.

Use the manual workflow `GC stale app images` to list or delete GHCR packages
whose app key is no longer present in `catalog/index.yml`.

Add repository secret `GHCR_GC_TOKEN` with
`read:packages` for dry-runs and both `read:packages` and `delete:packages` for
deletion. If the secret is absent, the workflow falls back to `GITHUB_TOKEN`.

Default mode is dry-run:

```text
delete=false
app=all
keep_last=0
```

Set `delete=true` only after confirming deployments no longer reference the old
app key. `keep_last` can retain the newest package versions for rollback during
a transition.

The workflow only deletes GHCR package versions.

The same dry-run can be started locally when the `gh` token has `read:packages`:

```bash
scripts/gc-ghcr-images.sh --owner XGC-Team --repo xgc2-images
```

## Local Smoke

```bash
docker build -t xgc-ros1-runtime:local apps/xgc-ros1-runtime
docker run --rm xgc-ros1-runtime:local bash -lc \
  'source /opt/ros/noetic/setup.bash && rosversion -d && roscore --help >/dev/null'
```

For GUI/Gazebo usage, run through the app compose file or mount X11 manually.

The centralized XGC2 ROS1 simulation image additionally verifies its locked
product set and launch files:

```bash
docker build -t xgc2-ros1-central-sim:local apps/xgc2-ros1-central-sim
docker run --rm xgc2-ros1-central-sim:local \
  /usr/local/bin/xgc2-central-sim-healthcheck
docker run --rm xgc2-ros1-central-sim:local \
  /usr/local/bin/xgc2-central-sim-smoke
```

## License

See `LICENSE`.

