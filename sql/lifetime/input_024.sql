.load ./libsqlite_plugin_lj
select L('
  sqlite.config.use_traceback = 0

  local function make_payload(i)
    local head = string.char(65 + (i % 26))
    return head .. ":" .. tostring(i) .. ":" .. string.rep("z", 8192)
  end

  local result = "PASS:bind_text_gc"
  for i = 1, 2000 do
    local payload = make_payload(i)
    local iter = sqlite.rows("select ?1 as v", {payload})
    payload = nil

    collectgarbage("collect")
    collectgarbage("collect")

    local row = iter()
    local expected = make_payload(i)
    if not row or row[1] ~= expected then
      result = "FAIL:bind_text_gc:" .. tostring(i)
      break
    end
    iter()
  end

  return result
');
