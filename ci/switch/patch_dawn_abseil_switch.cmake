# DUSK_SWITCH_PATCH_V8
if (NOT EXISTS "${PATCH_FILE}")
  message(FATAL_ERROR "patch_dawn_abseil_switch.cmake requires PATCH_FILE to point at Dawn's tools/fetch_dawn_dependencies.py")
endif ()

# ─── Part 1: Hook the fetch script for future downloads ───

file(READ "${PATCH_FILE}" _dawn_fetch_deps)
set(_patched "${_dawn_fetch_deps}")

set(_absl_hook [==[
        # DUSK_SWITCH_HOOK_V8
        if submodule == 'third_party/abseil-cpp':
            absl_sysinfo = submodule_path / 'absl/base/internal/sysinfo.cc'
            if absl_sysinfo.is_file():
                patch_abseil_switch_v8(absl_sysinfo)

            absl_elf_mem_image = submodule_path / 'absl/debugging/internal/elf_mem_image.h'
            if absl_elf_mem_image.is_file():
                patch_abseil_elf_mem_image_switch_v8(absl_elf_mem_image)
]==])

set(_absl_helper [==[
# BEGIN DUSK_SWITCH_HELPERS_V8
def patch_abseil_switch_v8(absl_sysinfo):
    """Patch Abseil's thread-id fallback for libnx. (v8)"""
    text = absl_sysinfo.read_text()
    patched = text

    if "reinterpret_cast<uintptr_t>(pthread_self())" not in patched:
        # Match original or any previous versions
        import re
        patched = re.sub(
            r"static_cast<pid_t>\s*\(\s*(?:reinterpret_cast<[ui]ntptr_t>\s*\()?\s*pthread_self\s*\(\s*\)\s*\)?\s*\)",
            "static_cast<pid_t>(reinterpret_cast<uintptr_t>(pthread_self()))",
            patched,
        )
        if patched == text:
            patched = text.replace("static_cast<pid_t>(pthread_self())", 
                                 "static_cast<pid_t>(reinterpret_cast<uintptr_t>(pthread_self()))")
        
        if patched != text:
            log(f"applied Switch abseil thread-id patch (uintptr_t): {absl_sysinfo}")

    if "#include <cstdint>" not in patched:
        patched = patched.replace('#include "absl/base/internal/sysinfo.h"', 
                                 '#include "absl/base/internal/sysinfo.h"\n#include <cstdint>')
        log(f"added <cstdint> to: {absl_sysinfo}")

    if patched != text:
        absl_sysinfo.write_text(patched)

def patch_abseil_elf_mem_image_switch_v8(absl_elf_mem_image):
    """Disable Abseil elf_mem_image on libnx where <link.h> is unavailable. (v8)"""
    text = absl_elf_mem_image.read_text()
    if "!defined(__SWITCH__)" in text:
        return

    needle = "#if defined(__ELF__) && !defined(__OpenBSD__) && !defined(__QNX__) &&"
    replacement = "#if defined(__ELF__) && !defined(__SWITCH__) && !defined(__OpenBSD__) && !defined(__QNX__) &&"
    if needle not in text:
        needle = "#if defined(__ELF__) && !defined(__OpenBSD__) &&"
        replacement = "#if defined(__ELF__) && !defined(__SWITCH__) && !defined(__OpenBSD__) &&"
        
    if needle in text:
        absl_elf_mem_image.write_text(text.replace(needle, replacement, 1))
        log(f"applied Switch elf_mem_image patch: {absl_elf_mem_image}")

def log(msg):
    print(f"-- -- {msg}")
# END DUSK_SWITCH_HELPERS_V8
]==])

# Idempotent marker check
string(FIND "${_patched}" "DUSK_SWITCH_PATCH_V8" _has_v8)
if (_has_v8 EQUAL -1)
  # 1. Inject Marker
  set(_patched "# DUSK_SWITCH_PATCH_V8\n${_patched}")
  
  # 2. Inject Imports (very simple string replacement)
  string(FIND "${_patched}" "import re" _has_re)
  if (_has_re EQUAL -1)
    string(REPLACE "import os" "import os\nimport re" _patched "${_patched}")
  endif ()
  string(FIND "${_patched}" "from pathlib import Path" _has_path)
  if (_has_path EQUAL -1)
    string(REPLACE "import os" "import os\nfrom pathlib import Path" _patched "${_patched}")
  endif ()

  # 3. Clean up old helpers (v1-v7) if present
  # We use a simple marker search to avoid REGEX REPLACE for the whole block
  string(FIND "${_patched}" "def patch_abseil_switch" _old_pos)
  if (NOT _old_pos EQUAL -1)
    # This is safer: just inject our new one at the start of the file or before class Var
    # and let Python handle the duplicate definitions (new one wins if it's later, or we replace)
  endif ()

  # 4. Inject Helpers before class Var:
  string(REPLACE "class Var:" "${_absl_helper}\n\nclass Var:" _patched "${_patched}")

  # 5. Inject Hook after process_dir
  string(FIND "${_patched}" "DUSK_SWITCH_HOOK_V8" _has_hook_v8)
  if (_has_hook_v8 EQUAL -1)
    string(REPLACE "        process_dir(args, submodule_path, required_subsubmodules)" "        process_dir(args, submodule_path, required_subsubmodules)\n${_absl_hook}" _patched "${_patched}")
  endif ()

  file(WRITE "${PATCH_FILE}" "${_patched}")
