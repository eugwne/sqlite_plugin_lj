# SQLite Luajit Extension Plugin Library (sqlite_plugin_lj)

A C library to extend SQLite's functionality with LuaJIT. This plugin focuses on extensibility rather than performance.

## Table of Contents

- [Overview](#overview)
- [Features](#features)
- [Installation](#installation)
- [Usage](#usage)
- [Examples](#examples)
- [Building from Source](#building-from-source)
- [License](#license)

## Features
  Plugin runs unrestricted LuaJIT VM inside of sqlite plugin. 
- Custom SQL functions

The plugin makes available only L function, which can add more functions.

Execute L with arguments
```sql
cmd> sqlite3
sqlite> select load_extension('./libsqlite_plugin_lj');
sqlite> --select L('return arg[1] ', arg1, ...);
sqlite> select L('return arg[1] ', 1);
1
sqlite> select L('return arg[1] + arg[2] ', 1, 3);
4
```

API functions are available in the `sqlite` module.

Register all internal functions with default names:
```sql
sqlite> select L('sqlite.register_internal_functions()');
```

Register one function (default name) or rename it:
```sql
sqlite> select L('sqlite.register_internal_function("make_chk")');
sqlite> select L('sqlite.register_internal_function("make_function_agg_chk", "make_stored_agg3")');
```

Internal API reference:

| Function | Description | Arguments | Example |
| --- | --- | --- | --- |
| `make_fn` | Create SQL scalar function from Lua factory code. | `(name, code_text, argc)` | `select make_fn('inc', 'return function(a) return a + 1 end', 1);` |
| `make_chk` | Create SQL scalar function from Lua chunk using `arg`. | `(name, code_text, argc)` | `select make_chk('inc_c', 'return arg[1] + 1', 1);` |
| `make_int` | Create constant integer SQL function. | `(name, value)` | `select make_int('answer', 42);` |
| `make_str` | Create constant text SQL function. | `(name, value)` | `select make_str('hello_const', 'hello');` |
| `make_function_agg_chk` | Create aggregate from init/step/final chunks. | `(name, init, step, final, argc)` | `select make_function_agg_chk('sum_ac', 'n=0', 'n=n+arg[1]', 'return n', 1);` |
| `create_function_agg_coro_text` | Create aggregate from coroutine-based code. | `(name, code_text, argc)` | `select create_function_agg_coro_text('sum_a', 'return function() ... end', 1);` |
| `create_function_agg_chk` | Aggregate registration helper (chunk-based). | `(name, init, step, final, argc)` | `select create_function_agg_chk('sum_b', 'n=0', 'n=n+arg[1]', 'return n', 1);` |
| `create_function_agg_chk_window` | Window aggregate helper (with optional inverse). | `(name, init, step, final, argc)` or `(name, init, step, inverse, final, argc)` | `select create_function_agg_chk_window('sum_w', 'n=0', 'n=n+arg[1]', 'return n', 1);` |
| `make_vtable` | Create virtual table from Lua table descriptor. | `(table_name, spec)` | `select L('sqlite.make_vtable(\"table_a\", {columns={\"a\"}, rows={{1}}})');` |
| `run_sql` | Execute SQL text from Lua. | `(sql)` | `select L('sqlite.run_sql(\"create table t(a)\")');` |
| `fetch_first` | Run query and return first row as Lua table. | `(sql, [binds])` | `select L('return sqlite.fetch_first(\"select 1 as v\").v');` |
| `fetch_all` | Run query and return all rows. | `(sql, [binds])` | `select L('return #sqlite.fetch_all(\"select 1 as v\")');` |
| `nrows` | Iterator over query rows (name-keyed row table). | `(sql, [binds])` | `select L('for r in sqlite.nrows(\"select 1 as v\") do return r.v end');` |
| `rows` | Row iterator helper (array-like row table). | `(sql, [binds])` | `select L('for r in sqlite.rows(\"select 1 as v\") do return r[1] end');` |
| `urows` | Unpacked-row iterator helper. | `(sql, [binds])` | `select L('for v in sqlite.urows(\"select 1\") do return v end');` |

Create sqlite callable function:
```sql
select make_fn('inc', 'return function(a) return a + 1 end', 1 /*expected arguments count*/);
select inc(14);
```

Create sqlite callable function from lua chunk:
```sql
select make_chk('inc_c', 'return arg[1] + 1', 1);
select inc_c(14);
```

Create fast constant string function:
```sql
select make_str('hello_const', 'hello from sqlite_plugin_lj');
select hello_const();
```


- Custom SQL aggregates

Create aggregate from 3 chunks (init,step,end):
```sql
select make_stored_agg3('sum_ac', 'n = 0', 'n = n + arg[1]', 'return n', 1);
```

Create aggregate from coroutine:
```sql
select make_stored_aggc('sum_a', 
'return function ()
        local acc = 0
        local n = 0
        while true do
            local has_next, value = coroutine.yield() 
            if has_next then
                acc = acc + value
                n = n + 1
            else
                break 
            end
        end
        return acc
    end', 1);
```


- Custom virtual tables

One field virtual table:
```sql
-- query 1: initialize helper in vtable VM
SELECT *
FROM L('
    _G.list_iterator = function(t)
      local i = 0
      local n = #t
      return function ()
               i = i + 1
               if i <= n then return t[i] end
             end
    end
    return function() end
 ');

-- query 2: use helper
SELECT * , typeof(value)
FROM L('
    local tbl = {123, 324, math.pi, NULL, "test", -1377409902473561268LL}
    return list_iterator(tbl)
 ');
```


10 Fields virtual table (fields named r0, r1 ...):
```sql
SELECT *
FROM L10('
    local tbl = {
        {123, 324, math.pi, NULL, "test", -1377409902473561268LL},
        {124, 324, math.pi, NULL, "test", -1377409902473561268LL}
    }
    return list_iterator(tbl)
 ');
```

Custom virtual table:
```sql
select L('
    sqlite.run_sql("DROP TABLE IF EXISTS TEMP.table_a")
    sqlite.make_vtable("table_a",
        {
            columns = {"a", "b", "c"}, 
            rows = {{1,2}}
        }
    )
 ');

select * from table_a o1;
```


## Installation

### Prerequisites

- C compiler
- CMake
- LuaJIT
- SQLite

Windows notes:
- `vcpkg install sqlite3:x64-windows` provides SQLite headers (`sqlite3.h`, `sqlite3ext.h`) and libraries.
- Tests also require the SQLite CLI executable (`sqlite3.exe`). Install the official SQLite command-line tools from sqlite.org and add `sqlite3.exe` to `PATH`.

### Building from Source

Docker builds:

Alpine
```
docker build --output=lib --target=binaries -f DockerAlpine .
```
Ubuntu
```
docker build --output=lib --target=binaries -f DockerUbuntu .
```

GitHub Actions workflows:
- `cmake-linux.yml` (Linux CMake build/test)
- `cmake-macos.yml` (macOS CMake build/test)
- `cmake-windows.yml` (Windows/MSVC CMake build/test)
- `docker-alpine.yml` (Docker Alpine binary build)
- `docker-ubuntu.yml` (Docker Ubuntu binary build)

Local build with LuaJIT fetched by CMake (Linux):
```
mkdir build 
cd build
cmake -DCMAKE_BUILD_TYPE=Release ..
cmake --build .

ctest -V
```

Native Windows build sample (Developer Command Prompt for VS):
```bat
set VCPKG_ROOT=C:\git\vcpkg
cmake -S . -B build-vs -G "Visual Studio 17 2022" -A x64
cmake --build build-vs --config Release
ctest --test-dir build-vs -C Release -V
```

Windows build sample with explicit SQLite headers directory (without `VCPKG_ROOT`):
```bat
set SQLITE3_INCLUDE_DIR=C:\path\to\sqlite\include
cmake -S . -B build-vs -G "Visual Studio 17 2022" -A x64
cmake --build build-vs --config Release
ctest --test-dir build-vs -C Release -V
```

Cross-platform Python test runner (used by CTest):
```bash
cd build-vs   # or build on Linux/macOS
python ../test.py --tests "011;010;009;001;002;003;004;005;006;007;008;012;013;014;015;016;017;018;019;020;021;022;024;025;026"
python ../test.py --sql-file ../sql/vtables/input_023.sql
```

All Lua scripts are embedded into the built library (`.so` / `.dll`).

### Threading

Use this extension in a single-threaded way per SQLite connection. Do not execute `L(...)`, custom Lua functions, aggregates, or virtual tables concurrently on the same connection.

### VM Paths

The extension uses separate Lua VM paths per SQLite connection:

- `SELECT L('...')` executes in the function-callback VM.
- `FROM L('...')` / `FROM L10('...')` executes in the virtual-table VM.

These are different Lua states. `_G` is not shared between them.

That means this does **not** work:

```sql
-- sets global in function-callback VM
SELECT L('_G.list_iterator = function(t) ... end');

-- runs in virtual-table VM, where list_iterator is nil
SELECT * FROM L10('return list_iterator({{1,2}})');
```

Use this pattern instead:

```sql
-- initialize global in virtual-table VM
SELECT * FROM L('
  _G.list_iterator = function(t) ... end
  return function() return nil end
');

-- now virtual-table queries can use it
SELECT * FROM L10('return list_iterator({{1,2}})');
```

Plain Lua globals are VM-local. If you need shared state across VM paths, pass values as function arguments or persist them in SQL tables.

Nested virtual-table execution is also restricted. If a virtual-table callback is already running, trying to enter another virtual-table path from inside it is rejected (for example `L`/`L10` re-entry from within vtable-driven Lua code). Expected error text includes:

`vtable cannot be used from nested context`

Global access note for nested paths: nested virtual-table calls would target the same virtual-table VM (so globals would be the same VM globals), but the re-entry guard blocks execution before that nested call proceeds.

Function-path nesting has a different caveat: nested function execution can run in a different depth VM. Runtime `_G` mutations made in one function call are not automatically propagated to other depth VMs, so nested calls (for example via `nrows("SELECT my_fn(...)")`) may observe a different value or `nil`.

### Retention/Lifetime

Shared bridge state (function contexts and stored Lua objects) is retained for the process/extension lifetime in the current implementation. Runtime function unregister/reclaim is currently unsupported as an operational path. Virtual table metadata remains the main reclaimable exception via vtable destroy callbacks.

### Runtime Limits

The extension uses a shared in-memory bridge between Lua VMs.

- `shared object`
  Serialized Lua data stored in bridge memory (for example function source chunks and vtable metadata).
- `shared buffer`
  The backing byte buffer that holds all shared objects.
- `function context`
  Stored callback metadata (`FunctionContext`) used by SQLite function/aggregate callbacks.

Configure limits with environment variables before starting `sqlite3`:

- `SQLITE_LJ_MAX_BUFFER_BYTES`
  Total bytes available for the shared buffer.
  Default: `67108864` (64 MiB).
- `SQLITE_LJ_MAX_OBJECT_BYTES`
  Maximum size of a single shared object.
  Default: `4194304` (4 MiB).
- `SQLITE_LJ_MAX_OBJECTS`
  Maximum number of shared objects stored in the bridge.
  Default: `200000`.
- `SQLITE_LJ_MAX_FUNCTION_CONTEXTS`
  Maximum number of stored function contexts.
  Default: `50000`.

When any limit is exceeded, registration fails with an explicit Lua error.


## Examples

See sql folder

# license

This project is licensed under the MIT License - see the LICENSE file for details.
