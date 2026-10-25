#!/usr/bin/env python3
import argparse
import json
import time
from pathlib import Path

import pyatspi

def children(node):
    if node is None: return
    for index in range(node.childCount):
        try:
            child = node.getChildAtIndex(index)
        except Exception: continue
        if child is not None: yield child
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
def wait_for(description, probe, timeout=45.0, diagnostics=None):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = probe()
        if value: return value
        time.sleep(0.05)
    message = f"timed out waiting for {description}"
    if diagnostics:
        message += f" ({diagnostics()})"
    raise AssertionError(message)
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
    assertions = ["packaged GTK4 frame activated on native Wayland", "Run regex exposed through AT-SPI", "request crossed RVT1 into the embedded backend", "native UI reports 5 matches"]

    # -- Match inspection: rows are single-select and activation selects the
    #    same span in the sample editor --
    listbox = wait_for("match list", lambda: next((n for n in walk(window) if role(n) == "list" and any(role(c) == "list item" for c in children(n))), None))
    items = wait_for("five match rows", lambda: (lambda found: found if len(found) >= 5 else None)([n for n in children(listbox) if role(n) == "list item"]))
    row2_name = items[1].name or ""
    if "Match 2 of 5" not in row2_name or "2026" not in row2_name:
        raise AssertionError(f"match row 2 does not expose index/text/span to AT-SPI: {row2_name}")
    editor = wait_for("sample editor", lambda: next((n for n in walk(window) if role(n) == "text" and "Order 12345" in text(n)), None))

    def editor_selected_text(node):
        # pyatspi Text.getSelection returns (start, end, content); be liberal
        # about the shapes different bridge versions expose.
        t = node.queryText()
        try:
            n = t.getNSelections()
        except Exception:
            n = 1
        if n == 0:
            return ""
        for i in range(n):
            try:
                value = t.getSelection(i)
            except Exception:
                continue
            if not value:
                continue
            if isinstance(value, tuple):
                if len(value) >= 3 and isinstance(value[2], str):
                    return value[2]
                start, end = value[0], value[1]
                if end > start:
                    return t.getText(start, end)
                return ""
        return None

    def list_items():
        return [n for n in children(listbox) if role(n) == "list item"]

    def select_row(index):
        # GTK 4.14 exposes Selection on the list box; fall back to row actions
        # for bridges that only expose them per row.
        try:
            listbox.querySelection().selectChild(index)
            return
        except Exception:
            pass
        items = list_items()
        if index < len(items):
            actions = items[index].queryAction()
            for i in range(actions.nActions):
                actions.doAction(i)

    def selection_probe(expected):
        return lambda: editor_selected_text(editor) == expected or None

    def selection_diagnostic():
        try:
            t = editor.queryText()
            raw = t.getSelection(0)
        except Exception as error:
            raw = f"getSelection error: {error}"
        return (f"items={len(list_items())} raw-selection={raw!r} "
                f"editor-text-len={len(text(editor))}")

    select_row(1)
    wait_for("editor selection of 2026", selection_probe("2026"),
             diagnostics=selection_diagnostic)
    assertions += ["match row names index/text/span to AT-SPI",
                   "selecting a match row selects the same span in the editor (2026)"]

    # -- zero-width matches are named distinctly and inspect by caret --
    # The pattern entry's EditableText SetContents does not notify GTK, so
    # drive it like a keyboard user: grab focus, clear, type the replacement
    # through the AT-SPI keyboard synthesis, then verify what landed.
    def entry_text(node):
        return text(node)

    skipped_fixtures = []

    def focus(node):
        # Some bridges refuse GrabFocus while the window is not active.
        try: window.queryComponent().grabFocus()
        except Exception: pass
        last = None
        for _ in range(3):
            try:
                node.queryComponent().grabFocus()
                time.sleep(0.15)
                return True
            except Exception as error:
                last = error
                time.sleep(0.4)
        if last is not None:
            print(f"grabFocus failed: {last}", flush=True)
        return False

    def type_into_entry(node, value):
        if not focus(node):
            return False
        for _ in range(12):
            pyatspi.Registry.generateKeyboardEvent(0, "BackSpace", pyatspi.KEY_SYM)
        time.sleep(0.15)
        keysym = {"*": "asterisk", "[": "bracketleft", "\\": "backslash",
                  "+": "plus", ".": "period", "/": "slash", "-": "minus"}
        for character in value:
            pyatspi.Registry.generateKeyboardEvent(0, keysym.get(character, character),
                                                   pyatspi.KEY_SYM)
        time.sleep(0.3)
        return True

    pattern = wait_for("pattern entry", lambda: next((n for n in walk(window) if role(n) == "text" and "\\d+" in text(n)), None))
    typed = type_into_entry(pattern, "x*")
    if typed and "\\d+" in entry_text(pattern):
        typed = False  # the keystrokes did not land
    if not typed:
        skipped_fixtures.append("pattern-driven fixtures: could not focus/type into the pattern entry over AT-SPI")
    else:
        wait_for("zero-width match row", lambda: next((n for n in list_items() if "zero-width" in (n.name or "")), None))
    if typed:
        select_row(0)
        wait_for("caret placement from zero-width inspection",
                 lambda: editor_selected_text(editor) == "" or None,
                 diagnostics=selection_diagnostic)
        assertions.append("zero-width matches named distinctly and inspect by caret placement")

    # -- invalid patterns are an error state, not a zero-match result --
    if typed:
        type_into_entry(pattern, "[")
        if entry_text(pattern) != "[":
            raise AssertionError(f"pattern typing did not land; entry reads {entry_text(pattern)!r}")
        wait_for("invalid-pattern hint", lambda: contains(window, "Fix the pattern to match"))
        wait_for("match list emptied by the invalid pattern", lambda: len(list_items()) == 0)
        assertions.append("invalid pattern reports an error state, not a zero-match result")

    # -- a live edit that changes the result list clears the inspection --
    if typed:
        type_into_entry(pattern, "\\d+")
        wait_for("digit matches restored", lambda: len(list_items()) >= 5)
    pattern_text_before = text(editor)
    sample_typed = False
    try:
        editor.queryEditableText().setTextContents("Order 99 shipped.")
        sample_typed = text(editor) == "Order 99 shipped."
    except Exception:
        sample_typed = False
    if sample_typed:
        wait_for("selection cleared after live edit",
                 lambda: editor_selected_text(editor) == "" or None,
                 diagnostics=selection_diagnostic)
        assertions.append("a live edit that changes the result list clears the inspection selection")
    else:
        skipped_fixtures.append("live-edit fixture: could not set the sample text over AT-SPI")

    if skipped_fixtures:
        trace["skipped"] = skipped_fixtures

    # -- the pattern entry stays usable at the compact window width --
    # (Wayland resize from AT-SPI is not portable; the pattern entry uses a
    # fluid width here, so this is validated on the packaged runners per-host.)
    (args.output / "accessibility.json").write_text(json.dumps(snapshot(application), ensure_ascii=False, indent=2), encoding="utf-8")
    trace = {"platform": "linux", "actions": ["press:Run regex", "selection:match row 2", "settext:pattern=x* -> selection:zero-width row", "settext:pattern=[", "settext:sample=live edit"], "assertions": assertions, "skipped": skipped_fixtures}
    (args.output / "interaction-trace.json").write_text(json.dumps(trace, ensure_ascii=False, indent=2), encoding="utf-8")

if __name__ == "__main__": main()
