cmake_minimum_required(VERSION 3.14)

project(sqlite_plugin_lj LANGUAGES C CXX)

enable_testing()
find_package(Python3 COMPONENTS Interpreter REQUIRED)
find_package(SQLite3 REQUIRED)
find_package(Threads REQUIRED)

add_library(${PROJECT_NAME} SHARED src/plugin.c)

option(SQLITE_PLUGIN_LJ_ENABLE_ASAN "Enable AddressSanitizer for sqlite_plugin_lj target only" OFF)
option(SQLITE_PLUGIN_LJ_PORTABLE_RPATH "Use origin-based runtime search path for distributable binaries" OFF)

# Enforce strict warning policy for this project target.
if(MSVC)
    target_compile_options(${PROJECT_NAME} PRIVATE /W4 /WX)
else()
    target_compile_options(${PROJECT_NAME} PRIVATE -Wall -Wextra -Wpedantic -Werror)
endif()

if(SQLITE_PLUGIN_LJ_ENABLE_ASAN)
    message(STATUS "AddressSanitizer enabled for target: ${PROJECT_NAME}")
    if(MSVC)
        target_compile_options(${PROJECT_NAME} PRIVATE /fsanitize=address)
        target_link_options(${PROJECT_NAME} PRIVATE /fsanitize=address)
    else()
        target_compile_options(${PROJECT_NAME} PRIVATE -fsanitize=address -fno-omit-frame-pointer)
        target_link_options(${PROJECT_NAME} PRIVATE -fsanitize=address)
    endif()
endif()

# Optional SQLite headers (sqlite3ext.h) detection.
# Priority: SQLITE3_INCLUDE_DIR env var, then vcpkg (VCPKG_ROOT + triplet).
set(SQLITE3_INCLUDE_DIR "")
if(DEFINED ENV{SQLITE3_INCLUDE_DIR})
    set(SQLITE3_INCLUDE_DIR "$ENV{SQLITE3_INCLUDE_DIR}")
elseif(DEFINED ENV{VCPKG_ROOT})
    set(_vcpkg_root "$ENV{VCPKG_ROOT}")
    if(DEFINED ENV{VCPKG_TARGET_TRIPLET})
        set(_vcpkg_triplet "$ENV{VCPKG_TARGET_TRIPLET}")
    elseif(DEFINED ENV{VCPKG_DEFAULT_TRIPLET})
        set(_vcpkg_triplet "$ENV{VCPKG_DEFAULT_TRIPLET}")
    else()
        set(_vcpkg_triplet "x64-windows")
    endif()
    set(_vcpkg_inc "${_vcpkg_root}/installed/${_vcpkg_triplet}/include")
    if(EXISTS "${_vcpkg_inc}/sqlite3ext.h")
        set(SQLITE3_INCLUDE_DIR "${_vcpkg_inc}")
    endif()
endif()
if(SQLITE3_INCLUDE_DIR)
    message(STATUS "Using SQLite headers from: ${SQLITE3_INCLUDE_DIR}")
    target_include_directories(${PROJECT_NAME} PRIVATE "${SQLITE3_INCLUDE_DIR}")
else()
    message(WARNING "SQLite headers not found. Set SQLITE3_INCLUDE_DIR or VCPKG_ROOT so sqlite3ext.h is available.")
endif()

set_target_properties(${PROJECT_NAME} PROPERTIES POSITION_INDEPENDENT_CODE ON)
if(SQLITE_PLUGIN_LJ_PORTABLE_RPATH AND NOT WIN32)
    if(APPLE)
        set(_portable_rpath "@loader_path")
    else()
        set(_portable_rpath "\$ORIGIN")
    endif()
    set_target_properties(${PROJECT_NAME} PROPERTIES
        BUILD_WITH_INSTALL_RPATH TRUE
        BUILD_RPATH "${_portable_rpath}"
        INSTALL_RPATH "${_portable_rpath}"
        INSTALL_RPATH_USE_LINK_PATH FALSE
    )
