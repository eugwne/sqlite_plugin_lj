-- Regression stress test: repeated make_vtable/drop churn should remain stable.
-- This fixture is wired as a dedicated CTest target.

select load_extension('./libsqlite_plugin_lj');

select L('
  sqlite.config.use_traceback = 0
  for i = 1, 260 do
    sqlite.run_sql("DROP TABLE IF EXISTS TEMP.gc_vt")
    sqlite.make_vtable("gc_vt", {
      columns = {"a", "b"},
      rows = {{1, 2}, {3, 4}}
    })

    local r = sqlite.fetch_first("select count(*) as c from gc_vt")
    if (not r) or tonumber(r.c) ~= 2 then
      return "FAIL:count:" .. tostring(i)
    end
  end
  return "PASS:vtable-churn-stable"
');
