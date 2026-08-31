cmake_minimum_required(VERSION 3.21)

# ============================================================================
# macOS native payload
# ============================================================================
# The macOS frontend is the Cocoa app in desktop-apps/macos.
# This is the CMake entry point for macOS: it builds native libraries, cocoa app
# bundles and common-files if not available.

project(EuroOfficeMacPayload VERSION 1.0 LANGUAGES CXX C OBJC OBJCXX)

set(CMAKE_FIND_PACKAGE_PREFER_CONFIG ON)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_INCLUDE_CURRENT_DIR ON)

set(CORE_ROOT_DIR "${CMAKE_CURRENT_LIST_DIR}/../../core")
set(DESKTOP_SDK_ROOT "${CMAKE_CURRENT_LIST_DIR}/../../desktop-sdk")

# Pulls in CEF (but, on macOS, neither Qt nor V8) via build_3rdparty.py.
set(BUILD_DESKTOP TRUE CACHE INTERNAL "tell common to prepare third party for desktop")
include(${CORE_ROOT_DIR}/common.cmake)

if(NOT APPLE)
    message(FATAL_ERROR
        "build/macos/CMakeLists.txt is the macOS entry point. "
        "On Windows and Linux, configure desktop-apps/win-linux/ instead.")
endif()

# ---------------------------------------------------------------------------
# Shared core libraries
# ---------------------------------------------------------------------------
if(NOT TARGET hunspell-wrapper)
    add_subdirectory(${CORE_ROOT_DIR}/Common/3dParty/hunspell/qt hunspell-wrapper)
endif()

if(NOT TARGET PdfFile)
    add_subdirectory(${CORE_ROOT_DIR}/PdfFile PdfFile)
endif()

if(NOT TARGET XpsFile)
    add_subdirectory(${CORE_ROOT_DIR}/XpsFile XpsFile)
endif()

if(NOT TARGET DjVuFile)
    add_subdirectory(${CORE_ROOT_DIR}/DjVuFile DjVuFile)
endif()

if(NOT TARGET ooxmlsignature)
    add_subdirectory(${CORE_ROOT_DIR}/DesktopEditor/xmlsec/src ooxmlsignature)
endif()

if(NOT TARGET kernel)
    add_subdirectory(${CORE_ROOT_DIR}/Common kernel)
endif()

if(NOT TARGET kernel_network)
    add_subdirectory(${CORE_ROOT_DIR}/Common/Network kernel_network)
endif()

if(NOT TARGET UnicodeConverter)
    add_subdirectory(${CORE_ROOT_DIR}/UnicodeConverter UnicodeConverter)
endif()

if(NOT TARGET graphics)
    add_subdirectory(${CORE_ROOT_DIR}/DesktopEditor/graphics/cmake graphics)
endif()

if(NOT TARGET ascdocumentscore)
    add_subdirectory(${DESKTOP_SDK_ROOT}/ChromiumBasedEditors/lib/ ascdocumentscore)
endif()

if(NOT TARGET doctrenderer)
    add_subdirectory(${CORE_ROOT_DIR}/DesktopEditor/doctrenderer doctrenderer)
endif()

if(NOT TARGET DocxRenderer)
    add_subdirectory(${CORE_ROOT_DIR}/DocxRenderer DocxRenderer)
endif()

if(NOT TARGET Fb2File)
    add_subdirectory(${CORE_ROOT_DIR}/Fb2File Fb2File)
endif()

if(NOT TARGET EpubFile)
    add_subdirectory(${CORE_ROOT_DIR}/EpubFile EpubFile)
endif()

if(NOT TARGET HtmlFile2)
    add_subdirectory(${CORE_ROOT_DIR}/HtmlFile2 HtmlFile2)
endif()

if(NOT TARGET OFDFile)
    add_subdirectory(${CORE_ROOT_DIR}/OFDFile OFDFile)
endif()

if(NOT TARGET IWorkFile)
    add_subdirectory(${CORE_ROOT_DIR}/Apple IWorkFile)
endif()

if(NOT TARGET HWPFile)
    add_subdirectory(${CORE_ROOT_DIR}/HwpFile HWPFile)
endif()

# ---------------------------------------------------------------------------
# Command-line tools that ship inside the bundle
# ---------------------------------------------------------------------------
if(NOT TARGET x2t)
    add_subdirectory("${CORE_ROOT_DIR}/X2tConverter/build/cmake" x2t)
endif()

if(NOT TARGET allfontsgen)
    add_subdirectory("${CORE_ROOT_DIR}/DesktopEditor/AllFontsGen" allfontsgen)
endif()

if(NOT TARGET allthemesgen)
    add_subdirectory("${CORE_ROOT_DIR}/DesktopEditor/allthemesgen" allthemesgen)
endif()

if(NOT TARGET pluginsmanager)
    add_subdirectory("${CORE_ROOT_DIR}/DesktopEditor/pluginsmanager" pluginsmanager)
endif()

if(NOT TARGET cmapbin)
    add_subdirectory("${CORE_ROOT_DIR}/PdfFile/Resources/CMapMemory" cmapbin)
endif()
