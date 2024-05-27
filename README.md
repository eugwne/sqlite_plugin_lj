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

**use_function_storage**  - one time called function. It sets table as a container for lua created functions. If table with the name exists, it reads the table contents and runs internal create functions. Do not run it on unknown sources, it has no sandboxing !!!  
User created functions will be stored there
```sql
select use_function_storage('tbl_name');
```
Call this function with no args to ignore store/restore function logic

```sql
select use_function_storage();
```

Execute lua with arguments
```sql
select L('return arg[1] ', arg1, ...)
```

Create sqlite callable function:
```sql
select make_stored_fn('inc', 'return function(a) return a + 1 end', 1 /*expected arguments count*/);
select inc(14);
```

Create sqlite callable function from lua chunk:
```sql
select make_stored_chk('inc_c', 'return arg[1] + 1', 1);
select inc_c(14);
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
-- store list_iterator in lua global
select L('
    _G.list_iterator = function(t)
      local i = 0
      local n = #t
      return function ()
               i = i + 1
               if i <= n then return t[i] end
             end
    end
 ');

SELECT * , typeof(value)
FROM L('
    local tbl = {123, 324, math.pi, NULL, "test", -1377409902473561268LL}
    return list_iterator(tbl)
 ')
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
 ')
```

Custom virtual table:
```sql
select L('
    run_sql("DROP TABLE IF EXISTS TEMP.table_a")
    make_vtable("table_a",
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

Local build with luajit repo:
```
mkdir build 
cd build
cmake -DCMAKE_BUILD_TYPE=Release ..
cmake --build .

ctest -R sqlite_plugin_tests -V
```

All lua scripts are included in the .so file.


## Examples

See sql folder

# license

This project is licensed under the MIT License - see the LICENSE file for details.
