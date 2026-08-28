// GSCommon.h - shared identifiers, paths and logging.
#import <Foundation/Foundation.h>

// jbroot() converts a jbroot-relative path to the real absolute path under the
// randomized roothide root, resolving through the .jbroot symlink at runtime.
// The header's stub falls back to the rootless macros for a plain rootless
// build, so the same source compiles either way.
#import <roothide.h>

#ifndef GS_IDENTIFIER
#define GS_IDENTIFIER @"xyz.regulad.geoshim"
#endif

// Both the CLI and the injected dylib resolve these through jbroot(), so the
// app, locationd and the CLI all agree on one absolute path without hardcoding
// the randomized prefix. These are jbroot-RELATIVE inputs; jbroot() returns the
// real path. Do not prepend a prefix.
#define GS_PREFS_PATH   jbroot(@"/var/mobile/Library/Preferences/xyz.regulad.geoshim.plist")
#define GS_STATE_DIR    jbroot(@"/var/mobile/Library/GeoShim")

// Darwin notification posted by the CLI after it rewrites the plist. Darwin
// notifications are system-wide, so a post from the CLI reaches both the app
// and locationd.
#define GS_NOTIFY_NAME "xyz.regulad.geoshim/prefsChanged"

// Everything is silent in release builds. A tweak that logs at 1 Hz inside
// every CoreLocation client - and inside locationd itself - makes the device
// unpleasant to diagnose.
#ifdef GEOSHIM_DEBUG
#define GSLog(fmt, ...) NSLog(@"[geoshim] " fmt, ##__VA_ARGS__)
#define GEOSHIM_DEBUG_BUILD 1
#else
// Release builds still type-check the format string and count the arguments
// as used, but the call is dead code and is removed by the optimiser.
#define GSLog(fmt, ...) do { if (0) NSLog(@"[geoshim] " fmt, ##__VA_ARGS__); } while (0)
#define GEOSHIM_DEBUG_BUILD 0
#endif
