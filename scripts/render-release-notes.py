#!/usr/bin/env python3
"""Extract a CHANGELOG.md section, optionally render to HTML for Sparkle.

CHANGELOG sections are expected to start with `## <version>` (anything after
the version on the heading line is ignored — e.g. "## 0.2.0 — 2026-04-22").
The section ends at the next `## ` heading or end of file.

--format html (default) renders via the markdown module for Sparkle's
<description>. --format markdown emits the raw section for use as a
GitHub release body.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path


def extract_section(text: str, version: str) -> str | None:
    # Match `## <version>` at start of line, optionally followed by anything.
    start_re = re.compile(
        rf"^##\s+{re.escape(version)}(\s|$)", re.MULTILINE
    )
    next_heading_re = re.compile(r"^##\s+", re.MULTILINE)

    m = start_re.search(text)
    if not m:
        return None

    # Advance past the rest of the heading line so the date suffix
    # (e.g. "— 2026-04-22") is not included in the body.
    eol = text.find("\n", m.start())
    body_start = eol + 1 if eol != -1 else len(text)
    next_m = next_heading_re.search(text, body_start)
    body_end = next_m.start() if next_m else len(text)

    return text[body_start:body_end].strip()


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--version", required=True, help="semver to extract (e.g. 0.2.0)")
    p.add_argument("--input", required=True, type=Path, help="CHANGELOG.md path")
    p.add_argument("--output", required=True, type=Path, help="output path")
    p.add_argument("--format", choices=["html", "markdown"], default="html",
                   help="html (Sparkle) or markdown (GitHub release body)")
    args = p.parse_args()

    text = args.input.read_text(encoding="utf-8")
    section = extract_section(text, args.version)
    if section is None:
        print(
            f"render-release-notes.py: no `## {args.version}` section in {args.input}",
            file=sys.stderr,
        )
        return 1

    if args.format == "html":
        try:
            import markdown
        except ImportError:
            print(
                "render-release-notes.py: `markdown` module not installed. "
                "Run scripts/setup-sparkle.sh.",
                file=sys.stderr,
            )
            return 1
        body = markdown.markdown(section, extensions=["fenced_code"])
    else:
        body = section

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(body + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main())
