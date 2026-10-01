#!/usr/bin/env python3
"""Heuristic publication checks; never print matching secret values.

Scan tracked and non-ignored candidate files, optionally every reachable Git
object and an application bundle. Ignored development sessions are not read.
This is a focused preflight, not a guarantee that a repository contains no secrets.
"""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import re
import subprocess
import sys
from collections import Counter


PATTERNS = {
    "private key": re.compile(rb"-----BEGIN (?:[A-Z ]+)?PRIVATE KEY-----"),
    "GitHub token": re.compile(rb"\b(?:gh[pousr]_[A-Za-z0-9_]{30,}|github_pat_[A-Za-z0-9_]{40,})\b"),
    "AWS access key": re.compile(rb"\b(?:AKIA|ASIA)[A-Z0-9]{16}\b"),
    "API token": re.compile(rb"\b(?:sk-(?:proj-)?[A-Za-z0-9_-]{25,}|xox[baprs]-[A-Za-z0-9-]{15,})\b"),
    "credential URL": re.compile(rb"\bhttps?://[^\s/:@]+:[^\s/@]{4,}@"),
    "personal absolute path": re.compile(rb"/(?:Users|home)/([^/\s\"'<>\x00]+)|[A-Za-z]:\\Users\\([^\\\s\"'<>\x00]+)"),
    "machine temporary path": re.compile(rb"/(?:private/)?var/folders/[A-Za-z0-9_-]+/[A-Za-z0-9_-]{8,}"),
    "secret assignment": re.compile(
        rb"(?i)\b(?:password|passwd|api[_-]?key|api[_-]?secret|access[_-]?token|client[_-]?secret|private[_-]?key)"
        rb"\b\s*[=:]\s*[\"']([^\"'\r\n]{8,})[\"']"
    ),
}
EMAIL = re.compile(rb"\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b")
PLACEHOLDERS = {b"user", b"username", b"yourname", b"you", b"example", b"test", b"name"}
PUBLIC_EMAILS = {b"zhangjunyang@mail.ustc.edu.cn"}


def git(root: Path, *args: str) -> bytes:
    return subprocess.check_output(["git", "-C", str(root), *args], stderr=subprocess.PIPE)


def display_path(value: str) -> str:
    """Escape control characters in a filename without disclosing matched values."""
    return value.encode("unicode_escape").decode("ascii") if any(ord(c) < 32 for c in value) else value


def is_example(kind: str, match: re.Match[bytes]) -> bool:
    if kind == "personal absolute path":
        return next(part for part in match.groups() if part is not None).lower() in PLACEHOLDERS
    if kind == "secret assignment":
        value = match.group(1).strip().lower()
        return (
            value in PLACEHOLDERS
            or value.startswith((b"<", b"${", b"process.env.", b"os.environ", b"your_", b"your-", b"example_", b"example-", b"replace_", b"replace-"))
            or set(value) <= {ord("x"), ord("*")}
        )
    return False


def inspect(data: bytes, path: str, origin: str = "", check_email: bool = True) -> list[tuple[str, int, str, str]]:
    findings = set()
    is_text = b"\x00" not in data
    for kind, pattern in PATTERNS.items():
        for match in pattern.finditer(data):
            if not is_example(kind, match):
                line = data.count(b"\n", 0, match.start()) + 1 if is_text else 0
                findings.add((path, line, kind, origin))
    # Third-party notices and license texts retain their upstream public identities.
    license_text = any(part.startswith(("LICENSE", "COPYING", "NOTICE", "THIRD_PARTY")) for part in Path(path).parts)
    if check_email and is_text and not path.startswith(".agents/") and not license_text:
        for match in EMAIL.finditer(data):
            email = match.group().lower()
            domain = email.split(b"@", 1)[1]
            if email in PUBLIC_EMAILS or domain in {b"example.com", b"example.org", b"example.net", b"localhost.test"}:
                continue
            findings.add((path, data.count(b"\n", 0, match.start()) + 1, "email to review", origin))
    return sorted(findings)


def identity(value: bytes) -> str:
    # Author/committer/tagger lines end in a Unix timestamp and timezone.
    return value.rsplit(b" ", 2)[0].decode("utf-8", "replace")


