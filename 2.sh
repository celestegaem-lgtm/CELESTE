#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ANDROID_API="${ANDROID_API:-34}"
BUILD_TOOLS="${BUILD_TOOLS:-34.0.0}"
NDK_VERSION="${NDK_VERSION:-26.3.11579264}"
CMAKE_VERSION="${CMAKE_VERSION:-3.22.1}"

ANDROID_SDK_DIR="${ANDROID_SDK_DIR:-$HOME/android-sdk}"
CMDLINE_TOOLS_ZIP="${CMDLINE_TOOLS_ZIP:-commandlinetools-linux-11076708_latest.zip}"
CMDLINE_TOOLS_URL="${CMDLINE_TOOLS_URL:-https://dl.google.com/android/repository/${CMDLINE_TOOLS_ZIP}}"

LOG_DIR="${LOG_DIR:-$HOME}"
LOG_FILE="${LOG_FILE:-$LOG_DIR/bootstrap-gamedev-$(date +%Y%m%d-%H%M%S).log}"

export DEBIAN_FRONTEND=noninteractive

exec > >(tee -a "$LOG_FILE") 2>&1

on_err() {
  local exit_code=$?
  echo "[FATAL] Falha na linha ${BASH_LINENO[0]}: comando '${BASH_COMMAND}' (exit=${exit_code})"
  echo "[FATAL] Log: $LOG_FILE"
  exit "$exit_code"
}
trap on_err ERR

log() { printf "[%s] %s\n" "$(date +%H:%M:%S)" "$*"; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "[FATAL] Comando ausente: $1"; exit 1; }
}

need_sudo() {
  if ! command -v sudo >/dev/null 2>&1; then
    echo "[FATAL] sudo não encontrado. Instale sudo ou rode como root."
    exit 1
  fi
  sudo -n true >/dev/null 2>&1 || true
}

as_root() { need_sudo; sudo "$@"; }

retry() {
  local -r tries="$1"; shift
  local -r delay="$1"; shift
  local n=0
  until "$@"; do
    n=$((n+1))
    if [ "$n" -ge "$tries" ]; then
      return 1
    fi
    log "retry ${n}/${tries}: $* (aguardando ${delay}s)"
    sleep "$delay"
  done
}

append_once() {
  local file="$1"
  local line="$2"
  mkdir -p "$(dirname "$file")"
  touch "$file"
  grep -Fqs "$line" "$file" || printf "\n%s\n" "$line" >> "$file"
}

dpkg_has() { dpkg -s "$1" >/dev/null 2>&1; }

apt_update_once() {
  if [ "${_APT_UPDATED:-0}" = "0" ]; then
    log "apt: update"
    as_root apt-get update -y
    _APT_UPDATED=1
  fi
}

apt_install_missing() {
  apt_update_once
  local pkgs=()
  local p
  for p in "$@"; do
    if ! dpkg_has "$p"; then
      pkgs+=("$p")
    fi
  done
  if [ "${#pkgs[@]}" -gt 0 ]; then
    log "apt: install (${#pkgs[@]}): ${pkgs[*]}"
    as_root apt-get install -y --no-install-recommends "${pkgs[@]}"
  else
    log "apt: ok (nada a instalar)"
  fi
}

ensure_nodesource_20() {
  if command -v node >/dev/null 2>&1; then
    local major
    major="$(node -v | sed -E "s/^v([0-9]+).*/\1/")" || major=""
    if [ "$major" = "20" ]; then
      log "nodejs: já é v20"
      return 0
    fi
  fi
  log "nodejs: configurando NodeSource 20.x"
  apt_install_missing ca-certificates curl gnupg
  as_root mkdir -p /etc/apt/keyrings
  retry 3 2 bash -lc 'curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | sudo gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg'
  echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_20.x nodistro main" | as_root tee /etc/apt/sources.list.d/nodesource.list >/dev/null
  _APT_UPDATED=0
  apt_install_missing nodejs
  node -v || true
  npm -v || true
}

