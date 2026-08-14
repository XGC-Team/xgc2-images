#!/usr/bin/env python3
"""Generate the xgc2-build-* app trees from the shared package lists."""
from __future__ import annotations

from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
APPS = ROOT / "apps"
VERSION = "1.0.0"
REGISTRY = "ghcr.io/xgc-team/xgc2-images"

TREES = [
    {
        "ubuntu": "bionic",
        "from_os": "ubuntu:18.04",
        "ros": "melodic",
        "layers": ("base", "dev", "ros", "full"),
    },
    {
        "ubuntu": "focal",
        "from_os": "ubuntu:20.04",
        "ros": "noetic",
        "layers": ("base", "dev", "ros", "full"),
    },
    {
        "ubuntu": "jammy",
        "from_os": "ubuntu:22.04",
        "ros": "humble",
        "layers": ("base", "dev", "ros", "full"),
    },
    {
        "ubuntu": "noble",
        "from_os": "ubuntu:24.04",
        "ros": "jazzy",
        "layers": ("base", "dev", "ros", "full"),
    },
]


def app_key(ubuntu: str, layer: str, ros: str | None) -> str:
    if layer in {"ros", "full"}:
        if not ros:
            raise ValueError(f"{layer} requires a ROS distro")
        return f"xgc2-build-{ubuntu}-{layer}-{ros}"
    return f"xgc2-build-{ubuntu}-{layer}"


def parent_key(ubuntu: str, layer: str, ros: str | None) -> str | None:
    if layer == "base":
        return None
    if layer == "dev":
        return app_key(ubuntu, "base", None)
    if layer == "ros":
        return app_key(ubuntu, "dev", None)
    if layer == "full":
        return app_key(ubuntu, "ros", ros)
    raise ValueError(layer)


def title(ubuntu: str, layer: str, ros: str | None) -> str:
    names = {
        "base": f"XGC2 {ubuntu} CI base",
        "dev": f"XGC2 {ubuntu} CI dev",
        "ros": f"XGC2 {ubuntu} {ros} CI ros",
        "full": f"XGC2 {ubuntu} {ros} CI full",
    }
    return names[layer]


def description(ubuntu: str, layer: str, ros: str | None) -> str:
    if layer == "base":
        return f"Ubuntu {ubuntu} CI base with apt hygiene only. No compilers, ROS, or XGC2 APT packages."
    if layer == "dev":
        return f"Ubuntu {ubuntu} CI compile and Debian packaging image. No ROS and no XGC2 APT packages."
    if layer == "ros":
        return f"Ubuntu {ubuntu} + official ROS {ros} CI image for compiling product sources. No XGC2 APT packages."
    return f"Ubuntu {ubuntu} + official ROS {ros} full CI image including simulation and vision stacks. No XGC2 APT packages."


