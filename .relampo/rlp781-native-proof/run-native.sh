#!/usr/bin/env bash
set -euo pipefail
test "$(uname -s)" = Linux
test "$(uname -m)" = x86_64
cd "$RLP781_PAYLOAD_ROOT"
export RLP781_PAYLOAD_ROOT="$PWD"
mkdir -p proof-output
python3 - <<'PY'
import json, os, pathlib, platform
keys = ('PROOF_ID', 'PROOF_MANIFEST_SHA256', 'PROOF_ARCHIVE_SHA256', 'PROOF_BINARY_SHA256',
        'GITHUB_REPOSITORY', 'GITHUB_SHA', 'GITHUB_REF', 'GITHUB_RUN_ID', 'GITHUB_RUN_ATTEMPT')
context = {key: os.environ.get(key) for key in keys}
context['native_system'] = platform.system()
context['native_machine'] = platform.machine()
pathlib.Path('proof-output/input-context.json').write_text(json.dumps(context, sort_keys=True, indent=2) + '\n')
PY
python3 verify-inputs.py 2>&1 | tee proof-output/input-verification.log
mkdir proof-bin
cp compiler-copy.py proof-bin/precompiled-tool
cp aws-local.py proof-bin/aws
chmod +x proof-bin/precompiled-tool proof-bin/aws
export RLP781_PROOF_ROOT="$PWD"
export RLP781_PRECOMPILED_WORKER="$PWD/verified-input/relampo-worker"
export RLP781_BINARY_SHA256="$PROOF_BINARY_SHA256"
export RLP781_COMPILER_LOG="$PWD/proof-output/compiler.jsonl"
export RLP781_UPLOAD_LOG="$PWD/proof-output/uploads.jsonl"
export RLP781_COPY_TOOL="$PWD/proof-bin/precompiled-tool"
export PATH="$PWD/proof-bin:$PATH"
test "$(command -v aws)" = "$PWD/proof-bin/aws"
export GOPROXY=off GOSUMDB=off GOTOOLCHAIN=local
export GORELEASER_CURRENT_TAG=v0.0.0
export RELAMPO_GO_TOOL="$RLP781_COPY_TOOL"
export RELAMPO_DEV_VERSION=0.0.0-next
export RELAMPO_DEV_BUILD_DIR="$PWD/proof-output/develop-build"
export RELAMPO_DEV_STAGING_DIR="$PWD/proof-output/develop-staging"
export RELAMPO_BINARIES=relampo-worker RELAMPO_TARGETS=linux/amd64
export RELAMPO_EMBED_UI=0 RELAMPO_AWS_PROFILE=
fixture=$(python3 -c 'import json; print(json.load(open("manifest.json"))["stable_fixture_path"])')
cd packaging
# Synthetic metadata only. Never copy the backend module or private source.
test ! -e go.mod && test ! -e go.sum
printf 'module proof.invalid/rlp781\n\ngo 1.23.0\n' > go.mod
goreleaser --version > "$RLP781_PAYLOAD_ROOT/proof-output/goreleaser-version.txt"
grep -F '2.14.3' "$RLP781_PAYLOAD_ROOT/proof-output/goreleaser-version.txt"
goreleaser check "$fixture"
timeout 300s goreleaser release --snapshot --skip=before,sign --clean --parallelism=1 --timeout=4m --config "$fixture" 2>&1 | tee "$RLP781_PAYLOAD_ROOT/proof-output/stable.log"
(cd dist && sha256sum -c checksums.txt)
timeout 120s ./scripts/publish-develop-release.sh 2>&1 | tee "$RLP781_PAYLOAD_ROOT/proof-output/develop.log"
(cd "$RELAMPO_DEV_STAGING_DIR" && sha256sum -c checksums.txt)
cd "$RLP781_PAYLOAD_ROOT"
timeout 90s python3 run-negatives.py
python3 assert-output.py
