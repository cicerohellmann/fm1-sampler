#!/bin/zsh
# Host tests of the iOS-only C++ (the RemoteFM1 bridge), built with the engine and libremotefm1 (ASan + UBSan).
set -e
cd "${0:A:h}"
R=../..; E=$R/engine; V=../ThirdParty/remotefm1; S=../FM1Sampler/Sources
B=build; rm -rf $B; mkdir -p $B
FLAGS=(-O1 -g -fsanitize=address,undefined -fno-omit-frame-pointer -DSAMPLERATE=44100)
INC=(-I$E/dsp -I$E/session -I$E/app -I$E/ui -I$E/tools -I$E/3rdparty/kissfft -I$V/include -I$V/proto -I$V/firmware/src -I$S)
for f in $V/src/*.c $E/3rdparty/kissfft/kiss_fft.c $E/3rdparty/kissfft/kiss_fftr.c; do clang -std=c99 -w $FLAGS $INC -c $f -o $B/c_${${f:h}:t}_${${f:t}%.c}.o; done
for f in $E/dsp/*.cpp $E/session/*.cpp $E/app/*.cpp $E/ui/*.cpp $S/RemoteBridge.cpp remote_bridge_test.cpp; do clang++ -std=c++20 -w $FLAGS $INC -c $f -o $B/x_${${f:h}:t}_${${f:t}%.cpp}.o; done
clang++ -std=c++20 -w $FLAGS $INC -x c++ -c $S/Core.mm -o $B/Core.o
clang++ $FLAGS $B/*.o -o $B/remote_bridge_test
(( $# )) || set -- ${R:A}/samples   # the bundled library (the app ships it); a key sounds nothing without a sample
$B/remote_bridge_test "$@"
