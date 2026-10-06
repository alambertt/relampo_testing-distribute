#!/usr/bin/env sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
ROOT_DIR="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)"

CHANNEL="${RELAMPO_CHANNEL:-internal}"
OUT_DIR="${RELAMPO_OUT_DIR:-$ROOT_DIR/ops/$CHANNEL}"
TARGETS="${RELAMPO_TARGETS:-darwin/amd64 darwin/arm64 linux/amd64 linux/arm64 windows/amd64 windows/arm64}"
# Default user-facing builds ship the CLI and distributed worker.
BINARIES="${RELAMPO_BINARIES:-relampo relampo-worker}"
GO_TOOL="${RELAMPO_GO_TOOL:-go}"

if ! command -v go >/dev/null 2>&1; then
  echo "Error: go is required." >&2
  exit 1
fi

VERSION="${RELAMPO_VERSION:-}"
COMMIT="${RELAMPO_COMMIT:-}"
DATE="${RELAMPO_DATE:-}"
UPDATE_BASE_URL="${RELAMPO_UPDATE_BASE_URL:-}"
UPDATE_LATEST_URL="${RELAMPO_UPDATE_LATEST_URL:-}"
STUDIO_STATSIG_CLIENT_KEY="${STUDIO_STATSIG_CLIENT_KEY:-}"
STUDIO_CATALOG_PUBLIC_KEY="${STUDIO_CATALOG_PUBLIC_KEY:-}"
STUDIO_CATALOG_KEY_ID="${STUDIO_CATALOG_KEY_ID:-}"
STUDIO_RELEASE_CHANNEL="${RELAMPO_STUDIO_RELEASE_CHANNEL:-stable}"
EMBEDDED_EDITOR_VERSION="${EMBEDDED_EDITOR_VERSION:-}"

if [ -z "$EMBEDDED_EDITOR_VERSION" ] && [ -f "$ROOT_DIR/EDITOR_VERSION" ]; then
  EMBEDDED_EDITOR_VERSION="$(tr -d '[:space:]' < "$ROOT_DIR/EDITOR_VERSION")"
fi

if command -v git >/dev/null 2>&1; then
  if git -C "$ROOT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    if [ -z "$VERSION" ]; then
      VERSION="$(git -C "$ROOT_DIR" describe --tags --abbrev=0 --match 'v*' 2>/dev/null || true)"
      if [ -z "$VERSION" ]; then
        VERSION="$(git -C "$ROOT_DIR" describe --tags --abbrev=0 2>/dev/null || true)"
      fi
      VERSION="${VERSION#v}"
    fi
    if [ -z "$COMMIT" ]; then
      COMMIT="$(git -C "$ROOT_DIR" rev-parse --short HEAD 2>/dev/null || true)"
    fi
  fi
fi

if [ -z "$VERSION" ]; then
  VERSION="dev"
fi

if [ -z "$DATE" ] && command -v date >/dev/null 2>&1; then
  DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
fi

case "$CHANNEL" in
  internal)
    TOOL="$GO_TOOL"
    TAGS=""
    LDFLAGS="-s -w"
    if [ -n "$VERSION" ]; then
      LDFLAGS="$LDFLAGS -X main.version=$VERSION"
    fi
    if [ -n "$COMMIT" ]; then
      LDFLAGS="$LDFLAGS -X main.commit=$COMMIT"
    fi
    if [ -n "$DATE" ]; then
      LDFLAGS="$LDFLAGS -X main.date=$DATE"
    fi
    ;;
  dist)
    TOOL="$GO_TOOL"
    TAGS="dist"
    LDFLAGS="-s -w"
    if [ -n "$VERSION" ]; then
      LDFLAGS="$LDFLAGS -X main.version=$VERSION"
    fi
    ;;
  *)
    echo "Error: unsupported RELAMPO_CHANNEL '$CHANNEL' (expected internal or dist)." >&2
    exit 1
    ;;
esac

if [ -n "$UPDATE_BASE_URL" ]; then
  LDFLAGS="$LDFLAGS -X main.defaultUpdateBaseURL=$UPDATE_BASE_URL"
fi
if [ -n "$UPDATE_LATEST_URL" ]; then
  LDFLAGS="$LDFLAGS -X main.defaultUpdateLatestURL=$UPDATE_LATEST_URL"
fi
if [ -n "$STUDIO_STATSIG_CLIENT_KEY" ]; then
  LDFLAGS="$LDFLAGS -X main.studioStatsigClientKey=$STUDIO_STATSIG_CLIENT_KEY"
fi
if [ -n "$STUDIO_CATALOG_PUBLIC_KEY" ]; then
  LDFLAGS="$LDFLAGS -X main.studioCatalogPublicKey=$STUDIO_CATALOG_PUBLIC_KEY"
fi
if [ -n "$STUDIO_CATALOG_KEY_ID" ]; then
  LDFLAGS="$LDFLAGS -X main.studioCatalogKeyID=$STUDIO_CATALOG_KEY_ID"
fi
if [ -n "$EMBEDDED_EDITOR_VERSION" ]; then
  LDFLAGS="$LDFLAGS -X main.embeddedEditorVersion=$EMBEDDED_EDITOR_VERSION"
fi
LDFLAGS="$LDFLAGS -X main.studioReleaseChannel=$STUDIO_RELEASE_CHANNEL"

resolve_package() {
  case "$1" in
    relampo)
      printf '%s\n' "./cmd/relampo"
      ;;
    relampo-worker)
      printf '%s\n' "./cmd/relampo-worker"
      ;;
    *)
      echo "Error: unsupported binary '$1'." >&2
      exit 1
      ;;
  esac
}

mkdir -p "$OUT_DIR"

for bin in $BINARIES; do
  pkg="$(resolve_package "$bin")"
  # Only the `relampo` CLI embeds the editor UI, and only when RELAMPO_EMBED_UI
  # is set (releases set it after scripts/fetch-editor-dist.sh has populated the
  # embed dir). The worker never embeds it; plain dev/test builds leave the flag
  # unset and use the no-UI stub, so it needs no editor dist.
  bin_tags="$TAGS"
  if [ "$bin" = "relampo" ] && [ "${RELAMPO_EMBED_UI:-}" = "1" ]; then
    if [ -n "$bin_tags" ]; then
      bin_tags="$bin_tags embedui"
    else
      bin_tags="embedui"
    fi
  fi
  for target in $TARGETS; do
    os="${target%/*}"
    arch="${target#*/}"
    ext=""
    if [ "$os" = "windows" ]; then
      ext=".exe"
    fi
    out="$OUT_DIR/${bin}_${os}_${arch}${ext}"
    echo "Building [$CHANNEL] $bin $os/$arch -> $out"
    set -- build -trimpath -buildvcs=false
    if [ -n "$bin_tags" ]; then
      set -- "$@" -tags "$bin_tags"
    fi
    set -- "$@" -ldflags "$LDFLAGS" -o "$out" "$pkg"
    (
      cd "$ROOT_DIR" &&
      env CGO_ENABLED=0 GOOS="$os" GOARCH="$arch" "$TOOL" "$@"
    )
  done
done

echo "Done. Channel '$CHANNEL' artifacts in $OUT_DIR"
