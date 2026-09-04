# syntax=docker/dockerfile:1.7
ARG PARENT_IMAGE=ghcr.io/xgc-team/xgc2-images/xgc2-build-noble-base:1.0.0
FROM ${PARENT_IMAGE}

LABEL org.opencontainers.image.title="XGC2 LaTeX toolchain"
LABEL org.opencontainers.image.description="Noble XeLaTeX task image with latexmk. Trimmed TeX Live. No XGC2 APT packages."
LABEL org.opencontainers.image.source="https://github.com/XGC-Team/xgc2-images"

ENV DEBIAN_FRONTEND=noninteractive
ENV LANG=C.UTF-8
ENV LC_ALL=C.UTF-8
ENV SOURCE_DATE_EPOCH=0
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

COPY scripts/healthcheck.sh /usr/local/bin/xgc2-latex-toolchain-healthcheck
COPY scripts/assert-no-xgc2-apt.sh /usr/local/bin/xgc2-build-assert-no-xgc2-apt.sh

# Compile tasks must `docker run --network=none` and must not mount the host Docker socket.
# This image only provides latexmk + xelatex + synctex.
RUN chmod +x /usr/local/bin/xgc2-latex-toolchain-healthcheck /usr/local/bin/xgc2-build-assert-no-xgc2-apt.sh \
 && apt-get update \
 && apt-get install -y --no-install-recommends \
      latexmk \
      texlive-xetex \
      texlive-latex-recommended \
      texlive-latex-extra \
      texlive-fonts-recommended \
      texlive-science \
      texlive-publishers \
      texlive-bibtex-extra \
      texlive-plain-generic \
      biber \
      lmodern \
      fonts-liberation \
      fonts-texgyre \
 && rm -rf /var/lib/apt/lists/* \
 && /usr/local/bin/xgc2-build-assert-no-xgc2-apt.sh \
 && /usr/local/bin/xgc2-latex-toolchain-healthcheck

WORKDIR /work
CMD ["bash"]
