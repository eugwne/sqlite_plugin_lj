select load_extension('./libsqlite_plugin_lj');

select L('
    sqlite.make_int("const_x", 9999)
    sqlite.make_int("const_x2", 10000)
    sqlite.register_internal_function("make_fn")
');
select const_x();
select const_x2();
select make_fn('inc', 'return function(a) return a + 1 end', 1);
select inc(14) -1;
select make_fn('echo1', 'return function(a) return "echo ["..tostring(a) .."]" end', 1);
select echo1(17);
select inc(15) -1;
select L('sqlite.config["use_traceback"] = 0');
select make_fn('echo1', 'return function(a) return "updated echo ["..tostring(a) .."]" end', 1);
select echo1(21);
select L('
    local increment_w = function(a)
        return a + 1
    end
    sqlite.create_function("inc_w", increment_w, 1)
');
select inc(-1377409902473561268), inc_w(-1377409902473561268);