ensure_dotnet8_apt() {
  if command -v dotnet >/dev/null 2>&1; then
    local v
    v="$(dotnet --version 2>/dev/null || true)"
    if [[ "$v" == 8.* ]]; then
      log ".NET: já disponível (dotnet $v)"
      return 0
    fi
  fi

  log ".NET: tentando instalar via repositório Microsoft (apt)"
  apt_install_missing ca-certificates wget gpg apt-transport-https

  local ubuntu_codename
  ubuntu_codename="$(. /etc/os-release && echo "${VERSION_CODENAME:-}")"
  if [ -z "$ubuntu_codename" ]; then
    ubuntu_codename="jammy"
  fi

  as_root mkdir -p /etc/apt/keyrings
  retry 3 2 bash -lc 'wget -qO- https://packages.microsoft.com/keys/microsoft.asc | sudo gpg --dearmor -o /etc/apt/keyrings/microsoft.gpg'
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/microsoft.gpg] https://packages.microsoft.com/ubuntu/${ubuntu_codename}/prod ${ubuntu_codename} main" | as_root tee /etc/apt/sources.list.d/microsoft-prod.list >/dev/null

  _APT_UPDATED=0
  if ! as_root apt-get install -y --no-install-recommends dotnet-sdk-8.0; then
    log ".NET: fallback dotnet-install (userland)"
    retry 3 2 curl -fsSL https://dot.net/v1/dotnet-install.sh -o /tmp/dotnet-install.sh
    bash /tmp/dotnet-install.sh --channel 8.0 --install-dir "$HOME/.dotnet"
    export DOTNET_ROOT="$HOME/.dotnet"
    export PATH="$HOME/.dotnet:$PATH"
    append_once "$HOME/.bashrc" "export DOTNET_ROOT=\"$HOME/.dotnet\""
    append_once "$HOME/.bashrc" "export PATH=\"\$DOTNET_ROOT:\$PATH\""
  fi

  dotnet --info | head -n 25 || true
}

ensure_android_cmdline_tools() {
  log "Android: preparando SDK em $ANDROID_SDK_DIR"
  mkdir -p "$ANDROID_SDK_DIR/cmdline-tools" "$ANDROID_SDK_DIR/platform-tools" "$HOME/.android"

  local sdkmanager="$ANDROID_SDK_DIR/cmdline-tools/latest/bin/sdkmanager"
  if [ ! -x "$sdkmanager" ]; then
    log "Android: baixando cmdline-tools"
    local tmpdir
    tmpdir="$(mktemp -d)"
    retry 3 2 curl -fsSL -o "$tmpdir/cmdline.zip" "$CMDLINE_TOOLS_URL"
    unzip -q "$tmpdir/cmdline.zip" -d "$tmpdir"
    rm -rf "$ANDROID_SDK_DIR/cmdline-tools/latest"
    mv "$tmpdir/cmdline-tools" "$ANDROID_SDK_DIR/cmdline-tools/latest"
    rm -rf "$tmpdir"
  else
    log "Android: cmdline-tools já presente"
  fi

  export ANDROID_SDK_ROOT="$ANDROID_SDK_DIR"
  export ANDROID_HOME="$ANDROID_SDK_DIR"
  export PATH="$ANDROID_SDK_DIR/cmdline-tools/latest/bin:$ANDROID_SDK_DIR/platform-tools:$PATH"

  append_once "$HOME/.bashrc" "export ANDROID_SDK_ROOT=\"$HOME/android-sdk\""
  append_once "$HOME/.bashrc" "export ANDROID_HOME=\"\$ANDROID_SDK_ROOT\""
  append_once "$HOME/.bashrc" "export PATH=\"\$ANDROID_SDK_ROOT/cmdline-tools/latest/bin:\$ANDROID_SDK_ROOT/platform-tools:\$PATH\""

  need_cmd sdkmanager
  log "Android: aceitando licenças"
  yes | sdkmanager --sdk_root="$ANDROID_SDK_DIR" --licenses >/dev/null || true

  log "Android: instalando platform-tools/platforms/build-tools/ndk/cmake"
  sdkmanager --sdk_root="$ANDROID_SDK_DIR" \
    "platform-tools" \
    "platforms;android-${ANDROID_API}" \
    "build-tools;${BUILD_TOOLS}" \
    "cmdline-tools;latest" \
    "ndk;${NDK_VERSION}" \
    "cmake;${CMAKE_VERSION}"

  if command -v adb >/dev/null 2>&1; then
    adb version | head -n 1 || true
  fi
}

ensure_monogame_tools() {
  log "MonoGame: templates + MGCB editor"
  dotnet new install MonoGame.Templates.CSharp >/dev/null 2>&1 || true
  dotnet tool install --global dotnet-mgcb-editor >/dev/null 2>&1 || true
  append_once "$HOME/.bashrc" "export PATH=\"\$HOME/.dotnet/tools:\$PATH\""
  export PATH="$HOME/.dotnet/tools:$PATH"
}

