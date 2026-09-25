#!/usr/bin/env python3
# dsp-runtime-check.py <dsp-binaries> <firmware.mbn>:<runtime dir>...
# Fails unless every Hexagon binary in each runtime directory is authorised
# by the signed DSP firmware that will load it. A DSP refuses a fastrpc_shell
# or skel whose segment hashes its firmware does not carry, so a runtime from
# another firmware build fails only at run time on the board. The check is
# check_hashes() from dsp-binaries scripts/checkfw.py; its sibling module
# check.py (config validation, needing yaml and jsonschema) is not used.
import os
import sys
import types

sys.modules["check"] = types.SimpleNamespace(load_config=None)
sys.path.insert(0, os.path.join(sys.argv[1], "scripts"))
from checkfw import check_hashes, segment_hashes  # noqa: E402

ok = True
for pair in sys.argv[2:]:
    fw, rt = pair.split(":", 1)
    elves = [f for f in sorted(os.listdir(rt))
             if os.path.isfile(os.path.join(rt, f)) and
             segment_hashes(open(os.path.join(rt, f), "rb").read())]
    if not elves:
        print(f"{rt}: no Hexagon binaries")
        ok = False
    elif check_hashes(fw, rt):
        print(f"{rt}: {len(elves)} binaries authorised by {fw}")
    else:
        ok = False
sys.exit(0 if ok else 1)
