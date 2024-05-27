cmake_minimum_required(VERSION 3.5)

project(sqlite_plugin_lj LANGUAGES C)

enable_testing()

add_library(${PROJECT_NAME} SHARED src/plugin.c)

set_target_properties(${PROJECT_NAME} PROPERTIES POSITION_INDEPENDENT_CODE ON)

set(LUA_SCRIPT_FILES
    "${CMAKE_CURRENT_SOURCE_DIR}/src/sqlite_lj.lua"
    "${CMAKE_CURRENT_SOURCE_DIR}/src/sqlite_capi.lua"
)

# install(FILES 
#     ${CMAKE_CURRENT_SOURCE_DIR}/src/sqlite_lj.lua
#     ${CMAKE_CURRENT_SOURCE_DIR}/src/sqlite_capi.lua
#  DESTINATION /usr/share/lua/5.1/)

add_custom_command(OUTPUT ${CMAKE_CURRENT_BINARY_DIR}/sqlite_lj.lua
    COMMAND ${CMAKE_COMMAND} -E copy ${CMAKE_CURRENT_SOURCE_DIR}/src/sqlite_lj.lua ${CMAKE_CURRENT_SOURCE_DIR}/src/sqlite_capi.lua
                                     ${CMAKE_CURRENT_BINARY_DIR}
    DEPENDS ${CMAKE_CURRENT_SOURCE_DIR}/src/sqlite_lj.lua
)

add_custom_target(sqlite_lj
    DEPENDS ${CMAKE_CURRENT_BINARY_DIR}/sqlite_lj.lua
            ${CMAKE_CURRENT_BINARY_DIR}/sqlite_capi.lua
    SOURCES ${CMAKE_CURRENT_SOURCE_DIR}/src/sqlite_lj.lua
            ${CMAKE_CURRENT_SOURCE_DIR}/src/sqlite_capi.lua)


set(CMAKE_VERBOSE_MAKEFILE ON)

if(DEFINED ENV{LUAJIT_INCLUDE_DIR} AND DEFINED ENV{LUAJIT_LIBRARY})
    set(LUAJIT_INCLUDE_DIR $ENV{LUAJIT_INCLUDE_DIR})
    set(LUAJIT_LIBRARY     $ENV{LUAJIT_LIBRARY}) 

    set(LUAJIT_BIN $ENV{LUAJIT_BIN})

    target_include_directories(${PROJECT_NAME} PRIVATE ${LUAJIT_INCLUDE_DIR})
    target_link_libraries(${PROJECT_NAME} PRIVATE ${LUAJIT_LIBRARY})
else()
    SET(CMAKE_SKIP_BUILD_RPATH  FALSE)
    SET(CMAKE_BUILD_WITH_INSTALL_RPATH TRUE)
    SET(CMAKE_INSTALL_RPATH "\${ORIGIN}")
    # use github version
    include(FetchContent)

    FetchContent_Declare(luajit_sources
            GIT_REPOSITORY https://github.com/LuaJIT/LuaJIT.git
            GIT_TAG    	5790d25
    )

    FetchContent_MakeAvailable(luajit_sources)

    include(ExternalProject)
    ExternalProject_Add(ext_luajit
    SOURCE_DIR ${luajit_sources_SOURCE_DIR}
    DOWNLOAD_COMMAND ""
    CONFIGURE_COMMAND ""
    BUILD_COMMAND make
    BUILD_IN_SOURCE true
    INSTALL_COMMAND make install PREFIX=${CMAKE_CURRENT_BINARY_DIR}/luajit 
    && cp -a "${CMAKE_CURRENT_BINARY_DIR}/luajit/lib/." "${CMAKE_CURRENT_BINARY_DIR}"
    )

    target_include_directories(${PROJECT_NAME} PRIVATE "${CMAKE_CURRENT_BINARY_DIR}/luajit/include/luajit-2.1")

    add_dependencies(${PROJECT_NAME} ext_luajit sqlite_lj)
    target_link_libraries(${PROJECT_NAME} PRIVATE "${CMAKE_CURRENT_BINARY_DIR}/libluajit-5.1.so")

    set(LUAJIT_BIN ${CMAKE_CURRENT_BINARY_DIR}/luajit/bin/luajit)

endif()

set(LUA_SCRIPT_GENERATOR_SCRIPT "${CMAKE_CURRENT_SOURCE_DIR}/generate_lua_scripts.lua")
set(LUA_SCRIPT_HEADER_FILE "${CMAKE_CURRENT_BINARY_DIR}/lua_scripts.h")

if (DEFINED ENV{LUAJIT_LIBRARY})
    set(GEN_DEPS ${LUA_SCRIPT_GENERATOR_SCRIPT} ${LUA_SCRIPT_FILES})
else()
    set(GEN_DEPS ${LUA_SCRIPT_GENERATOR_SCRIPT} ${LUA_SCRIPT_FILES} ext_luajit)
endif()

add_custom_command(
    OUTPUT "${LUA_SCRIPT_HEADER_FILE}"
    COMMAND ${CMAKE_COMMAND} -E env LUA_PATH=${CMAKE_CURRENT_SOURCE_DIR}/?.lua ${LUAJIT_BIN} ${LUA_SCRIPT_GENERATOR_SCRIPT} ${LUA_SCRIPT_FILES} ${LUA_SCRIPT_HEADER_FILE}
    DEPENDS ${GEN_DEPS} 
    COMMENT "Generating Lua script header file"
)


add_custom_target(generate_lua_scripts DEPENDS "${LUA_SCRIPT_HEADER_FILE}")
add_dependencies(${PROJECT_NAME} generate_lua_scripts)
target_include_directories(${PROJECT_NAME} PRIVATE "${CMAKE_CURRENT_BINARY_DIR}")


set(TEST_NAMES
    001
    002
    003
    004
    005
    006
    007
    008
    # timed001
)

# Copy each file to the build directory
foreach(TNAME ${TEST_NAMES})
    configure_file(sql/input_${TNAME}.sql ${CMAKE_BINARY_DIR}/sql/input_${TNAME}.sql COPYONLY)
    configure_file(expected/output_${TNAME}.txt ${CMAKE_BINARY_DIR}/expected/output_${TNAME}.txt COPYONLY)
endforeach()

add_test(
    NAME sqlite_plugin_tests
    COMMAND ${CMAKE_CURRENT_SOURCE_DIR}/test.sh "${TEST_NAMES}"
)

# Set the working directory for the test
set_tests_properties(sqlite_plugin_tests PROPERTIES WORKING_DIRECTORY ${CMAKE_BINARY_DIR})