endif()

set(LUA_SCRIPT_FILES
    src/sqlite_lj.lua
    src/sqlite_capi.lua
    src/sqlite_shared.lua
)

set(CMAKE_VERBOSE_MAKEFILE ON)

set(USE_SYSTEM_LUAJIT OFF)
if(DEFINED ENV{LUAJIT_INCLUDE_DIR} AND DEFINED ENV{LUAJIT_LIBRARY} AND DEFINED ENV{LUAJIT_BIN})
    set(LUAJIT_INCLUDE_DIR "$ENV{LUAJIT_INCLUDE_DIR}")
    set(LUAJIT_LIBRARY "$ENV{LUAJIT_LIBRARY}")
    set(LUAJIT_BIN "$ENV{LUAJIT_BIN}")

    if(EXISTS "${LUAJIT_INCLUDE_DIR}" AND EXISTS "${LUAJIT_LIBRARY}" AND EXISTS "${LUAJIT_BIN}")
        set(USE_SYSTEM_LUAJIT ON)
    else()
        message(WARNING "System LuaJIT paths are set but not found. Falling back to CMake-managed LuaJIT build.")
    endif()
endif()

if(USE_SYSTEM_LUAJIT)
    target_include_directories(${PROJECT_NAME} PRIVATE "${LUAJIT_INCLUDE_DIR}")
    target_link_libraries(${PROJECT_NAME} PRIVATE "${LUAJIT_LIBRARY}")
else()
    # use github version
    include(FetchContent)

    FetchContent_Declare(luajit_sources
            GIT_REPOSITORY https://github.com/LuaJIT/LuaJIT.git
            GIT_TAG    	5790d25
    )

    FetchContent_MakeAvailable(luajit_sources)

    include(ExternalProject)
    set(LUAJIT_SRC_DIR "${luajit_sources_SOURCE_DIR}/src")
    if(MSVC)
        ExternalProject_Add(ext_luajit
            SOURCE_DIR ${luajit_sources_SOURCE_DIR}
            DOWNLOAD_COMMAND ""
            CONFIGURE_COMMAND ""
            BUILD_COMMAND ${CMAKE_COMMAND} -E chdir ${LUAJIT_SRC_DIR} cmd /c msvcbuild.bat
            BUILD_IN_SOURCE true
            INSTALL_COMMAND ""
        )

        target_include_directories(${PROJECT_NAME} PRIVATE "${LUAJIT_SRC_DIR}")
        add_dependencies(${PROJECT_NAME} ext_luajit)
        target_link_libraries(${PROJECT_NAME} PRIVATE "${LUAJIT_SRC_DIR}/lua51.lib")
        set(LUAJIT_BIN "${LUAJIT_SRC_DIR}/luajit.exe")
    else()
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
        target_link_libraries(${PROJECT_NAME} PRIVATE "${CMAKE_CURRENT_BINARY_DIR}/libluajit-5.1${CMAKE_SHARED_LIBRARY_SUFFIX}")
        set(LUAJIT_BIN "${CMAKE_CURRENT_BINARY_DIR}/luajit/bin/luajit")
    endif()

endif()

if(USE_SYSTEM_LUAJIT)
    set(LUA_PATH "${CMAKE_CURRENT_BINARY_DIR}/luajit/share/luajit-2.1/?.lua\;${CMAKE_CURRENT_BINARY_DIR}/luajit/share/luajit-2.1/?/?.lua\;\;")
elseif(MSVC)
    set(LUA_PATH "${LUAJIT_SRC_DIR}/?.lua\;${LUAJIT_SRC_DIR}/?/?.lua\;\;")
else()
    set(LUA_PATH "${CMAKE_CURRENT_BINARY_DIR}/luajit/share/luajit-2.1/?.lua\;${CMAKE_CURRENT_BINARY_DIR}/luajit/share/luajit-2.1/?/?.lua\;\;")
