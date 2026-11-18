# Flutter's Windows plugin CMakeLists fetch their own dependencies while
# generating the build tree (media_kit: libmpv + ANGLE archives,
# webview_windows: nuget.exe). Those file(DOWNLOAD) calls have no timeout, so a
# stalled connection parks the build at "Building Windows application..." with
# no output for hours. Seed the artifacts from the repository cache instead and
# pin nuget, so generation never waits on the network.
# Populate the cache with scripts/prepare_windows_native_deps.ps1.
get_filename_component(WEBHTV_REPO_ROOT "${CMAKE_CURRENT_LIST_DIR}/../../../.." ABSOLUTE)
set(WEBHTV_WIN_DEPS_DIR "${WEBHTV_REPO_ROOT}/.local/win-deps" CACHE PATH "Cached Windows build dependencies")

function(_webhtv_seed_artifact DIRECTORY NAME ALGORITHM EXPECTED_HASH)
  set(_target "${DIRECTORY}/${NAME}")
  if(EXISTS "${_target}")
    file(${ALGORITHM} "${_target}" _actual)
    if(_actual STREQUAL EXPECTED_HASH)
      return()
    endif()
    file(REMOVE "${_target}")
  endif()
  set(_source "${WEBHTV_WIN_DEPS_DIR}/${NAME}")
  if(NOT EXISTS "${_source}")
    message(FATAL_ERROR "Missing ${NAME} in ${WEBHTV_WIN_DEPS_DIR}. Run scripts/prepare_windows_native_deps.ps1 first.")
  endif()
  file(${ALGORITHM} "${_source}" _actual)
  if(NOT _actual STREQUAL EXPECTED_HASH)
    message(FATAL_ERROR "Cached ${NAME} is corrupt (${ALGORITHM} ${_actual}). Delete ${_source} and rerun scripts/prepare_windows_native_deps.ps1.")
  endif()
  file(COPY "${_source}" DESTINATION "${DIRECTORY}")
  message(STATUS "Seeded ${NAME}")
endfunction()

if(NOT EXISTS "${WEBHTV_WIN_DEPS_DIR}/manifest.json")
  message(FATAL_ERROR "Windows build dependencies are not prepared. Run scripts/prepare_windows_native_deps.ps1 first.")
endif()

# Keep the four artifacts below in sync with the versions those plugin
# CMakeLists declare; a plugin bump that changes a name silently restores the
# download path.
# media_kit_libs_windows_video/windows/CMakeLists.txt
_webhtv_seed_artifact("${CMAKE_BINARY_DIR}" "mpv-dev-x86_64-20230924-git-652a1dd.7z" MD5 a832ef24b3a6ff97cd2560b5b9d04cd8)
_webhtv_seed_artifact("${CMAKE_BINARY_DIR}" "ANGLE.7z" MD5 e866f13e8d552348058afaafe869b1ed)

# webview_windows/windows/CMakeLists.txt: find_program(NUGET nuget) is a no-op
# once NUGET is set, which skips both the nuget.exe download and the PATH probe.
_webhtv_seed_artifact("${CMAKE_BINARY_DIR}" "nuget.exe" SHA256 852b71cc8c8c2d40d09ea49d321ff56fd2397b9d6ea9f96e532530307bbbafd3)
# FORCE: an earlier configure stored NUGET-NOTFOUND, and a non-forced CACHE
# write would leave that stale value in place.
set(NUGET "${WEBHTV_WIN_DEPS_DIR}/nuget.exe" CACHE FILEPATH "Pinned nuget used by webview_windows" FORCE)

# sqlite3_flutter_libs/windows/CMakeLists.txt pulls sqlite-autoconf-3520000 with
# FetchContent (untimed URL download on every cold build tree). Hand it the
# cached sources instead.
set(WEBHTV_SQLITE_SOURCE_DIR "${WEBHTV_WIN_DEPS_DIR}/sqlite3-src/sqlite-autoconf-3520000")
if(NOT EXISTS "${WEBHTV_SQLITE_SOURCE_DIR}/sqlite3.c")
  message(FATAL_ERROR "Missing extracted sqlite3 sources in ${WEBHTV_WIN_DEPS_DIR}. Run scripts/prepare_windows_native_deps.ps1 first.")
endif()
set(FETCHCONTENT_SOURCE_DIR_SQLITE3 "${WEBHTV_SQLITE_SOURCE_DIR}" CACHE PATH "Cached sqlite3 amalgamation" FORCE)
