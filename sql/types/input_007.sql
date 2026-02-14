select load_extension('./libsqlite_plugin_lj');

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
for a in sqlite.urows [[select (x''ff00ff''); ]] do
    return blob_to_hex_string(a)
end
');

select hex(L('
return sqlite.make_blob ({0xF5, 0x00, 0xF9})'
)),
hex(L('
return sqlite.make_blob ({})'
)),
hex(L('
return sqlite.make_blob ()'
));

select L('
for a, b in sqlite.urows ("select ?1, ?2", {
    sqlite.make_blob ({0xF5, 0x00, 0xF9}),
    sqlite.make_blob ()
    }) do
    return blob_to_hex_string(a) .. "\t" .. tostring(b.data) .. "\t" .. tostring(b.size)
end
');

