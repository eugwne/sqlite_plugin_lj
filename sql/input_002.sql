select load_extension('./libsqlite_plugin_lj');
select use_function_storage('tbl_lua_code_storage');
select const_x();
select const_x2();
select make_stored_fn('inc', 'return function(a) return a + 1 end', 1);
select inc(14) -1;
select make_stored_fn('echo1', 'return function(a) return "echo ["..tostring(a) .."]" end', 1);
select inc(15) -1;
select L('config["use_traceback"] = 0');
select make_stored_fn('echo1', 'return function(a) return "echo ["..tostring(a) .."]" end', 1);
select L('
    local increment_w = function(a)
        return a + 1
    end
    create_function("inc_w", increment_w, 1)
');
select inc(-1377409902473561268), inc_w(-1377409902473561268);
select drop_function('echo1', 1);

