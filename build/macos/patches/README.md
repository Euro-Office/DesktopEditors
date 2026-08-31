# macOS compatibility patches

Clang on macOS is stricter than the GCC and MSVC toolchains the other two
platforms use. 

Each fix is one reviewable `.patch` file, applied by `build.sh` with
`git apply --unidiff-zero` and reverted when the script exits.