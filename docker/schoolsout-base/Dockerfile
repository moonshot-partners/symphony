FROM ubuntu:24.04

ARG DEBIAN_FRONTEND=noninteractive
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Base tools + Python 3.12 (default in Ubuntu 24.04)
RUN apt-get update && apt-get install -y --no-install-recommends \
      curl \
      git \
      ca-certificates \
      gnupg \
      build-essential \
      libssl-dev \
      zlib1g-dev \
      python3 \
      python3-dev \
      python3-pip \
      python3-venv \
    && rm -rf /var/lib/apt/lists/*

# Make python/python3 point to python3.12
RUN update-alternatives --install /usr/bin/python python /usr/bin/python3 1

# Ruby 3.4.2 via mise (precompiled)
ENV HOME=/root
RUN curl https://mise.run | bash
ENV PATH=/root/.local/bin:/root/.local/share/mise/shims:$PATH
RUN mise settings ruby.compile=false \
    && mise install ruby@3.4.2 \
    && mise use -g ruby@3.4.2

# Node 22 via NodeSource
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

# pnpm
RUN npm install -g pnpm

# gh CLI
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update && apt-get install -y --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/*

# Install devflow-agent (vendored) then shim
COPY docker/schoolsout-base/vendor/devflow-agent /opt/devflow-agent
COPY elixir/priv/agent_shim /opt/agent_shim

RUN pip install --break-system-packages --no-cache-dir \
      /opt/devflow-agent \
      /opt/agent_shim

# Default bundler
RUN gem install bundler --no-document

# Wire gh as the git credential helper so GH_TOKEN (passed at runtime)
# authenticates HTTPS git operations (clone, push) inside the container.
RUN git config --global credential.https://github.com.helper '!/usr/bin/gh auth git-credential' \
    && git config --global credential.https://gist.github.com.helper '!/usr/bin/gh auth git-credential'

# Create non-root agent user. Claude Code refuses --dangerously-skip-permissions
# when running as root, so all agent sessions must run as a non-root user.
# Make /root world-traversable so mise shims and ruby remain accessible via PATH.
RUN chmod 755 /root \
    && chmod -R a+rX /root/.local \
    && useradd -m -u 1001 -s /bin/bash agent \
    && cp /root/.gitconfig /home/agent/.gitconfig \
    && chown agent:agent /home/agent/.gitconfig

USER agent
ENV HOME=/home/agent
# mise global config lives under the root home where it was installed;
# point all users at it so `ruby`, `gem`, etc. resolve via the same shims.
ENV MISE_GLOBAL_CONFIG_FILE=/root/.config/mise/config.toml
ENV MISE_DATA_DIR=/root/.local/share/mise
WORKDIR /workspace

CMD ["python", "-m", "symphony_agent_shim"]