def dockerfile(ubuntu: str, layer: str, ros: str | None, from_os: str, parent: str | None) -> str:
    if parent:
        default_parent = f"{REGISTRY}/{parent}:{VERSION}"
    else:
        default_parent = from_os
    env = [
        "ENV DEBIAN_FRONTEND=noninteractive",
        "ENV LANG=en_US.UTF-8",
        "ENV LC_ALL=en_US.UTF-8",
    ]
    if ros:
        env.append(f"ENV ROS_DISTRO={ros}")
        if ros in {"melodic", "noetic"}:
            env.append("ENV DISABLE_ROS1_EOL_WARNINGS=1")
    run_parts = [
        "chmod +x /tmp/xgc2-build/*.sh /usr/local/bin/xgc2-build-healthcheck",
        "cp /tmp/xgc2-build/assert-no-xgc2-apt.sh /usr/local/bin/xgc2-build-assert-no-xgc2-apt.sh",
        "chmod +x /usr/local/bin/xgc2-build-assert-no-xgc2-apt.sh",
        "printf 'Acquire::Retries \"5\";\\n' >/etc/apt/apt.conf.d/99-xgc2-retries",
    ]
    if layer == "base":
        run_parts.extend(
            [
                "/tmp/xgc2-build/install-packages.sh /tmp/xgc2-build/packages/base.txt",
                "locale-gen en_US.UTF-8",
            ]
        )
    elif layer == "dev":
        run_parts.append(
            "/tmp/xgc2-build/install-packages.sh "
            "/tmp/xgc2-build/packages/dev.txt "
            f"/tmp/xgc2-build/packages/dev-{ubuntu}.txt"
        )
    elif layer == "ros":
        run_parts.extend(
            [
                f"/tmp/xgc2-build/install-ros-apt-source.sh {ros} {ubuntu}",
                f"/tmp/xgc2-build/install-packages.sh /tmp/xgc2-build/packages/ros-tools-{ros}.txt",
                f"/tmp/xgc2-build/install-ros-packages.sh {ros} /tmp/xgc2-build/packages/ros-{ros}.txt",
            ]
        )
    else:
        run_parts.extend(
            [
                f"/tmp/xgc2-build/install-packages.sh /tmp/xgc2-build/packages/full-sys-{ubuntu}.txt",
                f"/tmp/xgc2-build/install-ros-packages.sh {ros} /tmp/xgc2-build/packages/full-{ros}.txt",
            ]
        )
        if ros == "noetic":
            run_parts.append(
                'if [[ -x /opt/ros/noetic/lib/mavros/install_geographiclib_datasets.sh ]]; then '
                "/opt/ros/noetic/lib/mavros/install_geographiclib_datasets.sh || true; fi"
            )
    run_parts.extend(
        [
            "/tmp/xgc2-build/assert-no-xgc2-apt.sh",
            "rm -rf /tmp/xgc2-build /var/lib/apt/lists/*",
        ]
    )
    run = " \\\n && ".join(run_parts)
    return f"""# syntax=docker/dockerfile:1.7
ARG PARENT_IMAGE={default_parent}
FROM ${{PARENT_IMAGE}}

LABEL org.opencontainers.image.title="{title(ubuntu, layer, ros)}"
LABEL org.opencontainers.image.description="{description(ubuntu, layer, ros)}"
LABEL org.opencontainers.image.source="https://github.com/XGC-Team/xgc2-images"

{chr(10).join(env)}
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

COPY scripts/build/ /tmp/xgc2-build/
COPY apps/{app_key(ubuntu, layer, ros)}/scripts/healthcheck.sh /usr/local/bin/xgc2-build-healthcheck

RUN {run}

WORKDIR /work
CMD ["bash"]
"""


def healthcheck(ubuntu: str, layer: str, ros: str | None) -> str:
    lines = [
        "#!/usr/bin/env bash",
        "set -euo pipefail",
        ". /etc/os-release",
        f'test "${{VERSION_CODENAME}}" = "{ubuntu}"',
        "/usr/local/bin/xgc2-build-assert-no-xgc2-apt.sh",
    ]
    # assert script is only in the image during build; copy it to a stable path
    if layer == "base":
        lines += [
            "test -f /etc/apt/apt.conf.d/99-xgc2-retries",
            "command -v locale-gen >/dev/null",
        ]
    elif layer == "dev":
        lines += [
            "command -v g++ >/dev/null",
            "command -v cmake >/dev/null",
            "command -v dpkg-buildpackage >/dev/null",
            "python3 -c 'import yaml,numpy'",
        ]
    elif layer == "ros":
        lines += [
            "set +u",
            f"source /opt/ros/{ros}/setup.bash",
            "set -u",
            f'test "${{ROS_DISTRO}}" = "{ros}"',
        ]
        if ros in {"humble", "jazzy"}:
            lines += ["command -v ros2 >/dev/null", "command -v colcon >/dev/null"]
        else:
            lines += ["command -v rospack >/dev/null", "command -v catkin_make >/dev/null"]
    else:
        lines += [
            "set +u",
            f"source /opt/ros/{ros}/setup.bash",
            "set -u",
            f'test "${{ROS_DISTRO}}" = "{ros}"',
        ]
        if ros in {"humble", "jazzy"}:
            lines += ["command -v rviz2 >/dev/null"]
        else:
            lines += ["command -v rviz >/dev/null", "command -v gazebo >/dev/null"]
    lines += [
        "if dpkg-query -W -f='${Package}\\n' | grep -E '^(lib)?xgc2-|ros-[a-z]+-xgc2-'; then",
        '  echo "XGC2 packages leaked into build image" >&2',
        "  exit 1",
        "fi",
    ]
    return "\n".join(lines) + "\n"


