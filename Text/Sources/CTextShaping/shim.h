// The two C libraries behind the text stack, as one module.
//
// Keeping them in a single system-library target means SwiftPM resolves one
// pkg-config file (spritekit-text.pc, written by Android/Vendor/build.sh)
// instead of a Requires: chain, and hb-ft.h gets FreeType's headers in the
// same include path it expects.
#ifndef SKA_TEXT_SHIM_H
#define SKA_TEXT_SHIM_H

#include <ft2build.h>
#include <freetype/freetype.h>
#include <freetype/ftoutln.h>
#include <freetype/ftmm.h>
#include <freetype/ftsnames.h>
#include <freetype/ttnameid.h>
#include <freetype/tttables.h>
#include <freetype/ftbitmap.h>

#include <hb.h>
#include <hb-ft.h>

#endif
