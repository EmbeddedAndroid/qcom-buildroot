#!/usr/bin/env python3
"""Select laptop source snapshots after repo sync in an isolated CIL workspace."""
import json
from pathlib import Path
import subprocess
import sys

board, workspace, bundles = sys.argv[1:]
pins = json.loads(Path(__file__).with_name("sources.json").read_text())[board]
for component, pin in pins.items():
    repo = Path(workspace) / component
    bundle = Path(bundles) / (pin["source"] + ".bundle")
    subprocess.run(["git", "-C", str(repo), "fetch", "-q", str(bundle),
                    "integration-20261005-sr"], check=True)
    actual = subprocess.check_output(["git", "-C", str(repo), "rev-parse",
                                      "FETCH_HEAD"], text=True).strip()
    if actual != pin["revision"]:
        raise SystemExit(f"{component}: bundle revision mismatch")
    subprocess.run(["git", "-C", str(repo), "checkout", "-q", "--detach",
                    actual], check=True)
    print(f"SOURCE {component} {actual}", flush=True)
