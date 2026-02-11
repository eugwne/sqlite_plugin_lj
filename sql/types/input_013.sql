.load ./libsqlite_plugin_lj
select L('
  sqlite.config.use_traceback = 0
  local out = {}

  local function run_matrix(kind, cases, run_one)
    for _, c in ipairs(cases) do
      local ok, err = pcall(run_one, c.value)
      local name = kind .. " " .. c.name
      if c.expect == "ok" then
        out[#out + 1] = (ok and "PASS " or "FAIL ") .. name
      else
        local matched = (not ok) and tostring(err):match(c.err_pat or "")
        out[#out + 1] = (matched and "PASS " or "FAIL ") .. name
      end
    end
  end

  local bind_cases = {
    { name = "sqlite.int_t",    value = sqlite.int_t(7),            expect = "ok"  },
    { name = "sqlite.int64_t",  value = sqlite.int64_t(8),          expect = "ok"  },
    { name = "sqlite.uint64_t", value = sqlite.uint64_t(9),         expect = "ok"  },
    { name = "sqlite.double_t", value = sqlite.double_t(2.5),       expect = "ok"  },
    { name = "NULL",            value = NULL,                        expect = "ok"  },
    { name = "number int",      value = 42,                          expect = "ok"  },
    { name = "number real",     value = 3.25,                        expect = "ok"  },
    { name = "string",          value = "abc",                       expect = "ok"  },
    { name = "boolean",         value = true,                        expect = "ok"  },
    { name = "blob empty",      value = sqlite.make_blob({}),        expect = "ok"  },
    { name = "blob bytes",      value = sqlite.make_blob({65,66,67}),expect = "ok"  },
    { name = "invalid table",   value = {foo = 1},                   expect = "err", err_pat = "unsupported type table" },
    { name = "invalid function",value = function() end,              expect = "err", err_pat = "unsupported type function" }
  }

  run_matrix("bind", bind_cases, function(v)
    sqlite.fetch_first("select ?1 as v", {[1] = v})
  end)

  return table.concat(out, "\n")
');
