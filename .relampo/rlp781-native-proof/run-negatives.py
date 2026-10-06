#!/usr/bin/env python3
"""Native no-load negatives against the actual frozen production producer."""
import hashlib
import json
import os
import pathlib
import platform
import subprocess
import sys

assert platform.system() == 'Linux' and platform.machine() == 'x86_64'
root = pathlib.Path(os.environ['RLP781_PAYLOAD_ROOT']).resolve()
packaging = root / 'packaging'
producer = packaging / 'scripts/write-worker-capabilities.py'
worker = root / 'verified-input/relampo-worker'
assert hashlib.sha256(worker.read_bytes()).hexdigest() == os.environ['PROOF_BINARY_SHA256']
base = root / 'proof-output/negatives'
base.mkdir(exist_ok=False)
results = []
flags = ('multi_scenario_parallel', 'multi_scenario_phase', 'multi_scenario_authorization',
         'multi_scenario_resolved_load_contract')

def record(name, status, detail=None):
    item = {'case': name, 'status': status}
    if detail:
        item['detail'] = detail
    results.append(item)
    (root / 'proof-output/negative-results.json').write_text(json.dumps(results, indent=2) + '\n')

def execute(command, folder, env=None, timeout=30):
    (folder / 'command.json').write_text(json.dumps(command) + '\n')
    try:
        result = subprocess.run(command, cwd=packaging, env=env, capture_output=True,
                                timeout=timeout, check=False)
    except subprocess.TimeoutExpired as failure:
        (folder / 'stdout').write_bytes(failure.stdout or b'')
        (folder / 'stderr').write_bytes(failure.stderr or b'')
        raise AssertionError('Case timed out; raw output retained')
    (folder / 'stdout').write_bytes(result.stdout)
    (folder / 'stderr').write_bytes(result.stderr)
    (folder / 'exit.json').write_text(json.dumps({'returncode': result.returncode}) + '\n')
    return result

def fixture(folder, mode):
    path = folder / 'negative-worker.py'
    body = "#!/usr/bin/env python3\nimport pathlib,sys\nassert sys.argv[1:] == ['--capabilities']\n"
    if mode == 'invalid':
        body += "print('INVALID_JSON_NEGATIVE_FIXTURE')\n"
    elif mode == 'failure':
        body += "sys.exit(7)\n"
    elif mode == 'sentinel':
        body += 'pathlib.Path(' + repr(str(folder / 'executed.marker')) + ").write_text('executed')\nsys.exit(7)\n"
    elif mode != 'empty':
        raise AssertionError('Unsupported negative fixture')
    path.write_text(body)
    path.chmod(0o700)
    return path

def run_case(name, callback):
    folder = base / name
    folder.mkdir()
    try:
        callback(folder)
    except Exception as failure:
        record(name, 'FAILED', str(failure))
        raise
    record(name, 'PASSED')

def producer_case(folder, binary, target_os='linux', arch='amd64', version='0.0.0-next', skip=False):
    receipt = folder / 'receipt.json'
    result = execute([sys.executable, str(producer), str(binary), target_os, arch,
                      str(receipt), version], folder)
    assert (result.returncode == 0) if skip else (result.returncode != 0)
    assert not receipt.exists(), 'Unexpected receipt'
    assert not (folder / 'executed.marker').exists(), 'Skipped binary executed'

def disabled_worker(folder):
    clean = {key: value for key, value in os.environ.items() if key in ('PATH', 'LANG', 'TMPDIR')}
    clean['RELAMPO_MULTI_SCENARIO_ENABLED'] = 'false'
    result = execute([str(worker), '--capabilities'], folder, env=clean, timeout=15)
    assert result.returncode == 0
    actual = json.loads(result.stdout)
    assert actual['version'] == '0.0.0-next'
    assert actual['schema_version'] == actual['execution_manifest_version'] == 1
    assert all(actual[flag] is False for flag in flags[:3]), 'Disabled actual worker still advertises multi execution'
    assert actual['multi_scenario_resolved_load_contract'] is True, 'Resolved-load evidence contract must remain supported'

run_case('disabled-actual-worker', disabled_worker)
for name, mode in (('missing-capabilities', 'empty'), ('invalid-capabilities', 'invalid'),
                   ('failed-capability-command', 'failure')):
    run_case(name, lambda folder, mode=mode: producer_case(folder, fixture(folder, mode)))
run_case('actual-worker-version-mismatch',
         lambda folder: producer_case(folder, worker, version='0.0.0-next-mismatch'))
for name, target_os, arch in (('skip-darwin-amd64', 'darwin', 'amd64'),
                              ('skip-linux-arm64', 'linux', 'arm64')):
    run_case(name, lambda folder, target_os=target_os, arch=arch:
             producer_case(folder, fixture(folder, 'sentinel'), target_os=target_os, arch=arch, skip=True))

def develop_failure(folder):
    env = dict(os.environ)
    env.update(RELAMPO_DEV_VERSION='0.0.0-next-mismatch',
               RELAMPO_DEV_BUILD_DIR=str(folder / 'build'),
               RELAMPO_DEV_STAGING_DIR=str(folder / 'staging'),
               RLP781_COMPILER_LOG=str(folder / 'compiler.jsonl'),
               RLP781_UPLOAD_LOG=str(folder / 'uploads.jsonl'))
    env.pop('GITHUB_OUTPUT', None)
    result = execute([str(packaging / 'scripts/publish-develop-release.sh')], folder, env=env)
    assert result.returncode != 0
    uploads = folder / 'uploads.jsonl'
    assert not uploads.exists() or not uploads.read_text().strip(), 'Failure allowed an upload'
    assert not (folder / 'staging/latest.txt').exists(), 'Failure created latest pointer'
    assert not list((folder / 'staging').glob('*.capabilities.json')), 'Failure wrote a receipt'
    records = [json.loads(line) for line in (folder / 'compiler.jsonl').read_text().splitlines()]
    assert len(records) == 1 and records[0]['mode'] == 'PRECOMPILED_COPY_ONLY'
    assert b'worker capability receipt failed' in result.stderr

run_case('develop-version-failure-no-uploads', develop_failure)
assert len(results) == 8 and all(item['status'] == 'PASSED' for item in results)
print('Eight real producer/worker no-load negative cases passed; all upload records remained local.')