def history(root: Path, expected_author: str | None) -> tuple[list[tuple[str, int, str, str]], Counter]:
    records = git(root, "rev-list", "--objects", "--all").splitlines()
    findings = []
    counts = Counter()
    # Batch one request at a time to avoid filling a pipe with a large history.
    with subprocess.Popen(["git", "-C", str(root), "cat-file", "--batch"], stdin=subprocess.PIPE, stdout=subprocess.PIPE) as process:
        assert process.stdin is not None and process.stdout is not None
        for record in records:
            oid, _, name = record.partition(b" ")
            process.stdin.write(oid + b"\n")
            process.stdin.flush()
            header = process.stdout.readline().split()
            if len(header) != 3:
                raise RuntimeError("Git could not read a reachable object")
            kind = header[1]
            size = int(header[2])
            data = process.stdout.read(size)
            if len(data) != size or process.stdout.read(1) != b"\n":
                raise RuntimeError("Incomplete Git object output")
            origin = "Git " + oid[:12].decode()
            if kind == b"blob":
                path = name.decode("utf-8", "replace") or "(unnamed Git blob)"
                findings.extend(inspect(data, path, origin))
                counts["history blobs"] += 1
            elif kind == b"commit":
                headers, _, message = data.partition(b"\n\n")
                for line in headers.splitlines():
                    field, _, value = line.partition(b" ")
                    if expected_author is not None and field in {b"author", b"committer"} and identity(value) != expected_author:
                        findings.append(("(commit metadata)", 0, field.decode() + " differs from explicitly expected identity", origin))
                findings.extend(inspect(message, "(commit message)", origin))
                counts["commits"] += 1
        process.stdin.close()
        if process.wait() != 0:
            raise RuntimeError("Git object reader failed")
    for ref in git(root, "for-each-ref", "--format=%(refname)", "refs/tags").decode().splitlines():
        if git(root, "cat-file", "-t", ref).strip() != b"tag":
            continue
        data = git(root, "cat-file", "tag", ref)
        headers, _, message = data.partition(b"\n\n")
        for line in headers.splitlines():
            if expected_author is not None and line.startswith(b"tagger ") and identity(line[7:]) != expected_author:
                findings.append((ref, 0, "tagger differs from explicitly expected identity", ""))
        findings.extend(inspect(message, ref))
        counts["annotated tags"] += 1
    return findings, counts


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--history", action="store_true", help="inspect all reachable Git history and tag messages; preserve contributor identities by default")
    parser.add_argument("--app", type=Path, help="also inspect an application bundle inside this project")
    parser.add_argument("--expected-author", help="with --history, explicitly require every author, committer, and tagger to match this identity (for a deliberate history rewrite audit only)")
    parser.add_argument("--allow-email", action="append", default=[], metavar="EMAIL", help="allow an additional reviewed public email in text; repeat for multiple addresses")
    args = parser.parse_args()
    if args.expected_author is not None and (not args.history or not args.expected_author.strip()):
        parser.error("--expected-author requires --history and a nonempty identity")
    for email in args.allow_email:
        encoded = email.lower().encode("utf-8")
        if EMAIL.fullmatch(encoded) is None:
            parser.error("each --allow-email must contain one valid email address")
        PUBLIC_EMAILS.add(encoded)
    root = Path(__file__).resolve().parent.parent
    findings = []
    counts = Counter()
    candidates = set(git(root, "ls-files", "--cached", "--others", "--exclude-standard", "-z").split(b"\0")) - {b""}
    for name in sorted(candidates):
        relative = os.fsdecode(name)
        path = root / relative
        if path.is_symlink():
            data = os.fsencode(os.readlink(path))
        elif path.is_file():
            if not path.resolve().is_relative_to(root):
                findings.append((relative, 0, "file resolves outside project", ""))
                continue
            data = path.read_bytes()
        else:
            continue  # Deleted tracked paths are still covered by --history.
        findings.extend(inspect(data, relative))
        counts["candidate files"] += 1
    if args.history:
        historical, history_counts = history(root, args.expected_author)
        findings.extend(historical)
        counts.update(history_counts)
    if args.app:
        app = (root / args.app).resolve()
        if not app.is_relative_to(root) or not app.is_dir() or app.suffix != ".app":
            parser.error("--app must be an existing .app directory inside this project")
        for path in sorted(app.rglob("*")):
            if path.is_symlink():
                data = os.fsencode(os.readlink(path))
            elif path.is_file() and path.resolve().is_relative_to(app):
                data = path.read_bytes()
            else:
                continue
            findings.extend(inspect(data, str(path.relative_to(root)), check_email=False))
            counts["app files"] += 1
    print("Publication audit: " + ", ".join(f"{value} {key}" for key, value in counts.items()))
    for path, line, kind, origin in sorted(set(findings)):
        location = display_path(path) + (f":{line}" if line else "")
        print(f"REVIEW {location}: {kind}" + (f" [{origin}]" if origin else ""))
    print("Heuristic scan only; ignored local data is excluded and no matching values are printed.")
    if findings:
        print(f"FAIL: {len(set(findings))} finding(s) require review.")
        return 1
    print("PASS: no configured patterns found." + (" All Git identities match the explicit expectation." if args.expected_author is not None else ""))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, subprocess.CalledProcessError, RuntimeError) as error:
        # Git command output and file exceptions can contain local paths or values.
        print(f"ERROR: audit could not complete ({type(error).__name__}).", file=sys.stderr)
        raise SystemExit(2)
