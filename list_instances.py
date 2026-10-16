#!/usr/bin/env python3
import json
import sys

if len(sys.argv) != 2:
    print(f"usage: {sys.argv[0]} <instances.json>", file=sys.stderr)
    sys.exit(1)

with open(sys.argv[1]) as f:
    lines = f.readlines()

data = json.loads(lines[-1])

def find_recommendations(obj):
    if isinstance(obj, dict):
        if "recommendations" in obj:
            return obj["recommendations"]
        for v in obj.values():
            result = find_recommendations(v)
            if result is not None:
                return result
    return None

recs = find_recommendations(data)
if recs is None:
    print("Error: no recommendations found", file=sys.stderr)
    sys.exit(1)

for rec in recs:
    print(rec["api_name"])
