// GSCommon.h - shared identifiers, paths and logging.
#import <Foundation/Foundation.h>
#import <math.h>
#import <stdint.h>

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

// Bit layout of the 64-bit notify_set_state value carried on
// GS_NOTIFY_STATUS_REPLY. Low bits are status flags; bits 16..47 carry a 32-bit
// fingerprint of the coordinate the daemon is actively serving, so the CLI and
// Settings can assert locationd holds the configured value without transmitting
// full precision.
#define GS_STATUS_ALIVE      (1ULL << 0)   // the daemon hook is loaded and answering
#define GS_STATUS_ENABLED    (1ULL << 1)   // config.enabled as the daemon sees it
#define GS_STATUS_CL_HOOK    (1ULL << 2)   // CLLocation encodeWithCoder: hook installed
#define GS_STATUS_VISIT_HOOK (1ULL << 3)   // CLVisit encodeWithCoder: hook installed
#define GS_STATUS_FP_SHIFT   16
#define GS_STATUS_FP_MASK    0xFFFFFFFFULL

// Stable 32-bit fingerprint of a coordinate, quantized to ~1e-5 deg (~1.1 m).
// The daemon reports the fingerprint of the coordinate it is serving; the CLI
// and Settings compute the same from the configured coordinate and compare.
// A fingerprint match asserts locationd is serving the configured value. Defined
// inline so the daemon, CLI and Settings bundle all use identical logic.
static inline uint32_t gs_coord_fingerprint(double lat, double lon) {
    int32_t qlat = (int32_t)llround(lat * 100000.0);
    int32_t qlon = (int32_t)llround(lon * 100000.0);
    uint64_t v = ((uint64_t)(uint32_t)qlat << 32) | (uint32_t)(uint32_t)qlon;
    uint64_t h = 1469598103934665603ULL;          // FNV-1a 64-bit
    for (int i = 0; i < 8; i++) {
        h ^= (v >> (i * 8)) & 0xffULL;
        h *= 1099511628211ULL;
    }
    return (uint32_t)(h ^ (h >> 32));
}

// Everything is silent in release builds. A tweak that logs at 1 Hz inside
// every CoreLocation client - and inside locationd itself - makes the device
// unpleasant to diagnose.
#ifdef GEOSHIM_DEBUG
#define GSLog(fmt, ...) NSLog(@"[GeoShim] " fmt, ##__VA_ARGS__)
#define GEOSHIM_DEBUG_BUILD 1
#else
// Release builds still type-check the format string and count the arguments
// as used, but the call is dead code and is removed by the optimiser.
#define GSLog(fmt, ...) do { if (0) NSLog(@"[GeoShim] " fmt, ##__VA_ARGS__); } while (0)
#define GEOSHIM_DEBUG_BUILD 0
#endif
