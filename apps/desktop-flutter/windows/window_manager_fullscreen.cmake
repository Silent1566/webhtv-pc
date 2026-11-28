# Patch only the Windows plugin in the build tree; never write to the pub cache.
find_package(Git REQUIRED)
set(window_manager_source "${FLUTTER_MANAGED_DIR}/ephemeral/.plugin_symlinks/window_manager/windows")
set(window_manager_patch "${CMAKE_CURRENT_LIST_DIR}/window_manager-0.5.2-fullscreen.patch")
set(window_manager_build "${CMAKE_CURRENT_BINARY_DIR}/window_manager_fullscreen")
set(window_manager_stage "${window_manager_build}/staging")
set(window_manager_sources window_manager.cpp window_manager_plugin.cpp)
file(MAKE_DIRECTORY "${window_manager_stage}")
set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS
  "${window_manager_patch}")
foreach(source IN LISTS window_manager_sources)
  # Start from pristine sources on every configure, regardless of timestamps.
  configure_file("${window_manager_source}/${source}" "${window_manager_stage}/${source}" COPYONLY)
endforeach()
execute_process(
  COMMAND "${CMAKE_COMMAND}" -E env "GIT_CEILING_DIRECTORIES=${window_manager_build}"
    "${GIT_EXECUTABLE}" apply --no-index --ignore-space-change "${window_manager_patch}"
  WORKING_DIRECTORY "${window_manager_stage}"
  RESULT_VARIABLE window_manager_patch_result
  ERROR_VARIABLE window_manager_patch_error)
if(NOT window_manager_patch_result STREQUAL "0")
  message(FATAL_ERROR "Cannot apply the window_manager 0.5.2 fullscreen patch: ${window_manager_patch_error}")
endif()
foreach(source IN LISTS window_manager_sources)
  configure_file("${window_manager_stage}/${source}" "${window_manager_build}/${source}" COPYONLY)
endforeach()
# The plugin includes window_manager.cpp directly; MSVC must recompile the
# including translation unit whenever that implementation changes.
file(SHA256 "${window_manager_build}/window_manager.cpp" window_manager_hash)
file(READ "${window_manager_stage}/window_manager_plugin.cpp" window_manager_entry)
set(window_manager_entry "${window_manager_entry}\n// window_manager.cpp: ${window_manager_hash}\n")
file(CONFIGURE OUTPUT "${window_manager_build}/window_manager_plugin.cpp"
  CONTENT "${window_manager_entry}" @ONLY)
set_property(TARGET window_manager_plugin PROPERTY SOURCES
  "${window_manager_build}/window_manager_plugin.cpp")
target_include_directories(window_manager_plugin PRIVATE "${window_manager_source}")
