.load ./libsqlite_plugin_lj
select L('sqlite.config.use_traceback = 0');
select L('
  local ok, err = pcall(function()
    return sqlite.fetch_first("select ?1 as v", {[1] = function() end})
  end)
  if not ok and tostring(err):match("api_bind_any: unsupported type function") then
    return "PASS: fetch_first bind error triggered"
  else
    return "FAIL: unexpected fetch_first result"
  end
');
