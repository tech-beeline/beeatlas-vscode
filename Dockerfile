FROM ubuntu:24.04 AS builder

ENV DEBIAN_FRONTEND=noninteractive \
    TZ=Etc/UTC

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    wget \
    git \
    sudo \
    dumb-init \
    build-essential \
    ca-certificates \
    python3 \
    python3-pip \
    python3-venv \
    && curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y nodejs \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# use raw.githubusercontent instead of unstable https://code-server.dev/install.sh
RUN curl -fsSL https://raw.githubusercontent.com/cdr/code-server/main/install.sh | sh

ARG USERNAME=vscode
ARG USER_UID=1000
ARG USER_GID=1000

RUN userdel -r ubuntu 2>/dev/null || true && \
    groupdel ubuntu 2>/dev/null || true

RUN groupadd --gid $USER_GID $USERNAME \
    && useradd --uid $USER_UID --gid $USER_GID -m -s /bin/bash $USERNAME \
    && echo "$USERNAME ALL=(root) NOPASSWD:ALL" > /etc/sudoers.d/$USERNAME \
    && chmod 0440 /etc/sudoers.d/$USERNAME

USER $USERNAME
WORKDIR /home/$USERNAME

RUN mkdir -p /home/$USERNAME/.config/code-server && \
    echo 'bind-addr: 0.0.0.0:8080' > /home/$USERNAME/.config/code-server/config.yaml && \
    echo 'auth: password' >> /home/$USERNAME/.config/code-server/config.yaml && \
    echo 'password: changeme' >> /home/$USERNAME/.config/code-server/config.yaml && \
    echo 'cert: false' >> /home/$USERNAME/.config/code-server/config.yaml

# Отключаем автообновление расширений и проверку обновлений в закрытых сетях,
# иначе VS Code Server уходит в таймауты к маркетплейсу и блокирует работу в UI.
RUN mkdir -p /home/$USERNAME/.local/share/code-server/User && cat > /home/$USERNAME/.local/share/code-server/User/settings.json <<'EOF'
{
    "extensions.autoCheckUpdates": false,
    "extensions.autoUpdate": false,
    "extensions.ignoreRecommendations": true,
    "update.mode": "none",
    "telemetry.telemetryLevel": "off"
}
EOF

# Запекаем расширение C4 из репозитория (vscode-extensions/), чтобы оно ставилось
# без обращения к маркетплейсу, и сохраняем как запасную папку для entrypoint.sh
COPY --chown=$USERNAME:$USERNAME vscode-extensions /home/$USERNAME/.local/share/code-server/extensions-save

COPY --chown=$USERNAME:$USERNAME entrypoint.sh /home/vscode/entrypoint.sh
RUN chmod +x /home/vscode/entrypoint.sh

EXPOSE 8080

ENTRYPOINT ["/usr/bin/dumb-init", "--"]
CMD ["/home/vscode/entrypoint.sh"]

