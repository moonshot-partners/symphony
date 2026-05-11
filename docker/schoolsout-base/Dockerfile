FROM ruby:3.4.2-slim

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN apt-get update && apt-get install -y --no-install-recommends \
      curl \
      git \
      ca-certificates \
      gnupg \
      build-essential \
      python3.12 \
      python3.12-dev \
      python3-pip \
      python3-venv \
    && rm -rf /var/lib/apt/lists/*

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

# Make python3.12 the default python3
RUN update-alternatives --install /usr/bin/python3 python3 /usr/bin/python3.12 1 \
    && update-alternatives --install /usr/bin/python python /usr/bin/python3.12 1

# Install devflow-agent (vendored) then shim
COPY docker/schoolsout-base/vendor/devflow-agent /opt/devflow-agent
COPY elixir/priv/agent_shim /opt/agent_shim

RUN pip install --break-system-packages --no-cache-dir \
      /opt/devflow-agent \
      /opt/agent_shim

# Default bundler
RUN gem install bundler --no-document

WORKDIR /workspace

CMD ["python", "-m", "symphony_agent_shim"]
