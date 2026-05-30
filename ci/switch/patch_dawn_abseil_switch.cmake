if (NOT EXISTS "${PATCH_FILE}")
  message(FATAL_ERROR "patch_dawn_abseil_switch.cmake requires PATCH_FILE to point at Dawn's tools/fetch_dawn_dependencies.py")
endif ()

file(READ "${PATCH_FILE}" _dawn_fetch_deps)
set(_patched "${_dawn_fetch_deps}")

set(_imports_block [==[
# DUSK_SWITCH_PATCH_V3
import os
import sys
import subprocess
import argparse
import re
from pathlib import Path
]==])

set(_log_helper [==[
def log(msg):
    """Just makes it look good in the CMake log flow."""
    print(f"-- -- {msg}")
]==])

set(_absl_hook [==[
        if submodule == 'third_party/abseil-cpp':
            absl_sysinfo = submodule_path / 'absl/base/internal/sysinfo.cc'
            if absl_sysinfo.is_file():
                patch_abseil_switch_v3(absl_sysinfo)

            absl_elf_mem_image = submodule_path / 'absl/debugging/internal/elf_mem_image.h'
            if absl_elf_mem_image.is_file():
                patch_abseil_elf_mem_image_switch(absl_elf_mem_image)
]==])

set(_absl_helper [==[
def patch_abseil_switch_v3(absl_sysinfo):
    """Patch Abseil's thread-id fallback for libnx. (v3)"""
    text = absl_sysinfo.read_text()
    patched = text

    # Use uintptr_t as it's the most portable way to cast a pointer to an integer
    # for use as a unique ID.
    if "reinterpret_cast<uintptr_t>(pthread_self())" not in patched:
        # Match both the original and v1/v2 which used intptr_t
        patched = re.sub(
            r"static_cast<pid_t>\s*\(\s*(?:reinterpret_cast<intptr_t>\s*\()?\s*pthread_self\s*\(\s*\)\s*\)?\s*\)",
            "static_cast<pid_t>(reinterpret_cast<uintptr_t>(pthread_self()))",
            patched,
        )
        if patched == text:
            # Fallback for even older versions or different formatting
            patched = text.replace("static_cast<pid_t>(pthread_self())", 
                                 "static_cast<pid_t>(reinterpret_cast<uintptr_t>(pthread_self()))")
        
        if patched != text:
            log(f"applied Switch abseil thread-id patch (uintptr_t): {absl_sysinfo}")

    # Ensure <cstdint> is included for uintptr_t
    if "#include <cstdint>" not in patched:
        patched = patched.replace('#include "absl/base/internal/sysinfo.h"', 
                                 '#include "absl/base/internal/sysinfo.h"\n#include <cstdint>')
        log(f"added <cstdint> to: {absl_sysinfo}")

    if patched != text:
        absl_sysinfo.write_text(patched)
    else:
        log(f"Switch abseil patch v3 already fully applied: {absl_sysinfo}")

def patch_abseil_elf_mem_image_switch(absl_elf_mem_image):
    """Disable Abseil elf_mem_image on libnx where <link.h> is unavailable."""
    text = absl_elf_mem_image.read_text()
    switch_guard = "!defined(__SWITCH__)"
    if switch_guard in text:
        log(f"Switch elf_mem_image patch already applied: {absl_elf_mem_image}")
        return

    needle = "#if defined(__ELF__) && !defined(__OpenBSD__) && !defined(__QNX__) &&"
    replacement = "#if defined(__ELF__) && !defined(__SWITCH__) && !defined(__OpenBSD__) && !defined(__QNX__) &&"
    if needle not in text:
        # Check for slightly different versions
        needle = "#if defined(__ELF__) && !defined(__OpenBSD__) &&"
        replacement = "#if defined(__ELF__) && !defined(__SWITCH__) && !defined(__OpenBSD__) &&"
        
    if needle not in text:
        log(f"WARNING: could not find elf_mem_image feature guard in {absl_elf_mem_image}")
        return

    absl_elf_mem_image.write_text(text.replace(needle, replacement, 1))
    log(f"applied Switch elf_mem_image patch: {absl_elf_mem_image}")
]==])

