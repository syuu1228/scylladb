#!/bin/bash -uex

if [ -z "${CLANG_ARCH}" ]; then
    echo "CLANG_ARCH is not defined"
elif [ "${CLANG_ARCH}" != "amd64" ]; then
    LLVM_TARGET_ARCH=AArch64
    LLVM_TARGET="-DLLVM_EXPERIMENTAL_TARGETS_TO_BUILD=AArch64;WebAssembly"
else
    LLVM_TARGET_ARCH=X86
    LLVM_TARGET="-DLLVM_EXPERIMENTAL_TARGETS_TO_BUILD=WebAssembly"
fi

if [ -z "${CLANG_BUILD}" ]; then
    echo "Skip building optimized clang"
    exit 0
elif [ "${CLANG_BUILD}" = "SKIP" ]; then
    echo "Skip building optimized clang"
    exit 0
elif [ "${CLANG_BUILD}" = "BUILD" ]; then
    echo "build optimized clang"
elif [ "${CLANG_BUILD}" = "INSTALL" ]; then
    echo "build and install optimized clang"
elif [ "${CLANG_BUILD}" = "INSTALL_PREBUILT" ]; then
    echo "install prebuilt optimized clang"
else
    echo "Not sure what to do with ${CLANG_BUILD}"
    exit 1
fi

if [ ! -d "/optimized_clang" ]; then
    echo "/optimized_clang not mounted"
    exit 1
fi
DIR="/optimized_clang"

STAGE0_BIN=$DIR/stage-0-${CLANG_ARCH}/build/bin
STAGE1_BIN=$DIR/stage-1-${CLANG_ARCH}/build/bin

# Which LLVM release to build in order to compile Scylla
LLVM_SCYLLA_TAG=17.0.6

# Which LLVM release to use to build clang (stage 0).
LLVM_CLANG_TAG=17.0.6

