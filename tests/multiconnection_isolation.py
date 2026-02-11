#!/usr/bin/env python3
import sqlite3
import sys
from pathlib import Path


def resolve_extension_path(cwd: Path) -> Path:
    candidates = [
        cwd / "libsqlite_plugin_lj.so",
        cwd / "libsqlite_plugin_lj.dylib",
        cwd / "libsqlite_plugin_lj.dll",
        cwd / "sqlite_plugin_lj.dll",
    ]
    for path in candidates:
        if path.exists():
            return path
    raise FileNotFoundError(
        "Could not find built extension in build dir. "
        "Expected one of: " + ", ".join(str(p.name) for p in candidates)
    )


def scalar_int(conn: sqlite3.Connection, sql: str) -> int:
    row = conn.execute(sql).fetchone()
    if row is None or row[0] is None:
        raise RuntimeError(f"Query returned no scalar value: {sql}")
    return int(row[0])


def require_l_function(conn: sqlite3.Connection, label: str, expected: int) -> None:
    value = scalar_int(conn, f"select L('return {expected}')")
    if value != expected:
        raise AssertionError(f"{label}: expected {expected}, got {value}")


def main() -> int:
    ext_path = resolve_extension_path(Path.cwd()).resolve()

    db1 = sqlite3.connect(":memory:")
    db2 = sqlite3.connect(":memory:")

    try:
        for db in (db1, db2):
            db.enable_load_extension(True)

        db1.load_extension(str(ext_path))
        require_l_function(db1, "db1 initial", 1)

        db2.load_extension(str(ext_path))

        # Both connections should keep independent usable plugin state.
        require_l_function(db1, "db1 after db2 load", 2)
        require_l_function(db2, "db2 after load", 3)

        # Verify DB isolation through plugin-executed SQL.
        db1.execute(
            "select L('sqlite.run_sql[[create table if not exists t_mc(v integer);"
            "delete from t_mc; insert into t_mc(v) values(10);]]')"
        )
        db2.execute(
            "select L('sqlite.run_sql[[create table if not exists t_mc(v integer);"
            "delete from t_mc; insert into t_mc(v) values(20);]]')"
        )

        c1 = scalar_int(db1, "select sum(v) from t_mc")
        c2 = scalar_int(db2, "select sum(v) from t_mc")
        if c1 != 10 or c2 != 20:
            raise AssertionError(f"cross-db isolation failed: db1 sum={c1}, db2 sum={c2}")

        # Churn a second connection repeatedly while keeping db1 open.
        for i in range(1, 34):
            churn = sqlite3.connect(":memory:")
            try:
                churn.enable_load_extension(True)
                churn.load_extension(str(ext_path))
                require_l_function(churn, f"churn db2 iter {i}", 1000 + i)
            finally:
                churn.close()

            require_l_function(db1, f"db1 after churn iter {i}", 2000 + i)

        print("PASS multiconnection isolation")
        return 0
    except Exception as exc:  # noqa: BLE001
        print(f"FAIL multiconnection isolation: {exc}")
        return 1
    finally:
        db1.close()
        db2.close()


if __name__ == "__main__":
    sys.exit(main())