# Ensure Dawn's fetch helper has the imports our injected helper uses.
string(FIND "${_patched}" "DUSK_SWITCH_PATCH_V3" _has_v3_imports)
if (_has_v3_imports EQUAL -1)
  # Look for ANY previous import block and replace it.
  string(FIND "${_patched}" "import os\nimport sys\nimport subprocess\nimport argparse" _old_imports)
  if (_old_imports GREATER -1)
     # This is a bit greedy but should work for this specific script.
     string(REGEX REPLACE "import os\nimport sys\nimport subprocess\nimport argparse(\nimport re)?(\nfrom pathlib import Path)?" "${_imports_block}" _patched "${_patched}")
  else ()
    message(FATAL_ERROR "aurora: could not find Dawn fetch script import block in ${PATCH_FILE}")
  endif ()
endif ()

# Keep the script idempotent: if a prior run already inserted the helpers/hooks,
# only add the missing pieces.
string(FIND "${_patched}" "def log(msg):" _has_log_helper)
if (_has_log_helper EQUAL -1)
  string(FIND "${_patched}" "def main(args):" _main_anchor)
  if (_main_anchor GREATER -1)
    string(REPLACE "def main(args):" "${_log_helper}\n\ndef main(args):" _patched "${_patched}")
  else ()
    message(FATAL_ERROR "aurora: could not find Dawn fetch script main() anchor in ${PATCH_FILE}")
  endif ()
endif ()

string(FIND "${_patched}" "def patch_abseil_switch_v3" _has_absl_helper)
if (_has_absl_helper EQUAL -1)
  # Check if old version is there and replace it
  string(FIND "${_patched}" "def patch_abseil_switch" _has_old_absl_helper)
  if (_has_old_absl_helper GREATER -1)
     # Replace the whole block from old helper to "class Var:"
     string(REGEX REPLACE "def patch_abseil_switch.*class Var:" "${_absl_helper}\n\nclass Var:" _patched "${_patched}")
  else ()
    string(FIND "${_patched}" "class Var:" _class_anchor)
    if (_class_anchor GREATER -1)
      string(REPLACE "class Var:" "${_absl_helper}\n\nclass Var:" _patched "${_patched}")
    else ()
      message(FATAL_ERROR "aurora: could not find Dawn fetch script class anchor in ${PATCH_FILE}")
    endif ()
  endif ()
endif ()

string(FIND "${_patched}" "patch_abseil_switch_v3" _has_absl_hook)
if (_has_absl_hook EQUAL -1)
  # Check if old hook is there and replace it
  string(FIND "${_patched}" "patch_abseil_switch" _has_old_absl_hook)
  if (_has_old_absl_hook GREATER -1)
    string(REGEX REPLACE "if submodule == 'third_party/abseil-cpp':.*absl_elf_mem_image_switch\\(absl_elf_mem_image\\)" "${_absl_hook}" _patched "${_patched}")
  else ()
    string(FIND "${_patched}" "process_dir(args, submodule_path, required_subsubmodules)" _call_anchor)
    if (_call_anchor GREATER -1)
      string(REPLACE "        process_dir(args, submodule_path, required_subsubmodules)" "        process_dir(args, submodule_path, required_subsubmodules)\n${_absl_hook}" _patched "${_patched}")
    else ()
      message(FATAL_ERROR "aurora: could not find Dawn recursive dependency call in ${PATCH_FILE}")
    endif ()
  endif ()
endif ()

file(WRITE "${PATCH_FILE}" "${_patched}")