if [ "${CLANG_BUILD}" = "INSTALL" -o "${CLANG_BUILD}" = "BUILD" ]; then
    cd "${DIR}"
    # Clone, patch and bootstrap the newest Clang.
    rm -rf stage-0-${CLANG_ARCH}
    git clone https://github.com/llvm/llvm-project --branch llvmorg-${LLVM_CLANG_TAG} --depth=1 stage-0-${CLANG_ARCH}
    cd stage-0-${CLANG_ARCH}
    USE_CURRENT_COMPILER=(-DCMAKE_C_COMPILER="/usr/bin/clang" -DCMAKE_CXX_COMPILER="/usr/bin/clang++" -DLLVM_USE_LINKER="/usr/bin/ld")
    COMMON_OPTS=(-DCMAKE_BUILD_TYPE=Release -DLLVM_TARGETS_TO_BUILD=all -DLLVM_TARGET_ARCH=${LLVM_TARGET_ARCH} -G Ninja -DLLVM_INCLUDE_BENCHMARKS=OFF -DLLVM_INCLUDE_EXAMPLES=OFF -DLLVM_INCLUDE_TESTS=OFF -DLLVM_ENABLE_BINDINGS=OFF)
    SCYLLA_OPTS=(--date-stamp $(date "+%Y%m%d") --debuginfo 1 --tests-debuginfo 1 --c-compiler="$STAGE1_BIN/clang" --compiler="$STAGE1_BIN/clang++")

    echo "stage-0: build the bootstrapped compiler"

    cmake -B build -S llvm  "${USE_CURRENT_COMPILER[@]}" "${COMMON_OPTS[@]}" "${LLVM_TARGET}" -DLLVM_ENABLE_PROJECTS="clang;lld;bolt" -DLLVM_ENABLE_RUNTIMES="compiler-rt" -DCOMPILER_RT_BUILD_SANITIZERS=OFF -DCOMPILER_RT_DEFAULT_TARGET_ONLY=ON
    ninja -C build

    USE_NEW_COMPILER=(-DCMAKE_C_COMPILER="$STAGE0_BIN/clang" -DCMAKE_CXX_COMPILER="$STAGE0_BIN/clang++" -DLLVM_USE_LINKER="$STAGE0_BIN/ld.lld")
    NEW_COMMON_OPTS=(-DLLVM_ENABLE_PROJECTS="clang;lld" -DLLVM_ENABLE_RUNTIMES="compiler-rt" -DLLVM_ENABLE_LTO=Thin -DCLANG_DEFAULT_PIE_ON_LINUX=OFF -DLLVM_BUILD_TOOLS=OFF -DCMAKE_C_FLAGS="-Xclang -mllvm -Xclang -vp-counters-per-site=16" -DCMAKE_CXX_FLAGS="-Xclang -mllvm -Xclang -vp-counters-per-site=16")

    echo "stage-1: Build a PGO-optimized compiler using the boostrapped compiler"

    # Build a PGO-optimized compiler using the boostrapped compiler.
    rm -rf ../stage-1-${CLANG_ARCH}
    git fetch --depth=1 origin tag llvmorg-${LLVM_SCYLLA_TAG}
    git worktree add ../stage-1-${CLANG_ARCH} llvmorg-${LLVM_SCYLLA_TAG}
    cd ../stage-1-${CLANG_ARCH}
    cmake -B build -S llvm "${USE_NEW_COMPILER[@]}" "${COMMON_OPTS[@]}" "${NEW_COMMON_OPTS[@]}" ${LLVM_TARGET} -DLLVM_BUILD_INSTRUMENTED=IR
    ninja -C build

    echo "cmake stage-1 output:"

    cd ../
    # Download the scylla codebase for training.
    # Scylla's dependencies are already installed.
    rm -rf scylla-${CLANG_ARCH}
    mkdir scylla-${CLANG_ARCH}
    cd scylla-${CLANG_ARCH}
    tar -xpf $DIR/scylla-archive.tar

    # 1st ScyllaDB compilation: gather a clang profile for PGO
    cd ../scylla-${CLANG_ARCH}
    rm -rf build build.ninja
    ./configure.py "${SCYLLA_OPTS[@]}"
    LLVM_PROFILE_FILE=$DIR/stage-1-${CLANG_ARCH}/build/profiles/default_%p-%m.profraw ninja build

    cd ../stage-1-${CLANG_ARCH}
    $STAGE0_BIN/llvm-profdata merge $DIR/stage-1-${CLANG_ARCH}/build/profiles/default_*.profraw -output=ir.prof
    rm -r build
    cmake -B build -S llvm "${USE_NEW_COMPILER[@]}" "${COMMON_OPTS[@]}" "${NEW_COMMON_OPTS[@]}" "${LLVM_TARGET}" -DLLVM_BUILD_INSTRUMENTED=CSIR -DLLVM_PROFDATA_FILE=$(realpath ir.prof)
    ninja -C build

    # 2nd compilation: gathering a clang profile for CSPGO
    cd ../scylla-${CLANG_ARCH}
    rm -rf build build.ninja
    ./configure.py "${SCYLLA_OPTS[@]}"
    LLVM_PROFILE_FILE=$DIR/stage-1-${CLANG_ARCH}/build/profiles/csir-%p-%m.profraw ninja build

    cd ../stage-1-${CLANG_ARCH}
    $STAGE0_BIN/llvm-profdata merge build/csprofiles/default_*.profraw -output=csir.prof
    $STAGE0_BIN/llvm-profdata merge ir.prof csir.prof -output=combined.prof
    rm -r build
    # -DLLVM_LIBDIR_SUFFIX=64 for Fedora compatibility
    cmake -B build -S llvm "${USE_NEW_COMPILER[@]}" "${COMMON_OPTS[@]}" "${NEW_COMMON_OPTS[@]}" -DLLVM_PROFDATA_FILE=$(realpath combined.prof) -DCMAKE_EXE_LINKER_FLAGS="-Wl,--emit-relocs" -DCMAKE_INSTALL_PREFIX=/usr -DLLVM_LIBDIR_SUFFIX=64
    ninja -C build

    #XXX: skipping BOLT for arm64 for now, since it causes segfault
    if [ "${CLANG_ARCH}" != "arm64" ]; then
        # BOLT phase
        mv build/bin/clang-17 build/bin/clang-17.prebolt
        mkdir -p build/profiles
        $STAGE0_BIN/llvm-bolt build/bin/clang-17.prebolt -o build/bin/clang-17 --instrument --instrumentation-file=$DIR/stage-1-${CLANG_ARCH}/build/profiles/prof --instrumentation-file-append-pid --conservative-instrumentation

        #3rd ScyllaDB compilation: gathering a clang profile for BOLT
        cd ../scylla-${CLANG_ARCH}
        rm -rf build build.ninja
        ./configure.py "${SCYLLA_OPTS[@]}"
        ninja build

        cd ../stage-1-${CLANG_ARCH}
        $STAGE0_BIN/merge-fdata build/profiles/*.fdata > prof.fdata
        $STAGE0_BIN/llvm-bolt build/bin/clang-17.prebolt -o build/bin/clang-17 --data=prof.fdata --reorder-functions=hfsort --reorder-blocks=ext-tsp --split-functions --split-all-cold --split-eh --dyno-stats
    fi

    if [ "${CLANG_BUILD}" = "INSTALL" ]; then
        sudo ninja -C build install
    elif [ "${CLANG_BUILD}" = "BUILD" ]; then
        cd ../
        rm -rf stage-1-${CLANG_ARCH}/build/profiles
        rm -f stage-1-${CLANG_ARCH}/*.{prof,fdata}
        tar -cpzf ${DIR}/optimized_clang-${CLANG_ARCH}.tar.gz stage-1-${CLANG_ARCH}
    fi
elif [ "${CLANG_BUILD}" = "INSTALL_PREBUILT" ]; then
    cd "${DIR}"
    tar -xpzf ${DIR}/optimized_clang-${CLANG_ARCH}.tar.gz
    cd stage-1-${CLANG_ARCH}
    sudo ninja -C build install
fi

cd ../
rm -rf $DIR/stage-*-${CLANG_ARCH} $DIR/scylla-${CLANG_ARCH}
