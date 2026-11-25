"""Add the fixture root to the SDK's already-resolved dependency report."""

import json
import sys
from pathlib import Path

source, destination, name = sys.argv[1:]
data = json.loads(Path(source).read_text())
for package in data["packages"]:
    if package["source"] == "root":
        package["source"] = "sdk"
        package["kind"] = "direct"
data["root"] = name
data["packages"].append({
    "name": name,
    "version": "1.0.0",
    "source": "root",
    "kind": "root",
    "dependencies": ["flutter", "flutter_test"],
})
Path(destination).write_text(json.dumps(data))