endif()

set(BYTECODE_OBJECTS "")
foreach(LUA_FILE ${LUA_SCRIPT_FILES})

    get_filename_component(FILENAME_WE ${LUA_FILE} NAME_WE)
    set(OBJECT_FILE ${CMAKE_CURRENT_BINARY_DIR}/${FILENAME_WE}.h)

    if(USE_SYSTEM_LUAJIT)
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

target_include_directories(${PROJECT_NAME} PRIVATE ${CMAKE_CURRENT_BINARY_DIR})
if(UNIX AND NOT APPLE)
    target_link_options(${PROJECT_NAME} PRIVATE -Wl,--strip-all)
endif()
if(WIN32)
    add_custom_command(TARGET ${PROJECT_NAME} POST_BUILD
        COMMAND ${CMAKE_COMMAND} -E copy_if_different
            "$<TARGET_FILE:${PROJECT_NAME}>"
            "${CMAKE_BINARY_DIR}/libsqlite_plugin_lj.dll"
    )
    if(NOT USE_SYSTEM_LUAJIT)
        add_custom_command(TARGET ${PROJECT_NAME} POST_BUILD
            COMMAND ${CMAKE_COMMAND} -E copy_if_different
                "${LUAJIT_SRC_DIR}/lua51.dll"
                "${CMAKE_BINARY_DIR}/lua51.dll"
        )
    endif()
endif()

set(TEST_NAMES
     011
     010
     009
     001
     002
     003
     004
     005
     006
     007
     008
     012
     013
     014
     015
     016
     017
     018
     019
     020
     021
     022
     027
     024
     025
     026
     028
     029
     030
     031
     032
     033
     034
     035
     036
     037
     038
     039
     040
    # timed001
)

# set(TEST_NAMES    009)

function(resolve_fixture out_var root_dir filename kind test_name)
    file(GLOB_RECURSE MATCHES "${root_dir}/${filename}")
    list(LENGTH MATCHES MATCH_COUNT)
    if(MATCH_COUNT EQUAL 0)
        message(FATAL_ERROR "Missing ${kind} fixture for test ${test_name}: ${filename}")
    endif()
    if(MATCH_COUNT GREATER 1)
        message(FATAL_ERROR "Ambiguous ${kind} fixture for test ${test_name}: ${filename} -> ${MATCHES}")
    endif()
    list(GET MATCHES 0 MATCH_PATH)
    set(${out_var} "${MATCH_PATH}" PARENT_SCOPE)
endfunction()

# Copy each file to the build directory
foreach(TNAME ${TEST_NAMES})
    resolve_fixture(INPUT_FILE "${CMAKE_CURRENT_SOURCE_DIR}/sql" "input_${TNAME}.sql" "SQL" "${TNAME}")
    resolve_fixture(EXPECTED_FILE "${CMAKE_CURRENT_SOURCE_DIR}/expected" "output_${TNAME}.txt" "expected" "${TNAME}")

    configure_file(${INPUT_FILE} ${CMAKE_BINARY_DIR}/sql/input_${TNAME}.sql COPYONLY)
    configure_file(${EXPECTED_FILE} ${CMAKE_BINARY_DIR}/expected/output_${TNAME}.txt COPYONLY)
endforeach()

foreach(TNAME ${TEST_NAMES})
    add_test(
        NAME sqlite_plugin_test_${TNAME}
        COMMAND ${Python3_EXECUTABLE} ${CMAKE_CURRENT_SOURCE_DIR}/test.py --tests "${TNAME}"
    )
    set_tests_properties(sqlite_plugin_test_${TNAME} PROPERTIES WORKING_DIRECTORY ${CMAKE_BINARY_DIR})
endforeach()

