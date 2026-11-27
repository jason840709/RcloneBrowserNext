cmake_minimum_required(VERSION 3.24)
project(RBNUnicodeRuntime LANGUAGES CXX)
if(NOT WIN32 OR NOT CMAKE_CXX_COMPILER_ID STREQUAL "Clang" OR NOT CMAKE_CXX_COMPILER_FRONTEND_VARIANT STREQUAL "MSVC")
  message(FATAL_ERROR "RBNUnicode.dll requires the Windows x64 MSVC environment")
endif()
if(NOT IS_DIRECTORY "${RBN_ICU_SOURCE}/icuSources")
  message(FATAL_ERROR "The verified ICU source directory is required")
endif()

set(CMAKE_CXX_STANDARD 14)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded")
set(CMAKE_RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/bin")
set(BUILD_SHARED_LIBS ON)
set(install_directory native)
set(SWIFT_SYSTEM_NAME windows)
include(GNUInstallDirs)

# Match the pinned official C++ build, except enable ICU's _74 C API renaming.
# Its top-level project enables Swift; only its C++ icuSources is included here.
add_compile_definitions(
  U_ATTRIBUTE_DEPRECATED=
  U_SHOW_CPLUSPLUS_API=1 U_SHOW_INTERNAL_API=1 U_TIMEZONE_PACKAGE="icutz44l"
  FORTIFY_SOURCE=2 STD_INSPIRED MAC_OS_X_VERSION_MIN_REQUIRED=101500
  U_HAVE_STRTOD_L=1 U_HAVE_XLOCALE_H=1 U_HAVE_STRING_VIEW=1
  U_DISABLE_RENAMING=0 U_COMBINED_IMPLEMENTATION U_COMMON_IMPLEMENTATION
  U_I18N_IMPLEMENTATION U_IO_IMPLEMENTATION ICU_DATA_DIR="/usr/share/icu"
  USE_PACKAGE_DATA=1 APPLE_ICU_CHANGES=1
  U_TIMEZONE=_timezone _CRT_SECURE_NO_DEPRECATE U_PLATFORM_USES_ONLY_WIN32_API)
add_compile_options(/bigobj)
add_subdirectory("${RBN_ICU_SOURCE}/icuSources" "${CMAKE_BINARY_DIR}/icuSources")
set_target_properties(_FoundationICU PROPERTIES OUTPUT_NAME RBNUnicode MSVC_RUNTIME_LIBRARY MultiThreaded)
