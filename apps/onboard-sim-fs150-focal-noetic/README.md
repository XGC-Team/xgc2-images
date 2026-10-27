# FS150 Noetic Python telemetry SDK

The runtime installs the official `eclipse-zenoh` 1.5.1 Python wheels into the
system Python shared with Noetic `rospy`; the builder inherits the same files.
`install-zenoh.sh` is the single installer and offline capability check for
this SDK. It pins the public telemetry product's immutable requirements metadata
and both official wheel SHA-256 hashes. Robot baseline preparation delegates to
this same installer. Neither source deployment nor product installation installs
SDK dependencies.

The tool-scripts named context remains independently pinned by
`onboard-baseline/tool-scripts.json`; the SDK implementation is part of this
app's image source context. The role tags are mutable: consumers requiring an
exact build must resolve and pin its published registry digest.

Release 1.0.1 adds Ubuntu `netbase` for VRPN protocol/service lookups. CI
publishes the existing `runtime` and `builder` role tags plus versioned
`runtime-1.0.1` and `builder-1.0.1` tags for both architectures; scheduled
refreshes update only the role tags.
