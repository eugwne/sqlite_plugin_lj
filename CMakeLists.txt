cmake_minimum_required(VERSION 3.5)

project(sqlite_plugin_lj LANGUAGES C)

enable_testing()

add_library(${PROJECT_NAME} SHARED src/plugin.c)

set_target_properties(${PROJECT_NAME} PROPERTIES POSITION_INDEPENDENT_CODE ON)

set(LUA_SCRIPT_FILES
    src/sqlite_lj.lua
    src/sqlite_capi.lua
)

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

    add_dependencies(${PROJECT_NAME} ext_luajit)
    target_link_libraries(${PROJECT_NAME} PRIVATE "${CMAKE_CURRENT_BINARY_DIR}/libluajit-5.1.so")

    set(LUAJIT_BIN ${CMAKE_CURRENT_BINARY_DIR}/luajit/bin/luajit)

endif()

set(LUA_PATH "/usr/share/luajit-2.1.0-beta3/?.lua\;${CMAKE_CURRENT_BINARY_DIR}/luajit/share/luajit-2.1/?.lua\;\;")

set(BYTECODE_OBJECTS "")
foreach(LUA_FILE ${LUA_SCRIPT_FILES})

    get_filename_component(FILENAME_WE ${LUA_FILE} NAME_WE)
    set(OBJECT_FILE ${CMAKE_CURRENT_BINARY_DIR}/${FILENAME_WE}.obj)

    if(DEFINED ENV{LUAJIT_LIBRARY})
        add_custom_command(
            OUTPUT ${OBJECT_FILE}
            COMMAND ${CMAKE_COMMAND} -E env LUA_PATH="${LUA_PATH}" 
                    ${LUAJIT_BIN} -b ${CMAKE_CURRENT_SOURCE_DIR}/${LUA_FILE} ${OBJECT_FILE}
            DEPENDS ${CMAKE_CURRENT_SOURCE_DIR}/${LUA_FILE}
            COMMENT "Compiling ${LUA_FILE} to ${OBJECT_FILE} with system luajit"
        )
    else()
        add_custom_command(
            OUTPUT ${OBJECT_FILE}
            COMMAND ${CMAKE_COMMAND} -E env LUA_PATH="${LUA_PATH}" 
                    ${LUAJIT_BIN} -b ${CMAKE_CURRENT_SOURCE_DIR}/${LUA_FILE} ${OBJECT_FILE}
            DEPENDS ${CMAKE_CURRENT_SOURCE_DIR}/${LUA_FILE} ext_luajit
            COMMENT "Compiling ${LUA_FILE} to ${OBJECT_FILE} with luajit from git"
        )
    endif()

    list(APPEND BYTECODE_OBJECTS ${OBJECT_FILE})
endforeach()

add_custom_target(generate_bytecode_objects ALL DEPENDS ${BYTECODE_OBJECTS})
add_dependencies(${PROJECT_NAME} generate_bytecode_objects)

target_link_libraries(${PROJECT_NAME} PRIVATE ${BYTECODE_OBJECTS})
set_target_properties(${PROJECT_NAME} PROPERTIES LINK_FLAGS "-Wl,--strip-all")


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