# Also patch Dawn compiler flags so Switch/libnx builds keep exceptions enabled.
get_filename_component(_dawn_tools_dir "${PATCH_FILE}" DIRECTORY)
get_filename_component(_dawn_source_dir "${_dawn_tools_dir}" DIRECTORY)
set(_dawn_extra_flags "${_dawn_source_dir}/src/cmake/DawnCompilerExtraFlags.cmake")
if (EXISTS "${_dawn_extra_flags}")
  file(READ "${_dawn_extra_flags}" _dawn_extra_flags_text)
  set(_dawn_extra_flags_patched "${_dawn_extra_flags_text}")

  string(FIND "${_dawn_extra_flags_patched}" "-fno-exceptions" _has_fno_exceptions)
  if (NOT _has_fno_exceptions EQUAL -1)
    string(REPLACE
      "\"-fno-exceptions\""
      "\"$<$<NOT:$<AND:$<STREQUAL:${CMAKE_SYSTEM_NAME},Generic>,$<STREQUAL:${CMAKE_SYSTEM_VERSION},DKA-NX>>>:-fno-exceptions>\""
      _dawn_extra_flags_patched
      "${_dawn_extra_flags_patched}")
    file(WRITE "${_dawn_extra_flags}" "${_dawn_extra_flags_patched}")
    message(STATUS "aurora: patched Dawn compiler flags to keep exceptions enabled on Switch")
  endif ()
endif ()

message(STATUS "aurora: patched Dawn dependency fetch script for Switch")

# Patch Dawn native TintUtils to explicitly include tint Bindings type for
# toolchains where indirect include ordering differs.
set(_dawn_tint_utils "${_dawn_source_dir}/src/dawn/native/TintUtils.h")
if (EXISTS "${_dawn_tint_utils}")
  file(READ "${_dawn_tint_utils}" _dawn_tint_utils_text)
  set(_dawn_tint_utils_patched "${_dawn_tint_utils_text}")

  string(FIND "${_dawn_tint_utils_patched}" "src/tint/api/common/bindings.h" _has_tint_bindings_include)
  if (_has_tint_bindings_include EQUAL -1)
    string(REPLACE
      "#include \"src/tint/api/common/binding_point.h\""
      "#include \"src/tint/api/common/binding_point.h\"\n#include \"src/tint/api/common/bindings.h\""
      _dawn_tint_utils_patched
      "${_dawn_tint_utils_patched}")
  endif ()

  # Keep this robust across namespace lookup edge cases.
  string(REPLACE "tint::Bindings GenerateBindingRemapping(" "::tint::Bindings GenerateBindingRemapping(" _dawn_tint_utils_patched "${_dawn_tint_utils_patched}")
  string(REPLACE "tint::Bindings bindings;" "::tint::Bindings bindings;" _dawn_tint_utils_patched "${_dawn_tint_utils_patched}")

  if (NOT _dawn_tint_utils_patched STREQUAL _dawn_tint_utils_text)
    file(WRITE "${_dawn_tint_utils}" "${_dawn_tint_utils_patched}")
    message(STATUS "aurora: patched Dawn TintUtils.h for Switch")
  endif ()
endif ()

# Patch Dawn compiler extra warning flags for GNU+Switch to drop clang-only
# suppressions that generate noisy cc1plus notes.
if (EXISTS "${_dawn_extra_flags}")
  file(READ "${_dawn_extra_flags}" _dawn_extra_flags_text2)
  set(_dawn_extra_flags_patched2 "${_dawn_extra_flags_text2}")

  set(_switch_gnu_cond "$<AND:$<CXX_COMPILER_ID:GNU>,$<AND:$<STREQUAL:${CMAKE_SYSTEM_NAME},Generic>,$<STREQUAL:${CMAKE_SYSTEM_VERSION},DKA-NX>>>")

  foreach(_clang_only_flag
      "-Wno-nullability-extension"
      "-Wno-unreachable-code-break"
      "-Wno-gcc-compat"
      "-Wno-nrvo"
      "-Wno-unknown-warning-option"
      "-Wno-deprecated-builtins"
      "-Wno-assume")
    string(REPLACE
      "\"${_clang_only_flag}\""
      "\"$<$<NOT:${_switch_gnu_cond}>:${_clang_only_flag}>\""
      _dawn_extra_flags_patched2
      "${_dawn_extra_flags_patched2}")
  endforeach ()

  if (NOT _dawn_extra_flags_patched2 STREQUAL _dawn_extra_flags_text2)
    file(WRITE "${_dawn_extra_flags}" "${_dawn_extra_flags_patched2}")
    message(STATUS "aurora: patched Dawn compiler flags to drop clang-only -Wno-* on GNU Switch")
  endif ()
