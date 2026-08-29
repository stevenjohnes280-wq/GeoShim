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

// Liveness handshake between the CLI and the copy of the tweak inside locationd.
// The CLI posts REQUEST and waits briefly for REPLY; the daemon answers by
// packing its live state into the REPLY name (notify_set_state) and posting it.
// No reply within the timeout means the tweak is not loaded in locationd.
#define GS_NOTIFY_STATUS_REQ   "xyz.regulad.geoshim/statusRequest"
#define GS_NOTIFY_STATUS_REPLY "xyz.regulad.geoshim/statusReply"

// Bit layout of the notify_set_state value carried on GS_NOTIFY_STATUS_REPLY.
#define GS_STATUS_ALIVE      (1ULL << 0)   // the daemon hook is loaded and answering
#define GS_STATUS_ENABLED    (1ULL << 1)   // config.enabled as the daemon sees it
#define GS_STATUS_CL_HOOK    (1ULL << 2)   // CLLocation encodeWithCoder: hook installed
#define GS_STATUS_VISIT_HOOK (1ULL << 3)   // CLVisit encodeWithCoder: hook installed
#define GS_STATUS_ROUTE_MODE (1ULL << 4)   // daemon is in route mode

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
