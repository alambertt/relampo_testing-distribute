#!/usr/bin/env sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"

BIN_NAME="relampo"
REPO="${RELAMPO_REPO:-sqaadvisory-labs/relampo-backend}"
INSTALL_DIR="${RELAMPO_INSTALL_DIR:-}"
RELAMPO_VERSION="${RELAMPO_VERSION:-}"
RELAMPO_TAG="${RELAMPO_TAG:-}"
RELAMPO_URL="${RELAMPO_URL:-}"
RELAMPO_BASE_URL="${RELAMPO_BASE_URL:-}"
RELAMPO_BASE_ROOT_URL="${RELAMPO_BASE_ROOT_URL:-}"
RELAMPO_LATEST_URL="${RELAMPO_LATEST_URL:-}"
RELAMPO_LOCAL_DIR="${RELAMPO_LOCAL_DIR:-}"

usage() {
  cat <<'EOF'
Usage: install.sh [--version VERSION] [--dir DIR] [--url URL] [--repo OWNER/REPO] [--local DIR]

Installs the relampo CLI from a release archive.

Environment variables:
  RELAMPO_VERSION     Version (e.g. 1.2.3). If empty, uses latest release.
  RELAMPO_TAG         Release tag (e.g. v1.2.3). Overrides RELAMPO_VERSION.
  RELAMPO_REPO        GitHub repo in owner/name format. Default: sqaadvisory-labs/relampo-backend
  RELAMPO_URL         Full URL to the archive. Overrides repo/version detection.
  RELAMPO_BASE_URL    Base URL where archives live (release folder). Default: https://dl.relampo.com/relampo/v<version>
  RELAMPO_BASE_ROOT_URL  Channel root used to build the versioned folder as <root>/v<resolved-version> when RELAMPO_BASE_URL is unset. Default: https://dl.relampo.com/relampo
  RELAMPO_LATEST_URL  URL used to resolve the latest version. Default: https://dl.relampo.com/relampo/latest.txt
  RELAMPO_LOCAL_DIR   Local folder with relampo_<os>_<arch> binaries.
  RELAMPO_INSTALL_DIR Install directory (default: /usr/local/bin or ~/.local/bin).
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --version)
      RELAMPO_VERSION="$2"
      shift 2
      ;;
    --dir)
      INSTALL_DIR="$2"
      shift 2
      ;;
    --url)
      RELAMPO_URL="$2"
      shift 2
      ;;
    --repo)
      REPO="$2"
      shift 2
      ;;
    --local)
      RELAMPO_LOCAL_DIR="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

need_cmd() {
  command -v "$1" >/dev/null 2>&1
}

default_latest_url() {
  if [ -n "$RELAMPO_LATEST_URL" ]; then
    printf '%s\n' "$RELAMPO_LATEST_URL"
    return
  fi
  printf '%s\n' "https://dl.relampo.com/relampo/latest.txt"
}

PROFILE_UPDATE_RESULT="unsupported"
PROFILE_UPDATE_PATH=""

path_contains_dir() {
  echo "$PATH" | tr ':' '\n' | grep -qx "$1"
}

detect_shell_name() {
  shell_name="${SHELL##*/}"
  if [ -n "$shell_name" ]; then
    echo "$shell_name"
    return
  fi
  case "${os:-}" in
    darwin) echo "zsh" ;;
    *) echo "sh" ;;
  esac
}

detect_shell_profile() {
  shell_name="$1"
  case "$shell_name" in
    zsh)
      echo "$HOME/.zshrc"
      ;;
    bash)
      if [ "${os:-}" = "darwin" ]; then
        echo "$HOME/.bash_profile"
      elif [ -f "$HOME/.bashrc" ] || [ ! -f "$HOME/.bash_profile" ]; then
        echo "$HOME/.bashrc"
      else
        echo "$HOME/.bash_profile"
      fi
      ;;
    fish)
      echo "$HOME/.config/fish/config.fish"
      ;;
    ksh)
      echo "$HOME/.kshrc"
      ;;
    *)
      echo "$HOME/.profile"
      ;;
  esac
}

