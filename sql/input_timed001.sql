select load_extension('./libsqlite_plugin_lj');
select('-------------');
select make_stored_fn('L', '
return function (code_text, ...)
    local fn_env = {}
    setmetatable(fn_env, { __index = _G })
    fn_env[''arg''] = {...}

    local fn, err = loadstring(code_text, name, "t", fn_env)
    if not fn then
        local msg = ''Create failed [''.. name .. '']\n'' .. tostring(err)
        return error(msg)
    end
    return fn()
end
');

create table data as
select random() as x
from generate_series(1, 1000000);

.timer on
select max(inc(x)) from data;
select max(L("return arg[1] + 1", x)) from data;

select max(x+1) from data;