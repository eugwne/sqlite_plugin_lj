-- Retrieve Lua script file paths from command-line arguments
local lua_files = {...}

-- Function to read a file and return its content as a string
local function read_file(file_path)
    local file = assert(io.open(file_path, "r"))
    local content = file:read("*a")
    file:close()
    return content
end

local get_underscore = function (name)
    return name:match("([^/\\]+)$") -- Extracts filename from path
            :gsub("[^%w_]", "_"):upper() -- Ensure variable name starts with a letter
end

-- Function to write Lua script content to a C header file
local function write_header(lua_files, output_file)
    local header = io.open(output_file, "w")

    -- Extract the filename portion of the output file path for the include guard
    local include_guard = get_underscore(output_file)

    header:write("#ifndef ", include_guard, "\n")
    header:write("#define ", include_guard, "\n\n")

    -- Write Lua script content as string literals
    for _, file_path in ipairs(lua_files) do
        local content = read_file(file_path)
        local variable_name = get_underscore(file_path)
        header:write("static const char ", variable_name, "[] = {\n")
        for i = 1, #content do
            header:write(string.format("%3d,", string.byte(content, i)))
            if i % 16 == 0 then
                header:write("\n")
            else
                header:write(" ")
            end
        end
        header:write(" 0\n};\n\n")
    end

    header:write("#endif /* ", include_guard, " */\n")

    header:close()
end

-- Output file for the generated header
local output_file = lua_files[#lua_files]

lua_files[#lua_files] = nil --remove output file from the list

-- Generate the header file
write_header(lua_files, output_file)

print("Lua scripts have been embedded into '" .. output_file .. "'.")

