#!/usr/bin/env sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
ROOT_DIR="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)"

PROFILE="${RELAMPO_AWS_PROFILE:-}"
BUCKET="${RELAMPO_DOWNLOADS_BUCKET:-relampo-downloads-616250100969-20260201142308}"
AWS_REGION="${AWS_REGION:-us-east-2}"
DEV_CHANNEL="${RELAMPO_DEV_CHANNEL:-develop}"
# DEV_VERSION is computed below (date-based, autoincrement per day) unless the
# caller pins one explicitly via RELAMPO_DEV_VERSION. DEV_PREFIX is likewise
# resolved after DEV_VERSION is known.
DEV_VERSION="${RELAMPO_DEV_VERSION:-}"
DEV_ROOT_URL="${RELAMPO_DEV_ROOT_URL:-https://d1esekpdu3hjut.cloudfront.net/$DEV_CHANNEL}"
BUILD_DIR="${RELAMPO_DEV_BUILD_DIR:-$ROOT_DIR/ops/dev-dist}"
STAGING_DIR="${RELAMPO_DEV_STAGING_DIR:-$ROOT_DIR/ops/dev-release}"
CACHE_CONTROL_MUTABLE="${RELAMPO_DEV_CACHE_CONTROL_MUTABLE:-max-age=60}"
CONTENT_TYPE_SHELL="text/x-shellscript"
CONTENT_TYPE_POWERSHELL="text/plain; charset=utf-8"
TARGETS="${RELAMPO_TARGETS:-darwin/amd64 darwin/arm64 linux/amd64 linux/arm64 windows/amd64 windows/arm64}"
# Default develop releases ship the CLI and distributed worker.
BINARIES="${RELAMPO_BINARIES:-relampo relampo-worker}"

need_cmd() {
  command -v "$1" >/dev/null 2>&1
}

if ! need_cmd aws; then
  echo "Error: aws CLI is required." >&2
  exit 1
fi

if ! need_cmd sha256sum; then
  echo "Error: sha256sum is required." >&2
  exit 1
fi

if ! need_cmd zip; then
  echo "Error: zip is required." >&2
  exit 1
fi

if [ -n "$PROFILE" ]; then
  AWS_CMD="aws --profile $PROFILE"
else
  AWS_CMD="aws"
fi

# Resolve the develop-channel version. We use a human-readable, date-based
# autoincrementing scheme — "develop-YYYY.MM.DD.N" — so every develop build has a
# distinct, sortable identity instead of the old static "develop". N restarts at
# 1 each UTC day and increments for every release published the same day. This
# lets `relampo update` and `relampo --version` show exactly which build is
# installed and whether it is behind. The format is deliberately different from
# main's semver (vX.Y.Z) so the two channels can never be confused.
if [ -z "$DEV_VERSION" ]; then
  DEV_DATE="$(date -u +%Y.%m.%d)"
  # Read the authoritative latest.txt straight from S3 (the CDN copy can be
  # cached) to discover today's highest build number.
  PREV_VERSION="$($AWS_CMD s3 cp "s3://$BUCKET/$DEV_CHANNEL/relampo/latest.txt" - --region "$AWS_REGION" 2>/dev/null | tr -d '[:space:]' || true)"
  DEV_BUILD_NUM=1
  case "$PREV_VERSION" in
    develop-"$DEV_DATE".*)
      prev_num="${PREV_VERSION##*.}"
      if printf '%s' "$prev_num" | grep -Eq '^[0-9]+$'; then
        DEV_BUILD_NUM=$((prev_num + 1))
      fi
      ;;
  esac
  DEV_VERSION="develop-${DEV_DATE}.${DEV_BUILD_NUM}"
fi

DEV_PREFIX="${RELAMPO_DEV_PREFIX:-$DEV_CHANNEL/relampo/v$DEV_VERSION}"
echo "Develop release version: $DEV_VERSION"
# Expose the computed version to GitHub Actions so the Slack notify job can
# publish it. Written early so a later build/upload failure still reports which
# version was attempted.
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  echo "version=$DEV_VERSION" >> "$GITHUB_OUTPUT"
fi

rm -rf "$BUILD_DIR" "$STAGING_DIR"
mkdir -p "$BUILD_DIR" "$STAGING_DIR"

# When embedding the editor UI, pull the pinned editor build into the embed dir
# before build-channel.sh compiles `relampo` with -tags embedui. The CI workflow
# also runs this as an explicit step; doing it here keeps manual runs correct.
if [ "${RELAMPO_EMBED_UI:-}" = "1" ]; then
  "$ROOT_DIR/scripts/fetch-editor-dist.sh"
fi

RELAMPO_CHANNEL=dist \
RELAMPO_VERSION="$DEV_VERSION" \
RELAMPO_UPDATE_BASE_URL="$DEV_ROOT_URL" \
RELAMPO_UPDATE_LATEST_URL="$DEV_ROOT_URL/relampo/latest.txt" \
RELAMPO_OUT_DIR="$BUILD_DIR" \
RELAMPO_TARGETS="$TARGETS" \
RELAMPO_BINARIES="$BINARIES" \
"$ROOT_DIR/scripts/build-channel.sh"

