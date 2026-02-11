select load_extension('./libsqlite_plugin_lj');

select L('
  sqlite.config.use_traceback = 0

  sqlite.make_vtable("inner_t", {
    columns = {"v"},
    rows = {{1}, {2}, {3}}
  })
');

select('--- re-entry from L into make_vtable ---');

select L('
  sqlite.config.use_traceback = 0
  local out = {}

  local function check(label, ok)
    out[#out + 1] = (ok and "PASS " or "FAIL ") .. label
  end

  -- Test 1: L callback tries to SELECT from a make_vtable -> should fail with re-entry error
  local ok1, err1 = pcall(function()
    for row in sqlite.nrows("SELECT * FROM L(''return function() return sqlite.fetch_first(\"SELECT count(*) as c FROM inner_t\").c end'')") do
    end
  end)
  check("L into make_vtable blocked", not ok1 and tostring(err1):find("vtable cannot be used from nested context") ~= nil)

  -- Test 2: L callback tries to SELECT from L -> should also fail
  local ok2, err2 = pcall(function()
    for row in sqlite.nrows("SELECT * FROM L(''return function() return sqlite.fetch_first(\"SELECT * FROM L(''''return 1'''')\").value end'')") do
    end
  end)
  check("L into L blocked", not ok2 and tostring(err2):find("vtable cannot be used from nested context") ~= nil)

  return table.concat(out, "\n")
');
