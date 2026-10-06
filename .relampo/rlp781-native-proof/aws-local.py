#!/usr/bin/env python3
"""Proof fixture: record upload arguments locally; never invoke AWS."""
import json
import os
import pathlib
import sys

args = sys.argv[1:]
assert len(args) >= 4 and args[:2] == ["s3", "cp"], "Only local upload records are allowed"
source = pathlib.Path(args[2]).resolve()
source.relative_to(pathlib.Path(os.environ["RLP781_PROOF_ROOT"]).resolve())
assert source.is_file() and args[3].startswith("s3://")
with open(os.environ["RLP781_UPLOAD_LOG"], "a") as log:
    log.write(json.dumps(args) + "\n")
