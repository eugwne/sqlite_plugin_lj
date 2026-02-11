select load_extension('./libsqlite_plugin_lj');

-- Setup: create helper and test table
select L('
  sqlite.config.use_traceback = 0
  sqlite.register_internal_function("make_fn")
  sqlite.register_internal_function("make_chk")

  sqlite.run_sql("CREATE TABLE IF NOT EXISTS t036(id INTEGER PRIMARY KEY, val TEXT)")
  sqlite.run_sql("DELETE FROM t036")
  sqlite.run_sql("INSERT INTO t036 VALUES(1, ''a'')")
  sqlite.run_sql("INSERT INTO t036 VALUES(2, ''b'')")
  sqlite.run_sql("INSERT INTO t036 VALUES(3, ''c'')")
');

-- Test 1: Function that abandons an iterator mid-iteration returns correct value
-- make_chk uses caller_chk which has close_unfinalized cleanup
select make_chk('test036_abandon',
  'local first = sqlite.fetch_first("SELECT id, val FROM t036 ORDER BY id") return tonumber(first.id)',
  0);
select L('
  local r = sqlite.fetch_first("SELECT test036_abandon() as v")
  local ok = tonumber(r.v) == 1
  return (ok and "PASS" or "FAIL") .. " abandon iterator returns correct value"
');

-- Test 2: Repeated calls with abandoned iterators work correctly
select make_chk('test036_abandon2',
  'local first = sqlite.fetch_first("SELECT id FROM t036 ORDER BY id LIMIT 1") return tonumber(first.id)',
  0);
select L('
  local ok = true
  for i = 1, 5 do
    local r = sqlite.fetch_first("SELECT test036_abandon2() as v")
    if tonumber(r.v) ~= 1 then ok = false end
  end
  return (ok and "PASS" or "FAIL") .. " repeated abandon stable"
');

-- Test 3: Function that errors after partial iteration propagates the error
select make_chk('test036_error_mid',
  'local first = sqlite.fetch_first("SELECT id FROM t036 ORDER BY id") error("deliberate error after partial read")',
  0);
select L('
  sqlite.config.use_traceback = 0
  local ok, err = pcall(function()
    sqlite.fetch_first("SELECT test036_error_mid() as v")
  end)
  local err_ok = (not ok) and tostring(err):find("deliberate error after partial read")
  return (err_ok and "PASS" or "FAIL") .. " error after partial iteration propagates"
');

-- Test 4: Database remains usable after error+cleanup
select L('
  local r = sqlite.fetch_first("SELECT count(*) as c FROM t036")
  local ok = tonumber(r.c) == 3
  return (ok and "PASS" or "FAIL") .. " db usable after error cleanup"
');

-- Test 5: Nested function calls with cleanup
-- Inner function reads a value; outer calls inner and multiplies
select make_chk('test036_inner',
  'local r = sqlite.fetch_first("SELECT max(id) as m FROM t036") return tonumber(r.m)',
  0);
select make_chk('test036_outer',
  'local r = sqlite.fetch_first("SELECT test036_inner() as v") return tonumber(r.v) * 10',
  0);
select L('
  local r = sqlite.fetch_first("SELECT test036_outer() as v")
  local ok = tonumber(r.v) == 30
  return (ok and "PASS" or "FAIL") .. " nested functions with cleanup"
');

-- Test 6: Subsequent queries not corrupted by cleanup
select L('
  local rows = sqlite.fetch_all("SELECT id, val FROM t036 ORDER BY id")
  local ok = #rows == 3
    and tonumber(rows[1].id) == 1 and rows[1].val == "a"
    and tonumber(rows[2].id) == 2 and rows[2].val == "b"
    and tonumber(rows[3].id) == 3 and rows[3].val == "c"
  return (ok and "PASS" or "FAIL") .. " subsequent queries not corrupted"
');

-- Cleanup
select L('sqlite.run_sql("DROP TABLE IF EXISTS t036")');
