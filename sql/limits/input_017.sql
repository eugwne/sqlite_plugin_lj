.load ./libsqlite_plugin_lj
select L('
  sqlite.config.use_traceback = 0

  local ok = true
  local errtxt = ""
  for i = 1, 20 do
    local status, err = pcall(function()
      sqlite.create_function("ctx_lim_" .. i, function(a) return a end, 1)
    end)
    if not status then
      ok = false
      errtxt = tostring(err)
      break
    end
  end

  if (not ok) and errtxt:match("function context storage limit exceeded") then
    return "PASS: function context ceiling enforced"
  else
    return "FAIL: function context ceiling enforced"
  end
');
