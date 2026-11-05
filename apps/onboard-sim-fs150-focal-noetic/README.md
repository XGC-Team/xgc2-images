# FS150 Noetic Python telemetry SDK

The runtime pins the APT-owned `xgc2-zenoh` 1.10.2 package
(`1.10.2-1~focal`) into the system Python shared with Noetic `rospy`; the
builder declares the same exact version. `install-zenoh.sh` is the strict
consumer and offline capability check from the app-pinned tool-scripts release
selected by `tool-scripts.json`; it performs no pip, download, APT-source or source build. Robot
baseline preparation delegates to this same consumer. Neither source
deployment nor product installation installs SDK dependencies. The image build
must verify the signed APT receipt for the pinned Zenoh package first.

The FS150 app selects its own immutable
`apps/onboard-sim-fs150-focal-noetic/tool-scripts.json` release before the
shared onboard baseline lock. The role tags are mutable: consumers requiring an
exact build must resolve and pin its published registry digest.

Release 1.0.18 moves the runtime and builder Zenoh pin to `1.10.2-1~focal`
and the builder VRPN-to-Zenoh bridge pins to `0.1.0-5~focal`, rebuilt
against the same SDK. It also pins the tool-scripts baseline's
`xgc2-mavlink-router=3.0.0-14+focal`. The SDK4, ROS utilities 1.1.1-11 and
other package pins are unchanged. Adapter packages are not part of this base;
any Adapter consumer build must use the same SDK and its own reviewed pin.

Release 1.0.8 is the same FS150 runtime/builder supply as 1.0.7, versioned for
the shared robot-baseline commit so the already-published 1.0.7 digests remain
immutable. Release 1.0.7 was the app-scoped FS150 rebuild of the same 1.0.6
source; its per-arch and manifest digests are complete. Release 1.0.6
explicitly allows the formal FS150 `ros-noetic-xgc2-runtime-sync=2.0.0-1`
coordination package in the robot-base guard. Release 1.0.5 adopts the
published acados 0.6.0 APT SDK (`xgc2-acados=0.6.0-1~focal`), its
package-owned focal code-generation entry, and the corrected `90d1fec`
baseline archive. Release 1.0.4 adopts the published Zenoh 1.8.0 APT SDK and
the strict tool-scripts consumer. Release 1.0.3 masks chrony and its alias
inside the container while retaining the chrony tools. The host supplies the
shared clock. Release 1.0.2 added MAVROS extras including the vision pose
plugin; 1.0.1 added Ubuntu `netbase` for VRPN protocol/service lookups. CI
publishes the existing `runtime` and `builder` role tags plus versioned
`runtime-1.0.8` and `builder-1.0.8` tags for both architectures; scheduled
refreshes update only the role tags.