def app_yml(ubuntu: str, layer: str, ros: str | None, parent: str | None, from_os: str) -> str:
    key = app_key(ubuntu, layer, ros)
    tags = ["Build", "CI", ubuntu.capitalize()]
    if ros:
        tags.append(ros.capitalize())
    depends = f"dependsOnApp: {parent}\n" if parent else ""
    from_image = "" if parent else f"fromImage: {from_os}\n"
    return f"""key: {key}
name: {title(ubuntu, layer, ros)}
version: {VERSION}
image: {REGISTRY}/{key}:{VERSION}
{depends}{from_image}description: {description(ubuntu, layer, ros)}
type: build
buildLayer: {layer}
tags:
{chr(10).join(f"  - {t}" for t in tags)}
architectures:
  - amd64
  - arm64/v8
license: Apache-2.0
source: https://github.com/XGC-Team/xgc2-images
entrypoints:
  shell: /bin/bash
  healthcheck: /usr/local/bin/xgc2-build-healthcheck
"""


def data_yml(ubuntu: str, layer: str, ros: str | None) -> str:
    key = app_key(ubuntu, layer, ros)
    tags = ["Build", "CI", ubuntu.capitalize()]
    if ros:
        tags.append(ros.capitalize())
    return f"""name: {title(ubuntu, layer, ros)}
title: {title(ubuntu, layer, ros)}
additionalProperties:
  key: {key}
  name: {title(ubuntu, layer, ros)}
  tags:
{chr(10).join(f"    - {t}" for t in tags)}
  shortDescEn: {description(ubuntu, layer, ros)}
  description:
    en: {description(ubuntu, layer, ros)}
  type: build
  crossVersionUpdate: true
  limit: 0
  website: https://github.com/XGC-Team/xgc2-images
  github: https://github.com/XGC-Team/xgc2-images
  document: https://github.com/XGC-Team/xgc2-images/tree/master/apps/{key}
  architectures:
    - amd64
    - arm64/v8
  batchInstallSupport: false
  formFields:
    - default: {key}
      envKey: CONTAINER_NAME
      label:
        en: Container name
      required: true
      type: text
"""


def compose_yml(ubuntu: str, layer: str, ros: str | None) -> str:
    key = app_key(ubuntu, layer, ros)
    return f"""services:
  {key}:
    image: {REGISTRY}/{key}:{VERSION}
    container_name: ${{CONTAINER_NAME}}
    working_dir: /work
    volumes:
      - ${{PWD}}:/work
    stdin_open: true
    tty: true
    command: ["bash"]
    healthcheck:
      test: ["CMD", "/usr/local/bin/xgc2-build-healthcheck"]
      interval: 30s
      timeout: 10s
      retries: 2
"""


def write_app(ubuntu: str, layer: str, ros: str | None, from_os: str) -> str:
    key = app_key(ubuntu, layer, ros)
    parent = parent_key(ubuntu, layer, ros)
    dest = APPS / key
    dest.mkdir(parents=True, exist_ok=True)
    (dest / "scripts").mkdir(exist_ok=True)
    (dest / "Dockerfile").write_text(dockerfile(ubuntu, layer, ros, from_os, parent))
    (dest / "app.yml").write_text(app_yml(ubuntu, layer, ros, parent, from_os))
    (dest / "data.yml").write_text(data_yml(ubuntu, layer, ros))
    (dest / "docker-compose.yml").write_text(compose_yml(ubuntu, layer, ros))
    hc = dest / "scripts" / "healthcheck.sh"
    hc.write_text(healthcheck(ubuntu, layer, ros))
    hc.chmod(0o755)
    return key


def catalog_entries() -> list[str]:
    blocks = []
    for tree in TREES:
        for layer in tree["layers"]:
            ros = tree["ros"] if layer in {"ros", "full"} else None
            key = app_key(tree["ubuntu"], layer, ros)
            tags = ["Build", "CI", tree["ubuntu"].capitalize()]
            if ros:
                tags.append(ros.capitalize())
            tag_yaml = "\n".join(f"      - {t}" for t in tags)
            blocks.append(
                f"""  - key: {key}
    name: {title(tree["ubuntu"], layer, ros)}
    version: {VERSION}
    type: build
    image: {REGISTRY}/{key}:{VERSION}
    app: ../apps/{key}/app.yml
    data: ../apps/{key}/data.yml
    compose: ../apps/{key}/docker-compose.yml
    tags:
{tag_yaml}"""
            )
    return blocks


def main() -> None:
    keys = []
    for tree in TREES:
        for layer in tree["layers"]:
            ros = tree["ros"] if layer in {"ros", "full"} else None
            keys.append(write_app(tree["ubuntu"], layer, ros, tree["from_os"]))
    print("generated", len(keys), "apps")
    for key in keys:
        print(" ", key)


if __name__ == "__main__":
    main()
