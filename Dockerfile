# macnod/monitor-sites

FROM ubuntu:latest

ENV DEBIAN_FRONTEND=noninteractive

ARG ROSWELL_VERSION="v23.10.14.114"
ARG SBCL_VERSION="2.5.10"
ARG ROSWELL_URL_PREFIX="https://github.com/roswell/roswell/releases/download"

RUN apt update && apt upgrade -y && apt install -y \
    build-essential \
    bzip2 \
    curl \
    git \
    libcurl4-openssl-dev \
    tar \
    tzdata \
    zlib1g-dev \
    && ln -sf /usr/share/zoneinfo/America/Los_Angeles /etc/localtime

# Install Roswell
RUN url="${ROSWELL_URL_PREFIX}/${ROSWELL_VERSION}/roswell_${ROSWELL_VERSION#v}-1_amd64.deb" \
    && curl -fsSL "${url}" -o roswell.deb \
       || { echo "Failed to download Roswell ${ROSWELL_VERSION}"; exit 1; } \
    && dpkg -i roswell.deb \
    && rm roswell.deb

# Install SBCL
RUN ros install "sbcl-bin/${SBCL_VERSION}" && ros use "sbcl-bin/${SBCL_VERSION}"

# 3rd-party packages
RUN ros install cl-ppcre
RUN ros install drakma
RUN ros install hunchentoot
RUN ros install swank
RUN ros install trivial-utf-8
RUN ros install uiop

# macnod packages (order matters: dc-dlist -> dc-ds -> dc-time -> p-log -> dc-eclectic)
RUN ros install macnod/dc-dlist
RUN ros install macnod/dc-ds
RUN ros install macnod/dc-time
RUN ros install macnod/p-log
RUN ros install macnod/dc-eclectic

# monitor-sites package
COPY . /root/.roswell/local-projects/monitor-sites/
WORKDIR /app
RUN ros run -- --eval "(ql:register-local-projects)" --quit
# Pre-compile at build time so container start is fast.
RUN ros run -- --eval "(require :monitor-sites)" --quit

# Runtime files: script and CA bundle at known paths
COPY monitor-sites /app/monitor-sites
COPY ca-bundle.crt /app/ca-bundle.crt
RUN chmod +x /app/monitor-sites

# --disable-debugger: on unhandled error, print a backtrace and exit
# instead of hanging at an interactive debugger prompt.
ENTRYPOINT ["/app/monitor-sites", "start-in-container"]
