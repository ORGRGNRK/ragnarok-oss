#!/usr/bin/env python3
"""Check the actual packaged dispatch metadata, not only Swift source syntax."""
import json
from pathlib import Path

app = Path(__file__).resolve().parents[1] / "build/Heimdall.app/Contents"
bundles = [
    (app, "Heimdall"),
    (app / "PlugIns/RagnarokControls.appex/Contents", "RagnarokControls"),
]
for bundle, module in bundles:
    metadata = json.loads((bundle / "Resources/Metadata.appintents/extract.actionsdata").read_text())
    action = metadata["actions"]["RagnarokControlIntent"]
    assert action["fullyQualifiedTypeName"] == f"{module}.RagnarokControlIntent"
    assert "com.apple.link.systemProtocol.OpenEntity" in action["systemProtocols"]
    assert action["openAppWhenRun"] is True
    destination = next(e for e in metadata["enums"] if e["identifier"] == "RagnarokControlDestination")
    assert {c["identifier"] for c in destination["cases"]} == {"main", "locked"}
    assert [p["name"] for p in action["parameters"]] == ["target"]
    print(f"PASS {module}: foreground OpenIntent, only main/locked destinations")
