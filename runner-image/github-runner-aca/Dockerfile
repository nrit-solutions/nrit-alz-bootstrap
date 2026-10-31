FROM mcr.microsoft.com/azure-powershell:ubuntu-24.04

# To make it easier for build and release pipelines to run apt-get,
# configure apt to not require confirmation (assume the -y argument by default)
ENV DEBIAN_FRONTEND=noninteractive
RUN echo "APT::Get::Assume-Yes \"true\";" > /etc/apt/apt.conf.d/90assumeyes

RUN apt-get update \
  && apt-get upgrade -y \
  && apt-get install -y --no-install-recommends \
  ca-certificates \
  curl \
  jq \
  git \
  dumb-init \
  sudo \
  iputils-ping \
  libcurl4 \
  libunwind8 \
  netcat-openbsd \
  ruby \
  unzip \
  dnsutils \
  nodejs

SHELL ["/bin/bash", "-eo", "pipefail", "-c"]

RUN curl -sL https://aka.ms/InstallAzureCLIDeb | bash

RUN groupadd -g 121 runner \
  && useradd -mr -d /home/runner -u 1001 -g 121 runner \
  && usermod -aG sudo runner \
  && echo '%sudo ALL=(ALL) NOPASSWD: ALL' >> /etc/sudoers

ENV AGENT_TOOLSDIRECTORY=/opt/hostedtoolcache
RUN mkdir -p /opt/hostedtoolcache


WORKDIR /actions-runner
COPY install_actions.sh /actions-runner

RUN chmod +x /actions-runner/install_actions.sh \
  && /actions-runner/install_actions.sh "${GH_RUNNER_VERSION}" "${TARGETPLATFORM}" \
  && rm /actions-runner/install_actions.sh \
  && chown runner /_work /actions-runner /opt/hostedtoolcache

# Platform additions: policy/scan/cost tooling for the tfpr hook gates.
# conftest (static binary) and checkov (Python, no static binary) so the gates
# run on the self-hosted runner. Everything above this line is the vendored AVM
# github-runner-aca image at ref 9b4c292 (see README).
ARG CHECKOV_VERSION=3.4.0
ARG CONFTEST_VERSION=0.71.1
RUN apt-get update \
  && apt-get install -y --no-install-recommends python3 python3-pip \
  && rm -rf /var/lib/apt/lists/*
RUN pip3 install --no-cache-dir --break-system-packages "checkov==${CHECKOV_VERSION}"
RUN curl -sSfL -O "https://github.com/open-policy-agent/conftest/releases/download/v${CONFTEST_VERSION}/conftest_${CONFTEST_VERSION}_Linux_x86_64.tar.gz" \
  && curl -sSfL -O "https://github.com/open-policy-agent/conftest/releases/download/v${CONFTEST_VERSION}/checksums.txt" \
  && grep " conftest_${CONFTEST_VERSION}_Linux_x86_64.tar.gz$" checksums.txt | sha256sum -c - \
  && tar -C /usr/local/bin -xzf "conftest_${CONFTEST_VERSION}_Linux_x86_64.tar.gz" conftest \
  && rm -f "conftest_${CONFTEST_VERSION}_Linux_x86_64.tar.gz" checksums.txt \
  && conftest --version \
  && checkov --version

COPY token.sh entrypoint.sh app_token.sh /
RUN chmod +x /token.sh /entrypoint.sh /app_token.sh

ENTRYPOINT ["/entrypoint.sh"]
CMD ["./bin/Runner.Listener", "run", "--startuptype", "service"]
