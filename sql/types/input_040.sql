.load ./libsqlite_plugin_lj
select L('
    sqlite.create_function("ret_pos_inf", function() return math.huge end, 0)
    sqlite.create_function("ret_neg_inf", function() return -math.huge end, 0)
    return "PASS register inf functions"
');
select case when ret_pos_inf() > 1e308 then 'PASS return +inf stays float' else 'FAIL return +inf stays float' end;
select case when ret_neg_inf() < -1e308 then 'PASS return -inf stays float' else 'FAIL return -inf stays float' end;
select L('
    local out = {}
    local pos = sqlite.fetch_first("SELECT (?1 > 1e308) AS v", {math.huge})
    out[#out + 1] = (tonumber(pos.v) == 1 and "PASS bind +inf stays float" or ("FAIL bind +inf stays float: " .. tostring(pos.v)))
    local neg = sqlite.fetch_first("SELECT (?1 < -1e308) AS v", {-math.huge})
    out[#out + 1] = (tonumber(neg.v) == 1 and "PASS bind -inf stays float" or ("FAIL bind -inf stays float: " .. tostring(neg.v)))
    return table.concat(out, "\n")
');
