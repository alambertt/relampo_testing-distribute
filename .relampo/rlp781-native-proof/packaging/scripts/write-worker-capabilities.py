#!/usr/bin/env python3
"""Certify the exact final worker. This command never starts load."""
import hashlib
import json
import os
import pathlib
import subprocess
import sys
import tempfile


def unique_object(pairs):
    value = {}
    for key, item in pairs:
        if key in value:
            raise ValueError("duplicate capability field")
        value[key] = item
    return value


def invalid_constant(_):
    raise ValueError("invalid JSON constant")


def main():
    binary, target_os, arch, output, version = sys.argv[1:]
    if (target_os, arch) != ("linux", "amd64"):
        return
    system = subprocess.check_output(["uname", "-s"], timeout=5).strip()
    machine = subprocess.check_output(["uname", "-m"], timeout=5).strip()
    if system != b"Linux" or machine not in (b"x86_64", b"amd64"):
        raise ValueError("Linux/amd64 worker receipt requires a native Linux/amd64 host")
    path = pathlib.Path(binary).resolve(strict=True)
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    probe = subprocess.run([str(path), "--capabilities"], capture_output=True, check=True, timeout=15)
    if len(probe.stdout) > 1048576:
        raise ValueError("capability output exceeds the receipt limit")
    body = probe.stdout.strip()
    capabilities = json.loads(body.decode("utf-8"), object_pairs_hook=unique_object, parse_constant=invalid_constant)
    if not isinstance(capabilities, dict) or type(capabilities.get("schema_version")) is not int or capabilities["schema_version"] != 1:
        raise ValueError("invalid capability schema")
    if not version or capabilities.get("version") != version:
        raise ValueError("worker capability version differs from the packaged version")
    if type(capabilities.get("execution_manifest_version")) is not int or capabilities["execution_manifest_version"] != 1:
        raise ValueError("invalid execution manifest capability")
    for flag in ("multi_scenario_parallel", "multi_scenario_phase", "multi_scenario_authorization", "multi_scenario_resolved_load_contract"):
        if type(capabilities.get(flag)) is not bool:
            raise ValueError("missing or invalid worker capability")
    if hashlib.sha256(path.read_bytes()).hexdigest() != digest:
        raise ValueError("worker bytes changed during the capability probe")
    # Preserve the actual complete JSON body, including unknown and false fields.
    receipt = (b'{"schema_version":1,"os":"linux","arch":"amd64","binary_sha256":"'
               + digest.encode("ascii") + b'","capabilities":' + body + b'}\n')
    destination = pathlib.Path(output)
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(dir=destination.parent, prefix=".worker-receipt-", delete=False) as file:
            temporary = pathlib.Path(file.name)
            file.write(receipt)
        os.replace(temporary, destination)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, subprocess.SubprocessError):
        sys.exit("worker capability receipt failed; verify native host, final binary, version and capability output")