ensure_docker_client() {
  log "Docker: instalando client + compose plugin (daemon pode não existir no Codespace)"
  apt_install_missing docker.io docker-compose-plugin
  if command -v docker >/dev/null 2>&1; then
    as_root usermod -aG docker "$USER" 2>/dev/null || true
  fi
}

vscode_ext_installed() {
  local ext="$1"
  code --list-extensions 2>/dev/null | awk '{print tolower($0)}' | grep -qx "$(echo "$ext" | awk '{print tolower($0)}')"
}

install_vscode_extensions() {
  if ! command -v code >/dev/null 2>&1; then
    log "VS Code: comando 'code' não disponível no PATH. Pulando extensões."
    return 0
  fi

  local exts=(
    ms-dotnettools.csharp
    ms-dotnettools.csdevkit
    ms-dotnettools.vscode-dotnet-runtime
    ms-vscode.cpptools
    ms-vscode.cmake-tools
    eamodio.gitlens
    adelphes.android-dev-ext
    bbenoist.doxygen
    cheshirekow.cmake-format
    dart-code.flutter
    editorconfig.editorconfig
    jajera.vsx-remote-ssh
    jeff-hykin.better-cpp-syntax
    jnoortheen.nix-ide
    redhat.java
    redhat.vscode-yaml
    vadimcn.vscode-lldb
  )

  log "VS Code: instalando extensões (idempotente)"
  local ext
  for ext in "${exts[@]}"; do
    if vscode_ext_installed "$ext"; then
      log "VS Code: ok (já instalada) $ext"
      continue
    fi
    log "VS Code: install $ext"
    code --install-extension "$ext" >/dev/null 2>&1 || true
  done
}

sanity() {
  log "Sanity:"
  echo "dotnet: $(dotnet --version 2>/dev/null || echo missing)"
  echo "mono: $(mono --version 2>/dev/null | head -n 1 || echo missing)"
  echo "java: $(java -version 2>&1 | head -n 1 || echo missing)"
  echo "gradle: $(gradle --version 2>/dev/null | head -n 1 || echo missing)"
  echo "sdkmanager: $(command -v sdkmanager || echo missing)"
  echo "adb: $(adb version 2>/dev/null | head -n 1 || echo missing)"
  echo "docker: $(docker --version 2>/dev/null || echo missing)"
  echo "cmake: $(cmake --version 2>/dev/null | head -n 1 || echo missing)"
  echo "clang: $(clang --version 2>/dev/null | head -n 1 || echo missing)"
  echo "gcc: $(gcc --version 2>/dev/null | head -n 1 || echo missing)"
  echo "node: $(node -v 2>/dev/null || echo missing)"
  echo "npm: $(npm -v 2>/dev/null || echo missing)"
  echo "LOG: $LOG_FILE"
}

main() {
  log "Bootstrap iniciado (Ubuntu/Codespace). Log: $LOG_FILE"
  need_sudo

  log "1) Base + toolchain (equivalente dev.nix)"
  apt_install_missing \
    bash coreutils git openssh-client curl wget jq unzip zip tar findutils file less nano \
    ripgrep fd-find htop tree \
    build-essential gcc g++ make cmake ninja-build meson pkg-config autoconf automake libtool \
    clang llvm lld gdb \
    python3 python3-pip \
    ca-certificates openssl sqlite3 libssl-dev zlib1g-dev libsqlite3-dev \
    libsdl2-dev libopenal-dev libfreetype6-dev libfontconfig1-dev libpng-dev

  log "2) Node.js 20 + npm"
  ensure_nodesource_20

  log "3) Java 17 + Gradle"
  apt_install_missing openjdk-17-jdk gradle

  log "4) .NET SDK 8"
  ensure_dotnet8_apt

  log "5) Mono"
  apt_install_missing mono-complete || true
  if ! command -v mono >/dev/null 2>&1; then
    apt_install_missing mono-runtime mono-devel || true
  fi

  log "6) Android SDK/NDK/CMake"
  ensure_android_cmdline_tools

  log "7) MonoGame"
  ensure_monogame_tools

  log "8) Docker client"
  ensure_docker_client

  log "9) VS Code extensions (pula se já instaladas)"
  install_vscode_extensions

  sanity

  log "Concluído. Reabra o terminal (ou: source ~/.bashrc). Se instalou Docker, reabra para o grupo docker aplicar."
}

main "$@"
