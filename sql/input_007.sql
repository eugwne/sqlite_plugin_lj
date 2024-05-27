select load_extension('./libsqlite_plugin_lj');
select use_function_storage('tbl_lua_code_storage');
select('-------------');

select hex(x'ff00ff');

select L('

_G.blob_to_hex_string = function (blob)
    local hex_string = ""
    for i = 0, blob.size - 1 do
        hex_string = hex_string .. string.format("%02X", blob.data[i])
    end
    return hex_string
end

');

select L('
for a in urows [[select (x''ff00ff''); ]] do print( blob_to_hex_string(a) ) end
');

select hex(L('
return make_blob ({0xF5, 0x00, 0xF9})'
)),
hex(L('
return make_blob ({})'
)),
hex(L('
return make_blob ()'
));

select L('
for a, b in urows ("select ?1, ?2", {
    make_blob ({0xF5, 0x00, 0xF9}),
    make_blob ()
    }) do 
    print( blob_to_hex_string(a), b.data, b.size ) 
end
');