# Vtable churn regression: ensure repeated create/drop remains stable.
add_test(
    NAME sqlite_plugin_vtable_churn_repro
    COMMAND ${Python3_EXECUTABLE} ${CMAKE_CURRENT_SOURCE_DIR}/test.py --sql-file ${CMAKE_CURRENT_SOURCE_DIR}/sql/vtables/input_023.sql
)
set_tests_properties(sqlite_plugin_vtable_churn_repro PROPERTIES WORKING_DIRECTORY ${CMAKE_BINARY_DIR})

# Regression test: plugin must work independently on multiple SQLite connections
# in the same process.
add_test(
    NAME sqlite_plugin_multiconnection_isolation
    COMMAND ${Python3_EXECUTABLE} ${CMAKE_CURRENT_SOURCE_DIR}/tests/multiconnection_isolation.py
)
set_tests_properties(sqlite_plugin_multiconnection_isolation PROPERTIES
    WORKING_DIRECTORY ${CMAKE_BINARY_DIR}
)

add_executable(sqlite_plugin_multithread_isolated_connections
    ${CMAKE_CURRENT_SOURCE_DIR}/tests/multithread_isolated_connections.cpp
)
set_property(TARGET sqlite_plugin_multithread_isolated_connections PROPERTY CXX_STANDARD 23)
set_property(TARGET sqlite_plugin_multithread_isolated_connections PROPERTY CXX_STANDARD_REQUIRED ON)
set_property(TARGET sqlite_plugin_multithread_isolated_connections PROPERTY CXX_EXTENSIONS OFF)
set(SQLITE3_TEST_LINK_LIB "")
if(APPLE AND DEFINED ENV{SQLITE3_BIN})
    get_filename_component(_sqlite3_bin_dir "$ENV{SQLITE3_BIN}" DIRECTORY)
    get_filename_component(_sqlite3_prefix "${_sqlite3_bin_dir}" DIRECTORY)
    set(_sqlite3_brew_lib "${_sqlite3_prefix}/lib/libsqlite3.dylib")
    if(EXISTS "${_sqlite3_brew_lib}")
        set(SQLITE3_TEST_LINK_LIB "${_sqlite3_brew_lib}")
        message(STATUS "Using Homebrew SQLite for multithread test: ${SQLITE3_TEST_LINK_LIB}")
    endif()
endif()
if(SQLITE3_TEST_LINK_LIB)
    target_link_libraries(sqlite_plugin_multithread_isolated_connections PRIVATE "${SQLITE3_TEST_LINK_LIB}" Threads::Threads)
else()
    target_link_libraries(sqlite_plugin_multithread_isolated_connections PRIVATE SQLite::SQLite3 Threads::Threads)
endif()
if(MSVC)
    target_compile_options(sqlite_plugin_multithread_isolated_connections PRIVATE /WX)
else()
    target_compile_options(sqlite_plugin_multithread_isolated_connections PRIVATE -Werror)
endif()

add_executable(sqlite_plugin_multithread_vtable_queries
    ${CMAKE_CURRENT_SOURCE_DIR}/tests/multithread_vtable_queries.cpp
)
set_property(TARGET sqlite_plugin_multithread_vtable_queries PROPERTY CXX_STANDARD 23)
set_property(TARGET sqlite_plugin_multithread_vtable_queries PROPERTY CXX_STANDARD_REQUIRED ON)
set_property(TARGET sqlite_plugin_multithread_vtable_queries PROPERTY CXX_EXTENSIONS OFF)
if(SQLITE3_TEST_LINK_LIB)
    target_link_libraries(sqlite_plugin_multithread_vtable_queries PRIVATE "${SQLITE3_TEST_LINK_LIB}" Threads::Threads)
else()
    target_link_libraries(sqlite_plugin_multithread_vtable_queries PRIVATE SQLite::SQLite3 Threads::Threads)
endif()
if(MSVC)
    target_compile_options(sqlite_plugin_multithread_vtable_queries PRIVATE /WX)
