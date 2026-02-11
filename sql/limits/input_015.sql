.load ./libsqlite_plugin_lj
select L('
  sqlite.config.use_traceback = 0
  local payload = string.rep("a", 5 * 1024 * 1024)
  local chunk = "return function() return [[" .. payload .. "]] end"

  local ok, err = pcall(function()
    sqlite.make_fn("too_big", chunk, 0)
  end)

  if (not ok) and tostring(err):match("shared object storage limit exceeded") then
    return "PASS: shared object size ceiling enforced"
  else
    return "FAIL: shared object size ceiling enforced"
  end
');
