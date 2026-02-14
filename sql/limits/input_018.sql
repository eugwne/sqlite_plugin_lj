.load ./libsqlite_plugin_lj
select L('
  sqlite.config.use_traceback = 0

  local payload = string.rep("b", 50000)
  local chunk = "return function() return [[" .. payload .. "]] end"

  local ok = true
  local errtxt = ""
  for i = 1, 20 do
    local status, err = pcall(function()
      sqlite.make_fn("buf_lim_" .. i, chunk, 0)
    end)
    if not status then
      ok = false
      errtxt = tostring(err)
      break
    end
  end

  if (not ok) and errtxt:match("shared object storage limit exceeded") then
    return "PASS: shared buffer ceiling enforced"
  else
    return "FAIL: shared buffer ceiling enforced"
  end
');