else()
    target_compile_options(sqlite_plugin_multithread_vtable_queries PRIVATE -Werror)
endif()

add_executable(sqlite_plugin_thread_guard_same_connection
    ${CMAKE_CURRENT_SOURCE_DIR}/tests/thread_guard_same_connection.cpp
)
set_property(TARGET sqlite_plugin_thread_guard_same_connection PROPERTY CXX_STANDARD 23)
set_property(TARGET sqlite_plugin_thread_guard_same_connection PROPERTY CXX_STANDARD_REQUIRED ON)
set_property(TARGET sqlite_plugin_thread_guard_same_connection PROPERTY CXX_EXTENSIONS OFF)
if(SQLITE3_TEST_LINK_LIB)
    target_link_libraries(sqlite_plugin_thread_guard_same_connection PRIVATE "${SQLITE3_TEST_LINK_LIB}" Threads::Threads)
else()
    target_link_libraries(sqlite_plugin_thread_guard_same_connection PRIVATE SQLite::SQLite3 Threads::Threads)
endif()
if(MSVC)
    target_compile_options(sqlite_plugin_thread_guard_same_connection PRIVATE /WX)
else()
    target_compile_options(sqlite_plugin_thread_guard_same_connection PRIVATE -Werror)
endif()

add_test(
    NAME sqlite_plugin_multithread_isolated_connections
    COMMAND sqlite_plugin_multithread_isolated_connections
        $<TARGET_FILE:sqlite_plugin_lj>
        ${CMAKE_BINARY_DIR}/sql
        ${CMAKE_BINARY_DIR}/expected
)
add_test(
    NAME sqlite_plugin_multithread_vtable_queries
    COMMAND sqlite_plugin_multithread_vtable_queries
        $<TARGET_FILE:sqlite_plugin_lj>
)
add_test(
    NAME sqlite_plugin_thread_guard_same_connection
    COMMAND sqlite_plugin_thread_guard_same_connection
        $<TARGET_FILE:sqlite_plugin_lj>
)
if(WIN32)
    get_filename_component(_sqlite3_lib_dir "${SQLite3_LIBRARY}" DIRECTORY)
    get_filename_component(_sqlite3_prefix "${_sqlite3_lib_dir}" DIRECTORY)
    set(_sqlite3_bin_dir "${_sqlite3_prefix}/bin")
    set_tests_properties(sqlite_plugin_multithread_isolated_connections PROPERTIES
        WORKING_DIRECTORY ${CMAKE_BINARY_DIR}
        ENVIRONMENT "PATH=$<TARGET_FILE_DIR:sqlite_plugin_lj>;${_sqlite3_bin_dir};$ENV{PATH}"
    )
    set_tests_properties(sqlite_plugin_multithread_vtable_queries PROPERTIES
        WORKING_DIRECTORY ${CMAKE_BINARY_DIR}
        ENVIRONMENT "PATH=$<TARGET_FILE_DIR:sqlite_plugin_lj>;${_sqlite3_bin_dir};$ENV{PATH}"
    )
    set_tests_properties(sqlite_plugin_thread_guard_same_connection PROPERTIES
        WORKING_DIRECTORY ${CMAKE_BINARY_DIR}
        ENVIRONMENT "PATH=$<TARGET_FILE_DIR:sqlite_plugin_lj>;${_sqlite3_bin_dir};$ENV{PATH}"
    )
else()
    set_tests_properties(sqlite_plugin_multithread_isolated_connections PROPERTIES
        WORKING_DIRECTORY ${CMAKE_BINARY_DIR}
    )
    set_tests_properties(sqlite_plugin_multithread_vtable_queries PROPERTIES
        WORKING_DIRECTORY ${CMAKE_BINARY_DIR}
    )
    set_tests_properties(sqlite_plugin_thread_guard_same_connection PROPERTIES
        WORKING_DIRECTORY ${CMAKE_BINARY_DIR}
    )
endif()