make_archive() {
  bin="$1"
  os="$2"
  arch="$3"

  ext=""
  archive_ext="tar.gz"
  if [ "$os" = "windows" ]; then
    ext=".exe"
    archive_ext="zip"
  fi

  src="$BUILD_DIR/${bin}_${os}_${arch}${ext}"
  if [ ! -f "$src" ]; then
    echo "Error: expected build output not found: $src" >&2
    exit 1
  fi

  archive="$STAGING_DIR/${bin}_${DEV_VERSION}_${os}_${arch}.${archive_ext}"
  tmpdir="$(mktemp -d 2>/dev/null || mktemp -d -t relampo-dev-archive)"
  trap 'rm -rf "$tmpdir"' EXIT HUP INT TERM

  cp "$src" "$tmpdir/$bin$ext"
  if [ "$bin" = "relampo-worker" ]; then
    python3 "$ROOT_DIR/scripts/write-worker-capabilities.py" "$tmpdir/$bin$ext" "$os" "$arch" "$STAGING_DIR/relampo-worker_${os}_${arch}.capabilities.json" "$DEV_VERSION"
  fi
  if [ "$archive_ext" = "zip" ]; then
    (
      cd "$tmpdir" &&
      zip -q "$archive" "$bin$ext"
    )
  else
    (
      cd "$tmpdir" &&
      tar -czf "$archive" "$bin$ext"
    )
  fi

  rm -rf "$tmpdir"
  trap - EXIT HUP INT TERM
}

for bin in $BINARIES; do
  for target in $TARGETS; do
    os="${target%/*}"
    arch="${target#*/}"
    make_archive "$bin" "$os" "$arch"
  done
done

(
  cd "$STAGING_DIR"
  for file in *; do
    sha256sum "$file"
  done > checksums.txt
)

printf '%s\n' "$DEV_VERSION" > "$STAGING_DIR/latest.txt"

# Point the generated installers at the develop channel ROOT, not at this
# build's versioned folder. Each installer resolves the current version from
# latest.txt and then derives the versioned folder as <root>/v<version>, so a
# cached/older installer still downloads from the prefix that matches whatever
# latest.txt now advertises. Pinning the versioned URL here would make a stale
# installer build <old-prefix>/relampo_<new-version>_... and 404.
DEV_BASE_ROOT_URL="$DEV_ROOT_URL/relampo"
DEV_LATEST_URL="$DEV_ROOT_URL/relampo/latest.txt"
DEV_INSTALL_SH="$STAGING_DIR/install.sh"
DEV_INSTALL_PS1="$STAGING_DIR/install.ps1"

cat > "$DEV_INSTALL_SH" <<EOF
#!/usr/bin/env sh
RELAMPO_BASE_ROOT_URL="\${RELAMPO_BASE_ROOT_URL:-$DEV_BASE_ROOT_URL}"
RELAMPO_LATEST_URL="\${RELAMPO_LATEST_URL:-$DEV_LATEST_URL}"
export RELAMPO_BASE_ROOT_URL
export RELAMPO_LATEST_URL
EOF
cat "$ROOT_DIR/install.sh" >> "$DEV_INSTALL_SH"
chmod 0755 "$DEV_INSTALL_SH"

# The PowerShell installer already appends /v<version>/<archive> when its base
# URL is a channel root (no trailing /v<...> segment), so feeding it the root is
# enough — it picks the versioned folder from the resolved version.
sed \
  -e "s|'https://dl.relampo.com/relampo'|'$DEV_BASE_ROOT_URL'|" \
  -e "s|'https://dl.relampo.com/relampo/latest.txt'|'$DEV_LATEST_URL'|" \
  "$ROOT_DIR/scripts/install-relampo.ps1" > "$DEV_INSTALL_PS1"

upload_file() {
  src="$1"
  key="$2"
  content_type="$3"
  cache_control="$4"

  # shellcheck disable=SC2086
  $AWS_CMD s3 cp "$src" "s3://$BUCKET/$key" \
    --region "$AWS_REGION" \
    --content-type "$content_type" \
    --cache-control "$cache_control" \
    --sse AES256
}

# Upload order matters: latest.txt is the discovery pointer that installers and
# `relampo update` read to learn the current version, and every build now lives
# under a unique versioned prefix. If latest.txt were published before its
# archives/checksums existed, a client could read the new version and then 404
# on the download. So we upload in three explicit phases:
#   1. versioned archives + checksums (the payload),
#   2. the installer scripts (they reference the versioned prefix above),
#   3. latest.txt LAST (only now is the advertised version fully downloadable).
# A plain glob loop would instead upload latest.txt first (alphabetically before
# the relampo_* archives), reintroducing the race.
for archive in "$STAGING_DIR"/*; do
  name="$(basename "$archive")"
  case "$name" in
    latest.txt | install.sh | install.ps1)
      continue
      ;;
    *)
      upload_file "$archive" "$DEV_PREFIX/$name" "application/octet-stream" "$CACHE_CONTROL_MUTABLE"
      ;;
  esac
done

upload_file "$STAGING_DIR/install.sh" "$DEV_CHANNEL/install.sh" "$CONTENT_TYPE_SHELL" "$CACHE_CONTROL_MUTABLE"
upload_file "$STAGING_DIR/install.ps1" "$DEV_CHANNEL/install.ps1" "$CONTENT_TYPE_POWERSHELL" "$CACHE_CONTROL_MUTABLE"

# Publish latest.txt last, once all referenced artifacts are in place.
upload_file "$STAGING_DIR/latest.txt" "$DEV_CHANNEL/relampo/latest.txt" "text/plain" "$CACHE_CONTROL_MUTABLE"

echo "Published develop artifacts to s3://$BUCKET/$DEV_PREFIX/"
echo "Developer installer URL: $DEV_ROOT_URL/install.sh"