profile_contains_install_dir() {
  profile_file="$1"
  install_dir="$2"

  [ -f "$profile_file" ] || return 1
  if grep -F "$install_dir" "$profile_file" >/dev/null 2>&1; then
    return 0
  fi

  case "$install_dir" in
    "$HOME"/*)
      home_relative="\$HOME/${install_dir#$HOME/}"
      if grep -F "$home_relative" "$profile_file" >/dev/null 2>&1; then
        return 0
      fi
      home_relative_braced="\${HOME}/${install_dir#$HOME/}"
      if grep -F "$home_relative_braced" "$profile_file" >/dev/null 2>&1; then
        return 0
      fi
      ;;
  esac

  return 1
}

append_path_block_to_profile() {
  profile_file="$1"
  shell_name="$2"
  install_dir="$3"

  case "$shell_name" in
    fish)
      cat >> "$profile_file" <<EOF

# >>> relampo PATH >>>
set -gx PATH "$install_dir" \$PATH
# <<< relampo PATH <<<
EOF
      ;;
    *)
      cat >> "$profile_file" <<EOF

# >>> relampo PATH >>>
export PATH="$install_dir:\$PATH"
# <<< relampo PATH <<<
EOF
      ;;
  esac
}

ensure_path_in_shell_profile() {
  install_dir="$1"
  shell_name="$(detect_shell_name)"
  profile_file="$(detect_shell_profile "$shell_name")"

  PROFILE_UPDATE_RESULT="unsupported"
  PROFILE_UPDATE_PATH=""

  [ -n "$profile_file" ] || return 1
  mkdir -p "$(dirname "$profile_file")"
  touch "$profile_file"

  PROFILE_UPDATE_PATH="$profile_file"
  if profile_contains_install_dir "$profile_file" "$install_dir"; then
    PROFILE_UPDATE_RESULT="already"
    return 0
  fi

  append_path_block_to_profile "$profile_file" "$shell_name" "$install_dir"
  PROFILE_UPDATE_RESULT="added"
  return 0
}

install_bin() {
  src="$1"
  mkdir -p "$INSTALL_DIR"
  cp "$src" "$INSTALL_DIR/$BIN_NAME"
  chmod 0755 "$INSTALL_DIR/$BIN_NAME"
  echo "Installed to $INSTALL_DIR/$BIN_NAME"
  if ! path_contains_dir "$INSTALL_DIR"; then
    if ensure_path_in_shell_profile "$INSTALL_DIR"; then
      case "$PROFILE_UPDATE_RESULT" in
        added)
          echo "Added $INSTALL_DIR to $PROFILE_UPDATE_PATH automatically."
          echo "Open a new terminal window if relampo is not available in this one yet."
          ;;
        already)
          echo "PATH already includes $INSTALL_DIR in $PROFILE_UPDATE_PATH for new shells."
          echo "Open a new terminal window if relampo is not available in this one yet."
          ;;
        *)
          echo "Add this to your shell profile:"
          echo "  export PATH=\"$INSTALL_DIR:\$PATH\""
          ;;
      esac
    else
      echo "Add this to your shell profile:"
      echo "  export PATH=\"$INSTALL_DIR:\$PATH\""
    fi
  fi

  echo "Run: relampo version"
}

fetch_url() {
  if need_cmd curl; then
    curl -fsSL "$1"
    return 0
  fi
  if need_cmd wget; then
    wget -qO- "$1"
    return 0
  fi
  echo "Error: curl or wget is required." >&2
  return 1
}

download_url() {
  if need_cmd curl; then
    curl -fsSL -o "$2" "$1"
    return 0
  fi
  if need_cmd wget; then
    wget -qO "$2" "$1"
    return 0
  fi
  echo "Error: curl or wget is required." >&2
  return 1
}

detect_os() {
  os="$(uname -s | tr '[:upper:]' '[:lower:]')"
  case "$os" in
    darwin) echo "darwin" ;;
    linux) echo "linux" ;;
    msys*|mingw*|cygwin*) echo "windows" ;;
    *) return 1 ;;
  esac
}

detect_arch() {
  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64) echo "amd64" ;;
    arm64|aarch64) echo "arm64" ;;
    *) return 1 ;;
  esac
}

os="$(detect_os)" || { echo "Unsupported OS: $(uname -s)" >&2; exit 1; }
arch="$(detect_arch)" || { echo "Unsupported architecture: $(uname -m)" >&2; exit 1; }

if [ -n "$RELAMPO_VERSION" ] && [ -z "$RELAMPO_TAG" ]; then
  case "$RELAMPO_VERSION" in
    v*)
      RELAMPO_TAG="$RELAMPO_VERSION"
      RELAMPO_VERSION="${RELAMPO_VERSION#v}"
      ;;
  esac
fi

if [ -z "$INSTALL_DIR" ]; then
  if [ -w "/usr/local/bin" ]; then
    INSTALL_DIR="/usr/local/bin"
  else
    INSTALL_DIR="$HOME/.local/bin"
  fi
fi

if [ "$os" = "windows" ]; then
  BIN_NAME="relampo.exe"
  archive_ext="zip"
  ext=".exe"
else
  archive_ext="tar.gz"
  ext=""
fi

if [ -z "$RELAMPO_LOCAL_DIR" ]; then
  for candidate in "$SCRIPT_DIR/dist" "$SCRIPT_DIR/../dist" "$SCRIPT_DIR/../ops/dist"; do
    if [ -f "$candidate/relampo_${os}_${arch}${ext}" ]; then
      RELAMPO_LOCAL_DIR="$candidate"
      break
    fi
  done
fi

if [ -n "$RELAMPO_LOCAL_DIR" ]; then
  local_bin="$RELAMPO_LOCAL_DIR/relampo_${os}_${arch}${ext}"
  if [ -f "$local_bin" ]; then
    install_bin "$local_bin"
    exit 0
  fi
fi

if [ -z "$RELAMPO_URL" ]; then
  if [ -z "$RELAMPO_TAG" ]; then
    if [ -z "$RELAMPO_VERSION" ]; then
      latest_url="$(default_latest_url)"
      latest_version="$(fetch_url "$latest_url" 2>/dev/null | tr -d ' \t\r\n')"
      if [ -n "$latest_version" ]; then
        RELAMPO_VERSION="$latest_version"
        RELAMPO_TAG="v$RELAMPO_VERSION"
      else
        api_url="https://api.github.com/repos/$REPO/releases/latest"
        latest_json="$(fetch_url "$api_url")"
        RELAMPO_TAG="$(printf "%s" "$latest_json" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)"
        if [ -z "$RELAMPO_TAG" ]; then
          echo "Error: unable to detect latest release tag." >&2
          exit 1
        fi
        RELAMPO_VERSION="${RELAMPO_TAG#v}"
      fi
    else
      if [ -z "$RELAMPO_BASE_URL" ]; then
        for candidate in "v$RELAMPO_VERSION" "$RELAMPO_VERSION"; do
          if fetch_url "https://api.github.com/repos/$REPO/releases/tags/$candidate" >/dev/null 2>&1; then
            RELAMPO_TAG="$candidate"
            break
          fi
        done
      fi
      if [ -z "$RELAMPO_TAG" ]; then
        RELAMPO_TAG="$RELAMPO_VERSION"
      fi
    fi
  fi

  if [ -z "$RELAMPO_VERSION" ]; then
    RELAMPO_VERSION="${RELAMPO_TAG#v}"
  fi

  archive_name="relampo_${RELAMPO_VERSION}_${os}_${arch}.${archive_ext}"
  if [ -z "$RELAMPO_BASE_URL" ]; then
    # Derive the versioned folder from the resolved version under the channel
    # root. RELAMPO_BASE_ROOT_URL lets the develop channel point this at its own
    # root so the folder always matches the version resolved from latest.txt;
    # the default reproduces the production location exactly.
    RELAMPO_BASE_URL="${RELAMPO_BASE_ROOT_URL:-https://dl.relampo.com/relampo}/v${RELAMPO_VERSION}"
  fi

  if [ -n "$RELAMPO_BASE_URL" ]; then
    RELAMPO_URL="${RELAMPO_BASE_URL%/}/$archive_name"
  else
    RELAMPO_URL="https://github.com/$REPO/releases/download/$RELAMPO_TAG/$archive_name"
  fi
fi

tmpdir="$(mktemp -d 2>/dev/null || mktemp -d -t relampo)"
cleanup() {
  rm -rf "$tmpdir"
}
trap cleanup EXIT

archive_path="$tmpdir/relampo.$archive_ext"
if ! download_url "$RELAMPO_URL" "$archive_path"; then
  echo "Error: failed to download $RELAMPO_URL" >&2
  exit 1
fi

mkdir -p "$tmpdir/unpack"
if [ "$archive_ext" = "zip" ]; then
  if ! need_cmd unzip; then
    echo "Error: unzip is required to install zip archives." >&2
    exit 1
  fi
  unzip -q "$archive_path" -d "$tmpdir/unpack"
else
  tar -xzf "$archive_path" -C "$tmpdir/unpack"
fi

bin_path="$(find "$tmpdir/unpack" -type f -name "$BIN_NAME" | head -n 1)"
if [ -z "$bin_path" ]; then
  echo "Error: could not find $BIN_NAME in archive." >&2
  exit 1
fi

install_bin "$bin_path"