endif ()

# ─── Part 2: Direct patching if files present (Native CMake) ───

get_filename_component(_dawn_tools_dir "${PATCH_FILE}" DIRECTORY)
get_filename_component(_dawn_source_dir "${_dawn_tools_dir}" DIRECTORY)

set(_absl_sysinfo "${_dawn_source_dir}/third_party/abseil-cpp/absl/base/internal/sysinfo.cc")
if (EXISTS "${_absl_sysinfo}")
  file(READ "${_absl_sysinfo}" _txt)
  if (NOT _txt MATCHES "reinterpret_cast<uintptr_t>")
    string(REPLACE "static_cast<pid_t>(pthread_self())" "static_cast<pid_t>(reinterpret_cast<uintptr_t>(pthread_self()))" _txt "${_txt}")
    string(REPLACE "static_cast<pid_t>(reinterpret_cast<intptr_t>(pthread_self()))" "static_cast<pid_t>(reinterpret_cast<uintptr_t>(pthread_self()))" _txt "${_txt}")
    if (NOT _txt MATCHES "#include <cstdint>")
      string(REPLACE "#include \"absl/base/internal/sysinfo.h\"" "#include \"absl/base/internal/sysinfo.h\"\n#include <cstdint>" _txt "${_txt}")
    endif ()
    file(WRITE "${_absl_sysinfo}" "${_txt}")
    message(STATUS "aurora: Applied Switch thread-id patch to sysinfo.cc")
  endif ()
endif ()

set(_absl_elf_mem "${_dawn_source_dir}/third_party/abseil-cpp/absl/debugging/internal/elf_mem_image.h")
if (EXISTS "${_absl_elf_mem}")
  file(READ "${_absl_elf_mem}" _txt)
  if (NOT _txt MATCHES "__SWITCH__")
    set(_replacement "#if defined(__ELF__) && !defined(__SWITCH__) && !defined(__OpenBSD__) && !defined(__QNX__) &&")
    string(REPLACE "#if defined(__ELF__) && !defined(__OpenBSD__) && !defined(__QNX__) &&" "${_replacement}" _txt "${_txt}")
    file(WRITE "${_absl_elf_mem}" "${_txt}")
    message(STATUS "aurora: Applied Switch ELF guard patch to elf_mem_image.h")
  endif ()
endif ()

# ─── Part 3: Dawn specific flags ───

set(_dawn_extra_flags "${_dawn_source_dir}/src/cmake/DawnCompilerExtraFlags.cmake")
if (EXISTS "${_dawn_extra_flags}")
  file(READ "${_dawn_extra_flags}" _txt)
  if (NOT _txt MATCHES "DKA-NX")
    string(REPLACE "\"-fno-exceptions\"" "\"$<$<NOT:$<AND:$<STREQUAL:${CMAKE_SYSTEM_NAME},Generic>,$<STREQUAL:${CMAKE_SYSTEM_VERSION},DKA-NX>>>:-fno-exceptions>\"" _txt "${_txt}")
    file(WRITE "${_dawn_extra_flags}" "${_txt}")
    message(STATUS "aurora: Patched Dawn exceptions for Switch")
  endif ()
endif ()

set(_dawn_tint_utils "${_dawn_source_dir}/src/dawn/native/TintUtils.h")
if (EXISTS "${_dawn_tint_utils}")
  file(READ "${_dawn_tint_utils}" _txt)
  if (NOT _txt MATCHES "bindings.h")
    string(REPLACE "#include \"src/tint/api/common/binding_point.h\"" "#include \"src/tint/api/common/binding_point.h\"\n#include \"src/tint/api/common/bindings.h\"" _txt "${_txt}")
    string(REPLACE "tint::Bindings GenerateBindingRemapping(" "::tint::Bindings GenerateBindingRemapping(" _txt "${_txt}")
    string(REPLACE "tint::Bindings bindings;" "::tint::Bindings bindings;" _txt "${_txt}")
    file(WRITE "${_dawn_tint_utils}" "${_txt}")
    message(STATUS "aurora: Patched Dawn TintUtils.h for Switch")
  endif ()
endif ()

set(_dawn_wgpu_helpers "${_dawn_source_dir}/src/dawn/native/utils/WGPUHelpers.cpp")
if (EXISTS "${_dawn_wgpu_helpers}")
  file(READ "${_dawn_wgpu_helpers}" _txt)
  if (NOT _txt MATCHES "__SWITCH__")
    set(_rep "#if defined(__SWITCH__)\n    size_t n = 0;\n    while (n < in.length && in.data[n] != '\\0') {\n        ++n;\n    }\n    return std::string_view(in.data, n);\n#else\n    return std::string_view(in.data, strnlen(in.data, in.length));\n#endif")
    string(REPLACE "    return std::string_view(in.data, strnlen(in.data, in.length));" "${_rep}" _txt "${_txt}")
    file(WRITE "${_dawn_wgpu_helpers}" "${_txt}")
    message(STATUS "aurora: Patched Dawn WGPUHelpers.cpp for Switch")
  endif ()
endif ()
