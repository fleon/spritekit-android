#ifndef CZLIB_SHIM_H
#define CZLIB_SHIM_H

// zlib, which Android provides — libz.so is in config.sh's SYSTEM_LIBS, so
// it is never shipped in the APK. The Swift side uses it to inflate PNG
// pixel data; see PNGDecoder.swift.
#include <zlib.h>

#endif /* CZLIB_SHIM_H */