endif ()

# Patch Dawn WGPUHelpers NormalizeMessageString for libnx/newlib where strnlen
# may be unavailable in this toolchain configuration.
set(_dawn_wgpu_helpers "${_dawn_source_dir}/src/dawn/native/utils/WGPUHelpers.cpp")
if (EXISTS "${_dawn_wgpu_helpers}")
  file(READ "${_dawn_wgpu_helpers}" _dawn_wgpu_helpers_text)
  set(_dawn_wgpu_helpers_patched "${_dawn_wgpu_helpers_text}")

  string(FIND "${_dawn_wgpu_helpers_patched}" "#if defined(__SWITCH__)" _has_switch_strnlen_guard)
  if (_has_switch_strnlen_guard EQUAL -1)
    string(REPLACE
      "    return std::string_view(in.data, strnlen(in.data, in.length));"
      "#if defined(__SWITCH__)\n    size_t n = 0;\n    while (n < in.length && in.data[n] != '\\0') {\n        ++n;\n    }\n    return std::string_view(in.data, n);\n#else\n    return std::string_view(in.data, strnlen(in.data, in.length));\n#endif"
      _dawn_wgpu_helpers_patched
      "${_dawn_wgpu_helpers_patched}")
  endif ()

  if (NOT _dawn_wgpu_helpers_patched STREQUAL _dawn_wgpu_helpers_text)
    file(WRITE "${_dawn_wgpu_helpers}" "${_dawn_wgpu_helpers_patched}")
    message(STATUS "aurora: patched Dawn WGPUHelpers.cpp for Switch strnlen compatibility")
  endif ()
endif ()

# Switch-only fallback: if GCC still fails to resolve tint::Bindings in
# TintUtils.h, replace the helper with a no-op stub. This helper is consumed by
# non-Null backends only, and those backends are disabled for Switch here.
set(_dawn_tint_utils "${_dawn_source_dir}/src/dawn/native/TintUtils.h")
if (EXISTS "${_dawn_tint_utils}")
  file(READ "${_dawn_tint_utils}" _dawn_tint_utils_text2)
  set(_dawn_tint_utils_patched2 "${_dawn_tint_utils_text2}")

  string(FIND "${_dawn_tint_utils_patched2}" "DUSK_SWITCH_BINDINGS_STUB" _has_switch_bindings_stub)
  if (_has_switch_bindings_stub EQUAL -1)
    set(_orig_bindings_fn [=[template <ConvertsBindingIndexToBindingPoint F>
::tint::Bindings GenerateBindingRemapping(const PipelineLayoutBase* layout,
                                        SingleShaderStage stage,
                                        F&& BindingPointFor) {]=])

    set(_stubbed_bindings_fn [=[#if defined(__SWITCH__)
template <ConvertsBindingIndexToBindingPoint F>
inline void GenerateBindingRemapping(const PipelineLayoutBase*, SingleShaderStage, F&&) { /* DUSK_SWITCH_BINDINGS_STUB */ }
#else
template <ConvertsBindingIndexToBindingPoint F>
::tint::Bindings GenerateBindingRemapping(const PipelineLayoutBase* layout,
                                        SingleShaderStage stage,
                                        F&& BindingPointFor) {]=])

    string(REPLACE "${_orig_bindings_fn}" "${_stubbed_bindings_fn}" _dawn_tint_utils_patched2 "${_dawn_tint_utils_patched2}")
    string(REPLACE "    return bindings;\n}" "    return bindings;\n}\n#endif" _dawn_tint_utils_patched2 "${_dawn_tint_utils_patched2}")
  endif ()

  if (NOT _dawn_tint_utils_patched2 STREQUAL _dawn_tint_utils_text2)
    file(WRITE "${_dawn_tint_utils}" "${_dawn_tint_utils_patched2}")
    message(STATUS "aurora: patched Dawn TintUtils.h with Switch Bindings stub")
  endif ()
endif ()
