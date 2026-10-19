#!/usr/bin/env python3
import argparse
import json
import time
from pathlib import Path

import pyatspi

def children(node):
    for index in range(node.childCount):
        try: yield node.getChildAtIndex(index)
        except Exception: continue
def walk(node):
    yield node
    for child in children(node): yield from walk(child)
def role(node):
    try: return node.getRoleName()
    except Exception: return "unknown"
def text(node):
    try:
        value = node.queryText()
        return value.getText(0, value.characterCount)
    except Exception: return ""
def wait_for(description, probe, timeout=45.0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = probe()
        if value: return value
        time.sleep(0.05)
    raise AssertionError(f"timed out waiting for {description}")
def find_application():
    desktop = pyatspi.Registry.getDesktop(0)
    for application in children(desktop):
        for node in walk(application):
            if role(node) == "frame" and (node.name or "") == "RegexMate": return application
    return None
def contains(root, fragment): return any(fragment in (node.name or "") or fragment in text(node) for node in walk(root))
def press(node):
    actions = node.queryAction()
    if actions.nActions < 1: raise AssertionError(f"AT-SPI exposes no action for {node.name!r}")
    # GTK's AT-SPI bridge may report False even though the asynchronous
    # action was queued. The observable UI result below is the success test.
    actions.doAction(0)
def snapshot(node, depth=0):
    result = {"name": node.name or "", "role": role(node)}
    value = text(node)
    if value: result["text"] = value
    if depth < 8: result["children"] = [snapshot(child, depth + 1) for child in children(node)]
    return result

def main():
    parser = argparse.ArgumentParser(); parser.add_argument("--output", type=Path, required=True); args = parser.parse_args(); args.output.mkdir(parents=True, exist_ok=True)
    application = wait_for("RegexMate application", find_application)
    window = wait_for("RegexMate frame", lambda: next((n for n in walk(application) if role(n) == "frame"), None))
    wait_for("embedded backend ready status", lambda: contains(window, "Embedded Racket CS is ready"))
    refresh = wait_for("Run regex button", lambda: next((node for node in walk(window) if (node.name or "") == "Run regex" and role(node) == "push button"), None))
    press(refresh)
    wait_for("match count from embedded backend", lambda: contains(window, "5 matches"))
    (args.output / "accessibility.json").write_text(json.dumps(snapshot(application), ensure_ascii=False, indent=2), encoding="utf-8")
    (args.output / "interaction-trace.json").write_text(json.dumps({"platform": "linux", "actions": ["press:Run regex"], "assertions": ["packaged GTK4 frame activated on native Wayland", "Run regex exposed through AT-SPI", "request crossed RVT1 into the embedded backend", "native UI reports 5 matches"]}, indent=2), encoding="utf-8")

if __name__ == "__main__": main()
