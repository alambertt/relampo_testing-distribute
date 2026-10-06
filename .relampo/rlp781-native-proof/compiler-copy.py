#!/usr/bin/env python3
"""Proof fixture: copy verified bytes; never compile or execute the worker."""
import hashlib
import json
import os
import pathlib
import shutil
import sys

args = sys.argv[1:]
assert args and args[0] == "build", "Only a build invocation is allowed"
assert os.environ.get("GOOS") == "linux" and os.environ.get("GOARCH") == "amd64"
assert os.environ.get("CGO_ENABLED") == "0"
assert args[-1] == "./cmd/relampo-worker"
assert args.count("-o") == 1
output = pathlib.Path(args[args.index("-o") + 1]).resolve()
output.relative_to(pathlib.Path(os.environ["RLP781_PROOF_ROOT"]).resolve())
source = pathlib.Path(os.environ["RLP781_PRECOMPILED_WORKER"]).resolve()
expected = os.environ["RLP781_BINARY_SHA256"]
assert hashlib.sha256(source.read_bytes()).hexdigest() == expected
output.parent.mkdir(parents=True, exist_ok=True)
shutil.copyfile(source, output)
output.chmod(0o700)
assert hashlib.sha256(output.read_bytes()).hexdigest() == expected
with open(os.environ["RLP781_COMPILER_LOG"], "a") as log:
    log.write(json.dumps({"mode": "PRECOMPILED_COPY_ONLY", "args": args,
                          "sha256": expected, "output": str(output)}) + "\n")
