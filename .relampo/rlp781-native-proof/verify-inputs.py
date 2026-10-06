#!/usr/bin/env python3
"""Check public proof provenance and safely extract one exact worker."""
import hashlib
import json
import os
import pathlib
import platform
import re
import shutil
import tarfile

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

assert platform.system() == "Linux" and platform.machine() == "x86_64"
assert os.environ["GITHUB_REPOSITORY"] == "alambertt/relampo_testing-distribute"
assert os.environ["GITHUB_REF"].startswith("refs/heads/RLP-781-native-proof-")
assert os.environ["GITHUB_RUN_ATTEMPT"] == "1", "Use a fresh original proof run"
assert re.fullmatch(r"[A-Za-z0-9-]{1,64}", os.environ["PROOF_ID"])
root = pathlib.Path(os.environ["RLP781_PAYLOAD_ROOT"]).resolve()
for key in ("PROOF_MANIFEST_SHA256", "PROOF_ARCHIVE_SHA256", "PROOF_BINARY_SHA256"):
    assert re.fullmatch(r"[a-f0-9]{64}", os.environ[key]), key
manifest_path = root / "manifest.json"
assert digest(manifest_path) == os.environ["PROOF_MANIFEST_SHA256"]
manifest = json.loads(manifest_path.read_text())
assert manifest["schema_version"] == 1
assert manifest["proof_id"] == os.environ["PROOF_ID"]
assert manifest["producer_frozen"] is True and manifest["public_file_review_complete"] is True
assert manifest["expected_worker_version"] == "0.0.0-next"
for key in ("backend_source_sha", "worker_source_sha"):
    assert re.fullmatch(r"[a-f0-9]{40}", manifest[key]), key
assert manifest["worker_binary_sha256"] == os.environ["PROOF_BINARY_SHA256"]
assert manifest["worker_archive_sha256"] == os.environ["PROOF_ARCHIVE_SHA256"]
packaging = root / "packaging"
expected_files = set()
for item in manifest["files"]:
    name = item["path"]
    relative = pathlib.PurePosixPath(name)
    assert not relative.is_absolute() and ".." not in relative.parts
    assert not any(part in (".git", "node_modules", "editor", "internal") for part in relative.parts)
    assert relative.suffix not in (".go", ".mod", ".sum")
    assert re.fullmatch(r"[a-f0-9]{64}", item["sha256"])
    path = packaging / relative
    assert path.is_file() and not path.is_symlink()
    assert oct(path.stat().st_mode & 0o777) == item['mode'], 'File mode differs: ' + name
    path.resolve().relative_to(packaging.resolve())
    assert name not in expected_files
    expected_files.add(name)
    assert digest(path) == item["sha256"], name
actual_files = set()
for path in packaging.rglob("*"):
    assert not path.is_symlink(), str(path)
    if path.is_file():
        actual_files.add(path.relative_to(packaging).as_posix())
assert actual_files == expected_files, "Unlisted or missing packaging files"
assert manifest["stable_fixture_path"] in expected_files
assert ".goreleaser.yaml" in expected_files
archive = root / "input/relampo-worker.tar.gz"
assert digest(archive) == os.environ["PROOF_ARCHIVE_SHA256"]
worker_dir = root / "verified-input"
worker_dir.mkdir(exist_ok=False)
worker = worker_dir / "relampo-worker"
with tarfile.open(archive, "r:gz") as packed:
    members = packed.getmembers()
    assert len(members) == 1 and members[0].name == "relampo-worker" and members[0].isfile()
    with packed.extractfile(members[0]) as source, worker.open("xb") as target:
        shutil.copyfileobj(source, target)
assert digest(worker) == os.environ["PROOF_BINARY_SHA256"]
worker.chmod(0o700)
print("Native inputs verified. No worker command or provider mutation was performed.")
