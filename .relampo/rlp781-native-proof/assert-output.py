#!/usr/bin/env python3
"""Compare real native producer output with exact precompiled worker bytes."""
import hashlib
import json
import os
import pathlib
import re
import subprocess
import tarfile

root = pathlib.Path(os.environ["RLP781_PAYLOAD_ROOT"]).resolve()
packaging = root / "packaging"
output = root / "proof-output"
worker = root / "verified-input/relampo-worker"
expected = os.environ["PROOF_BINARY_SHA256"]
clean_env = {key: value for key, value in os.environ.items() if key in ("PATH", "LANG", "TMPDIR")}
try:
    actual = subprocess.run([str(worker), "--capabilities"], cwd=worker.parent, env=clean_env,
                            capture_output=True, timeout=15, check=False)
except subprocess.TimeoutExpired as failure:
    (output / 'worker-capabilities.stdout').write_bytes(failure.stdout or b'')
    (output / 'worker-capabilities.stderr').write_bytes(failure.stderr or b'')
    raise SystemExit('Actual worker capability timeout; partial raw output retained')
(output / 'worker-capabilities.stdout').write_bytes(actual.stdout)
(output / 'worker-capabilities.stderr').write_bytes(actual.stderr)
assert actual.returncode == 0, 'Actual worker --capabilities failed; raw output retained'
assert len(actual.stdout) <= 65536
capabilities = json.loads(actual.stdout)
assert capabilities["version"] == "0.0.0-next"
assert capabilities["schema_version"] == capabilities["execution_manifest_version"] == 1
for flag in ("multi_scenario_parallel", "multi_scenario_phase", "multi_scenario_authorization", "multi_scenario_resolved_load_contract"):
    assert capabilities[flag] is True, flag

def verify_stage(stage, allow_develop_self_entry=False):
    receipt_name = "relampo-worker_linux_amd64.capabilities.json"
    receipt_path = stage / receipt_name
    receipt = json.loads(receipt_path.read_text())
    assert (receipt['schema_version'], receipt['os'], receipt['arch']) == (1, 'linux', 'amd64')
    assert receipt['binary_sha256'] == expected and receipt['capabilities'] == capabilities
    entries = {}
    validated = []
    self_entry = None
    for line in (stage / 'checksums.txt').read_text().splitlines():
        checksum, name = line.split(maxsplit=1)
        name = name.removeprefix('*')
        assert re.fullmatch(r'[a-f0-9]{64}', checksum), 'Invalid checksum digest'
        relative = pathlib.PurePosixPath(name)
        assert not relative.is_absolute() and '..' not in relative.parts
        assert relative.as_posix() == name, 'Noncanonical checksum path'
        assert name not in entries
        entries[name] = checksum
        path = stage / relative
        path.resolve().relative_to(stage.resolve())
        assert path.is_file() and not path.is_symlink(), 'Invalid checksum payload path'
        if allow_develop_self_entry and name == 'checksums.txt':
            assert checksum == hashlib.sha256(b'').hexdigest(), 'Unexpected baseline self-entry digest'
            self_entry = {'path': name, 'recorded_sha256': checksum,
                          'actual_file_sha256': hashlib.sha256(path.read_bytes()).hexdigest(),
                          'status': 'PREEXISTING_SELF_ENTRY_RETAINED_NOT_VALIDATED'}
        else:
            assert hashlib.sha256(path.read_bytes()).hexdigest() == checksum, name
            validated.append(name)
    if allow_develop_self_entry:
        assert self_entry is not None, 'Missing expected baseline self-entry'
        detail = {'validated_payloads': validated, 'excluded_sole_self_entry': self_entry,
                  'raw_inventory_sha256': hashlib.sha256((stage / 'checksums.txt').read_bytes()).hexdigest()}
        (output / 'develop-checksum-validation.json').write_text(json.dumps(detail, indent=2) + '\n')
        print('Develop checksums: every listed payload verified; sole baseline checksums.txt self-entry retained and not validated.')
    assert entries[receipt_name] == hashlib.sha256(receipt_path.read_bytes()).hexdigest()
    archive_name = 'relampo-worker_0.0.0-next_linux_amd64.tar.gz'
    archive = stage / archive_name
    assert entries[archive_name] == hashlib.sha256(archive.read_bytes()).hexdigest()
    with tarfile.open(archive) as packed:
        members = [m for m in packed.getmembers() if m.isfile() and pathlib.PurePosixPath(m.name).name == 'relampo-worker']
        assert len(members) == 1
        assert hashlib.sha256(packed.extractfile(members[0]).read()).hexdigest() == expected
    return {'receipt_sha256': hashlib.sha256(receipt_path.read_bytes()).hexdigest(),
            'archive_sha256': hashlib.sha256(archive.read_bytes()).hexdigest()}

stable = verify_stage(packaging / 'dist')
develop = verify_stage(output / 'develop-staging', allow_develop_self_entry=True)
uploads = [json.loads(line) for line in (output / 'uploads.jsonl').read_text().splitlines()]
assert uploads[-1][3].endswith('/relampo/latest.txt')
for name in ('relampo-worker_linux_amd64.capabilities.json', 'checksums.txt', 'relampo-worker_0.0.0-next_linux_amd64.tar.gz'):
    assert sum(a[3].endswith('/' + name) for a in uploads[:-1]) == 1, name
compilers = [json.loads(line) for line in (output / 'compiler.jsonl').read_text().splitlines()]
assert len(compilers) == 2
assert all(entry['mode'] == 'PRECOMPILED_COPY_ONLY' and entry['sha256'] == expected for entry in compilers)
manifest = json.loads((root / 'manifest.json').read_text())
negatives = json.loads((output / 'negative-results.json').read_text())
assert len(negatives) == 8 and all(item['status'] == 'PASSED' for item in negatives)
evidence = {'schema_version': 1, 'status': 'NATIVE_PACKAGING_PROOF_ONLY',
            'worker_sha256': expected, 'worker_version': capabilities['version'],
            'stable': stable, 'develop': develop, 'manifest': manifest, 'negative_cases': negatives,
            'repository': os.environ['GITHUB_REPOSITORY'], 'source_sha': os.environ['GITHUB_SHA'],
            'run_id': os.environ['GITHUB_RUN_ID'], 'run_attempt': os.environ['GITHUB_RUN_ATTEMPT'],
            'native_private_go_compilation_proven': False, 'official_publication_performed': False}
(output / 'evidence.json').write_text(json.dumps(evidence, indent=2, sort_keys=True) + '\n')
(output / 'actual-capabilities.json').write_text(json.dumps(capabilities, sort_keys=True) + '\n')
print('Actual receipts, archives, checksums and intended upload order agree. Compiler used precompiled copies only.')
