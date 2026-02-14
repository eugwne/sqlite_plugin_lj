#!/usr/bin/env python3
import argparse
import os
import re
import subprocess
import sys
from pathlib import Path


LIMIT_ENV_BY_TEST = {
    "016": {
        "SQLITE_LJ_MAX_OBJECTS": "6",
        "SQLITE_LJ_MAX_OBJECT_BYTES": "1048576",
        "SQLITE_LJ_MAX_BUFFER_BYTES": "67108864",
        "SQLITE_LJ_MAX_FUNCTION_CONTEXTS": "50000",
    },
    "017": {
        "SQLITE_LJ_MAX_FUNCTION_CONTEXTS": "5",
        "SQLITE_LJ_MAX_OBJECTS": "200000",
        "SQLITE_LJ_MAX_BUFFER_BYTES": "67108864",
        "SQLITE_LJ_MAX_OBJECT_BYTES": "4194304",
    },
    "018": {
        "SQLITE_LJ_MAX_BUFFER_BYTES": "200000",
        "SQLITE_LJ_MAX_OBJECT_BYTES": "120000",
        "SQLITE_LJ_MAX_OBJECTS": "1000",
        "SQLITE_LJ_MAX_FUNCTION_CONTEXTS": "50000",
    },
}

SQLITE3_BIN = os.getenv("SQLITE3_BIN", "sqlite3")


GREEN = "\033[0;32m"
RED = "\033[0;31m"
NC = "\033[0m"


def mark(text: str, ok: bool) -> str:
    prefix = "PASSED" if ok else "FAILED"
    color = GREEN if ok else RED
    return f"{color}{text}: {prefix}{NC}"


def normalize_text(text: str) -> str:
    return text.replace("\r\n", "\n").replace("\r", "\n")


def shell_like_text(text: str) -> str:
    # test.sh uses command substitution, which drops trailing newlines.
    return normalize_text(text).rstrip("\n")


def extension_base_path() -> str:
    return "./libsqlite_plugin_lj"


def strip_sql_load_statements(sql: str) -> str:
    out_lines: list[str] = []
    for line in sql.splitlines():
        if re.match(r"^\s*\.load\b", line):
            continue
        if re.match(r"^\s*select\s+load_extension\s*\(", line, flags=re.IGNORECASE):
            continue
        out_lines.append(line)
    return "\n".join(out_lines) + ("\n" if sql.endswith("\n") else "")


def execute_sqlite(sql: str, env: dict[str, str], extra_args: list[str] | None = None) -> tuple[int, str]:
    args = [SQLITE3_BIN, ":memory:"]
    if extra_args:
        args.extend(extra_args)
    proc = subprocess.run(
        args,
        input=sql,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        env=env,
    )
    return proc.returncode, normalize_text(proc.stdout)


def resolve_fixture_path(root_dir: Path, flat_path: Path, filename: str) -> Path | None:
    if flat_path.exists():
        return flat_path

    matches = sorted(root_dir.rglob(filename))
    if not matches:
        return None
    return matches[0]


def run_sqlite(input_file: Path, extra_env: dict[str, str] | None = None) -> tuple[int, str]:
    sql = input_file.read_text(encoding="utf-8")
    env = os.environ.copy()
    if extra_env:
        env.update(extra_env)

    code, output = execute_sqlite(sql, env)
    if code == 0:
        return code, output

    needs_load_fallback = (
        "no such function: load_extension" in output
        or 'unknown command or invalid arguments:  "load"' in output
    )
    if not needs_load_fallback:
        return code, output

    stripped_sql = strip_sql_load_statements(sql)
    fallback_args = ["-cmd", f".load {extension_base_path()}"]
    fb_code, fb_output = execute_sqlite(stripped_sql, env, fallback_args)
    if fb_code == 0:
        return fb_code, fb_output
    return code, output


def run_suite(test_ids: str) -> int:
    failed = 0
    root = Path.cwd()

    for test_id in test_ids.split(";"):
        test_id = test_id.strip()
        if not test_id:
            continue

        print(f"Run test: {test_id}")

        input_file = resolve_fixture_path(
            root / "sql", root / "sql" / f"input_{test_id}.sql", f"input_{test_id}.sql"
        )
        if input_file is None:
            print(f"Test [{test_id}]: FAILED")
            print(f"Missing SQL fixture: input_{test_id}.sql")
            failed += 1
            continue

        expected_file = resolve_fixture_path(
            root / "expected",
            root / "expected" / f"output_{test_id}.txt",
            f"output_{test_id}.txt",
        )
        if expected_file is None:
            print(f"Test [{test_id}]: FAILED")
            print(f"Missing expected fixture: output_{test_id}.txt")
            failed += 1
            continue

        extra_env = LIMIT_ENV_BY_TEST.get(test_id, {})
        _, output_text = run_sqlite(input_file, extra_env)
        expected_text = normalize_text(expected_file.read_text(encoding="utf-8"))

        output_cmp = shell_like_text(output_text)
        expected_cmp = shell_like_text(expected_text)

        if output_cmp == expected_cmp:
            print(mark(f"Test [{test_id}]", True))
        else:
            print(mark(f"Test [{test_id}]", False))
            print(f"Expected: [{expected_cmp}]")
            print(f"Actual: [{output_cmp}]")
            failed += 1

    if failed > 0:
        print(f"{RED}{failed} test(s) failed.{NC}")
        return 1
    return 0


def run_sql_file(sql_file: Path) -> int:
    code, out = run_sqlite(sql_file, None)
    text = out.strip("\n")
    if text:
        print(text)
    return code


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--tests", help="Semicolon-separated test ids")
    parser.add_argument("--sql-file", help="SQL file to run as a single test")
    args = parser.parse_args()

    if bool(args.tests) == bool(args.sql_file):
        print("Use exactly one of --tests or --sql-file.", file=sys.stderr)
        return 2

    if args.tests:
        return run_suite(args.tests)
    return run_sql_file(Path(args.sql_file))


if __name__ == "__main__":
    sys.exit(main())
