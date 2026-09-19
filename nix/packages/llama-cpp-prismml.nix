# PrismML's fork of llama.cpp, CPU build.
#
# Stock llama.cpp rejects the PTQ1_0 and PQ2_0 tensor types the Bonsai GGUFs
# use, and loads the older Q2_0 files without the Hadamard activation
# rotation, which produces garbage. The fork carries the types, the ARM and
# x86 kernels, and the rotation runtime. Nothing here is a patch on nixpkgs'
# llama-cpp package: that one builds a web UI with npm, needs an npm deps
# hash per source revision, and none of that is wanted on an inference box.
#
# ============================================================================
# WHICH PACK TO SERVE ON ARM
# ============================================================================
#
# In the fork's source at f0a2b5d (2026-09-17): ggml/src/ggml-cpu/arch/arm/
# quants.c has a NEON vec_dot for PQ2_0. PTQ1_0 maps to the generic C kernel
# through arch-fallback.h. So on a Pi 5 the PQ2_0 file (7.2 GB) is the one to
# measure first; the dense PTQ1_0 file (5.9 GB) saves memory and costs speed
# until the fork grows an ARM kernel for it.
#
# ============================================================================
# THE CPU ARCHITECTURE IS FIXED AT BUILD TIME, ON PURPOSE
# ============================================================================
#
# GGML_NATIVE=ON would detect the build host's CPU, which under Nix is
# whatever machine built the derivation. cpuArch names the target instead.
# A Cortex-A76 (Pi 5) is armv8.2-a with dotprod and fp16 and without i8mm.
{
  lib,
  stdenv,
  cmake,
  ninja,
  pkg-config,
  src,
  rev,
  lastModifiedDate,
  # Passed to -DGGML_CPU_ARM_ARCH on aarch64. Ignored elsewhere.
  cpuArch ? "armv8.2-a+dotprod+fp16",
}:
stdenv.mkDerivation {
  pname = "llama-cpp-prismml";
  version = "0-unstable-${builtins.substring 0 4 lastModifiedDate}-${builtins.substring 4 2 lastModifiedDate}-${builtins.substring 6 2 lastModifiedDate}-${rev}";

  inherit src;

  nativeBuildInputs = [
    cmake
    ninja
    pkg-config
  ];

  cmakeFlags =
    [
      (lib.cmakeBool "BUILD_SHARED_LIBS" false)
      (lib.cmakeBool "GGML_NATIVE" false)
      (lib.cmakeBool "GGML_BACKEND_DL" false)
      (lib.cmakeBool "LLAMA_BUILD_SERVER" true)
      (lib.cmakeBool "LLAMA_BUILD_TOOLS" true)
      (lib.cmakeBool "LLAMA_BUILD_EXAMPLES" false)
      (lib.cmakeBool "LLAMA_BUILD_TESTS" false)
      # No model downloads from inside the server, and no TLS: the gateway
      # terminates TLS and the weights come from the store.
      (lib.cmakeBool "LLAMA_CURL" false)
      (lib.cmakeBool "LLAMA_OPENSSL" false)
      (lib.cmakeFeature "GGML_BUILD_NUMBER" "0")
      (lib.cmakeFeature "GGML_BUILD_COMMIT" rev)
    ]
    ++ lib.optionals stdenv.hostPlatform.isAarch64 [
      (lib.cmakeFeature "GGML_CPU_ARM_ARCH" cpuArch)
    ];

  # The install step leaves llama-* binaries and static libs. Only the
  # binaries this repo uses are kept on PATH.
  postInstall = ''
    for f in "$out"/bin/*; do
      case "$(basename "$f")" in
        llama-server | llama-cli | llama-bench | llama-quantize) ;;
        *) rm -f "$f" ;;
      esac
    done
    rm -rf "$out"/lib/cmake "$out"/lib/pkgconfig "$out"/include
  '';

  meta = {
    description = "llama.cpp with PrismML's ternary (PTQ1_0, PQ2_0) kernels and Hadamard rotation runtime";
    homepage = "https://github.com/PrismML-Eng/llama.cpp";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
    mainProgram = "llama-server";
  };
}
