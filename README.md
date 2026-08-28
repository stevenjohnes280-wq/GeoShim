# GeoShim

An iOS tweak that substitutes locations **in process**, inside CoreLocation, rather than
through `locationd`'s simulation channel.

That distinction is the whole point. Tools built on `CLSimulationManager` (Xcode's DDI,
`locsim`) deliver through the path iOS marks as simulated, so on iOS 15 and later every
`CLLocation` they produce reports `sourceInformation.isSimulatedBySoftware == YES` to
any app that asks — a public, documented API. GeoShim constructs the `CLLocation`
objects itself and therefore controls that property.

It hooks in **two places**:

1. **In the app** — the CoreLocation client hooks, for apps that let tweaks inject.
2. **In `locationd`** — the location daemon, for apps that *don't*. Under roothide, an
   app can be blacklisted so no tweak dylib is injected into it. Those apps still get
   their positions from `locationd` over XPC, so hooking the daemon reaches them anyway.
   This is the only interception point that works against a blacklisted app.

Target: **iOS 15.8.2, roothide** (roothide Bootstrap / Dopamine-roothide), ElleKit.
Package identifier `xyz.regulad.geoshim`. Paths are resolved at runtime with `jbroot()`;
nothing hardcodes the randomized jailbreak root.

---

## Status

Phase 1 and Phase 2 are implemented, plus the locationd interceptor. Everything builds
clean (zero warnings) under the **roothide** package scheme for `iphoneos-arm64e`
against the iOS 16.5 SDK with a 15.0 deployment target.

**Nothing here has been run on a device yet.** The compile is verified; the runtime is
not. The locationd path in particular rests on two device-only assumptions — read
[Open VERIFY items](#open-verify-items) before trusting it — and daemon injection on
iOS 15 is itself the biggest unknown. Work through [Verification](#verification) in
order.

---

## Layout

| Path | What it is |
|---|---|
| `Tweak.x` | The three hook sites, delegate swizzling, synthetic update timer |
| `GSConfig.{h,m}` | Immutable snapshot of the preferences plist; Darwin-notification reload |
| `GSLocationFactory.{h,m}` | Builds the `CLLocation`; noise, accuracy, `sourceInformation` |
| `GSRouteEngine.{h,m}` | GPX parsing, haversine cumulative distance, interpolation |
| `GSCommon.h` | Identifier, `jbroot()`-based paths, logging gate |
| `cli/main.m` | The `geoshim` command-line tool |
| `GeoShim.plist` | Injection filter — `com.apple.Maps` **and** the `locationd` executable |
| `examples/tokyo-loop.gpx` | A short loop for smoke-testing route mode |

`Tweak.x` splits into two halves at load time (`gs_isLocationd()`): the grouped
`GSClientHooks` (`CLLocationManager`) install in apps only, and a single manual swizzle
of `-[CLLocation encodeWithCoder:]` installs in `locationd` only.

---

## Building

Theos on Linux (this tree was built from WSL2 Fedora against Theos with the
`iPhoneOS16.5.sdk` and the Linux toolchain). Two requirements beyond a stock Theos:

- **roothide Theos support.** The `roothide` package scheme and the `jbroot()` API
  (`<roothide.h>`) come from roothide's Theos fork/patches. A stock Theos has neither
  and the build fails at `'roothide' package scheme does not exist`. Install roothide
  support per <https://roothidebootstrap.com/develop/> (or switch your Theos to the
  roothide branch). This tree was built against that.
- Two host tools Fedora does not ship:

```bash
sudo dnf install -y dpkg                 # dpkg-deb, for packaging
git clone --depth 1 https://github.com/ProcursusTeam/ldid.git && cd ldid
make && sudo install -m 0755 ldid /usr/local/bin/ldid    # for signing
```

`THEOS_PACKAGE_SCHEME = roothide` is set in the Makefile, so the deb comes out
`iphoneos-arm64e` with files staged at jbroot-relative paths (no `/var/jb`), linked
against `libroothide.dylib` via the `.jbroot` symlink. Then:

```bash
export THEOS=$HOME/theos
export PATH=/usr/local/bin:$PATH

make package                    # debug build, logging still off
make package GEOSHIM_DEBUG=1    # debug build with 1 Hz logging (use for bring-up)
make package FINALPACKAGE=1     # release; ship this
```

The `.deb` lands in `packages/`. Installing:

```bash
make package install THEOS_DEVICE_IP=<device> THEOS_DEVICE_PORT=22
# or copy the .deb over and: dpkg -i xyz.regulad.geoshim_*.deb
#   then: killall -9 Maps locationd
```

The jailbreak prefix is never written in source. Both the dylib and the CLI resolve the
preferences and route paths at runtime with `jbroot(@"/var/mobile/...")`, so the app,
`locationd` and the CLI all agree on one absolute path without any of them knowing the
randomized root.

### Enabling locationd injection (required for blacklisted apps)

`locationd` only receives tweaks if roothide re-signs it, which it does for executables
listed in `resignList.plist`. **`/usr/libexec/locationd` is in roothide's default list**,
so no action is normally needed. Confirm on device:

```bash
grep -c locationd $(jbroot)/basebin/resignList.plist   # expect 1; jbroot = your root
```

If it is missing, add `<string>/usr/libexec/locationd</string>` to the `executables`
array and reboot. Note the caveat in [Open VERIFY items](#open-verify-items): roothide's
daemon injection is documented for iOS 16–17, and its status on 15.8.2 is the single
biggest unknown in this project.

> Building from Windows via `wsl.exe`: pass the script on stdin
> (`wsl.exe -d <distro> -- bash < script.sh`). Passing it as `bash -lc '...'` gets the
> `$VAR` references mangled in transit.

---

## Using it

```
geoshim start -x 35.6812 -y 139.7671 [-a 40.0] [options]
geoshim route <file.gpx> [--speed 1.4] [--loop|--reverse|--stop]
geoshim stop
geoshim status
```

Options for `start`:

| Flag | Effect |
|---|---|
| `--source-info <nil\|clean\|passthrough>` | how `CLLocation.sourceInformation` reads |
| `--jitter <metres>` | per-update coordinate noise (default 2 m) |
| `--interval <seconds>` | synthetic update cadence (default 1 s) |
| `--no-synthesize` | only substitute real callbacks; never invent one |
| `--debug-log-real` | log genuine fixes — needs a `GEOSHIM_DEBUG=1` build |

The tool writes the plist, makes it readable by `mobile`, and posts
`xyz.regulad.geoshim/prefsChanged`. Changes take effect immediately in every already
running client; no respring.

`geoshim route` copies the GPX to `/var/jb/var/mobile/Library/GeoShim/route.gpx` so it
sits next to the preferences with the same ownership, and points `RoutePlistPath` there.
A route file left in `/var/root` or `/tmp` would not be readable from a sandboxed app.

Convert real routes to GPX with <https://mapstogpx.com/>.

### Preferences

`/var/jb/var/mobile/Library/Preferences/xyz.regulad.geoshim.plist`

| Key | Type | Default | Meaning |
|---|---|---|---|
| `Enabled` | bool | false | Master switch |
| `Latitude` / `Longitude` | real | — | Static coordinate; also the route fallback |
| `Altitude` | real | 0 | Metres. Set it — 0 m in Denver is a tell |
| `Mode` | string | `static` | `static` or `route` |
| `SourceInfoMode` | string | `nil` | `nil`, `clean`, `passthrough` |
| `JitterMetres` | real | 2.0 | Gaussian coordinate noise per update |
| `UpdateIntervalSec` | real | 1.0 | Synthetic update cadence |
| `RoutePlistPath` | string | "" | Path to a `.gpx` or `.plist` route |
| `RouteLoop` | bool | true | Loop at the end of the route |
| `RouteEndBehavior` | string | from `RouteLoop` | `loop`, `reverse`, `stop` |
| `RouteSpeedMps` | real | 1.4 | Base speed; varied ±10% per tick |
| `SynthesizeUpdates` | bool | true | Deliver on a timer even with no real fixes |
| `LogRealFixes` | bool | false | Debug builds only; logs genuine fixes |

Anything unparseable — a missing plist, a bad coordinate, a route with fewer than two
points — resolves to *disabled*, not to an error. The tweak fails open by construction.

---

## How it works

### Two processes, two strategies

At load, `gs_isLocationd()` (a `getprogname()` check) decides which half runs. The two
never coexist in one process, which bounds the blast radius of each.

**In `locationd` — one hook.** Positions are handed to clients as an NSSecureCoding keyed
archive over XPC (`bplist17`, confirmed by
[8kSec's Frida teardown](https://8ksec.io/advanced-frida-usage-part-4-sniffing-location-data-from-locationd-in-ios/)),
so `-[CLLocation encodeWithCoder:]` is the outbound serialisation chokepoint — and it is
reached even when the client blocks in-process injection. Rather than guess the archive's
key names, GeoShim replaces the *object* being encoded: it builds a fully spoofed
`CLLocation` and runs the original encoder against that. Whatever keys `CLLocation`
normally writes, it writes for the fake. Fixes with an invalid coordinate (region/visit
archiving and other internal round-trips) are left alone, and anything that throws falls
through to the real encode. This is why a roothide-blacklisted app is still spoofed.

**In the app — the client hooks (below).** These are still worth installing for apps that
*do* allow injection: they give per-app control the daemon cannot (the daemon spoofs
every client at once), and the synthetic-update timer works even when the app has no
fix to serialise.

Three hook sites on `CLLocationManager` (grouped `GSClientHooks`, apps only):

- **`-location`** — for apps that poll rather than subscribe.
- **`-setDelegate:`** — the delegate class lives in the host app, so it cannot be
  `%hook`ed by name. On first sight of a delegate class we swizzle
  `locationManager:didUpdateLocations:` and the legacy
  `locationManager:didUpdateToLocation:fromLocation:`, replacing the location argument
  and calling on to the original IMP. Each class is swizzled exactly once (a set of
  class pointers); a class that does not implement a callback does not get one added.
- **`-startUpdatingLocation`** / `-stopUpdatingLocation` / `-requestLocation` — a
  dispatch timer delivers spoofed updates on a cadence, so the tweak still works when
  permission is denied or GPS is cold and no real callback ever arrives. The timer skips
  a tick if a real callback landed within the last 1.5 intervals, so the app is not fed
  two fixes for one moment, and it calls the original IMP directly so its own delivery
  is never mistaken for a real one.

**Nothing is installed while `Enabled` is false.** No swizzles, no timers — the hooks
call `%orig` and return. Enabling applies the state to every manager seen so far, so
live toggling works without a restart. One asymmetry to know about: *disabling* after
having been enabled cannot remove a swizzle, so the delegate keeps a pass-through hook
until the app is restarted. Behaviour is unchanged; the runtime shape is not.

### Making the fix look real

Per-update, every field is populated rather than left at a placeholder:

- coordinate jittered by a Gaussian ±`JitterMetres` (metres → degrees corrected for
  latitude, with `cos(lat)` clamped near the poles)
- `horizontalAccuracy` is a random walk over 5–65 m, `verticalAccuracy` over 3–10 m —
  a walk, not a constant and not uniform noise, because that is how a receiver behaves
  as its solution firms up or degrades
- `speed` 0 ± small noise when stationary, from the polyline when moving;
  `speedAccuracy` a small positive value, never −1
- `course` −1 when stationary, the segment bearing when moving, blended across vertices
  rather than snapped; `courseAccuracy` positive only when the course is valid
- `altitude` from config ± 0.5 m
- `timestamp` is `[NSDate date]` at delivery

Route mode advances a distance cursor by `speed × elapsed` along the cumulative
haversine polyline, varies speed ±10%, and eases through sharp turns instead of
pivoting at full speed.

### `sourceInformation`

`SourceInfoMode` has three states, per the brief, so you can A/B them against a real
target:

- **`nil`** (default) — the public initializer, so the property is `nil`. This is what a
  `CLLocation` built by anyone else looks like, and it needs no private API at all.
- **`clean`** — attaches `[[CLLocationSourceInformation alloc]
  initWithSoftwareSimulationState:NO andExternalAccessoryState:NO]`. That initializer is
  **public API**, declared in `CLLocation.h` and available since iOS 15.0 — confirmed in
  the SDK, not guessed.
- **`passthrough`** — copies whatever the last genuine fix reported.

Attaching the object to a `CLLocation` is the part with no public answer. Two
strategies, resolved once at first use and logged in debug builds:

1. A private initializer taking the source info. It is looked up by name **and validated
   against its own `NSMethodSignature`** — 12 arguments, a struct, seven doubles, then
   two objects — before it is ever invoked. A selector that exists with a different
   shape is rejected rather than called.
2. Otherwise a `CLLocation` subclass overriding `-sourceInformation`. Always works,
   costs no private API, and is scoped to the objects we build — but see Known limits.

---

## Verification

Work these in order. A debug-logging build (`make package GEOSHIM_DEBUG=1`) is the right
one for steps 1–4; watch with `idevicesyslog | grep geoshim` or `oslog` on device.

1. **It loads — in both processes.** Launch Maps and expect
   `[geoshim] loaded in Maps (client enabled=0 …)`. Then check the daemon:
   `[geoshim] loaded in locationd (daemon …)` followed by
   `[geoshim] locationd: encodeWithCoder: hook installed`. **If the locationd line never
   appears, daemon injection is not happening** — this is the make-or-break test on
   iOS 15; see [Open VERIFY items](#open-verify-items). `killall -9 locationd` to force
   a reload while watching the log.
2. **Preferences are readable — from locationd.** `geoshim start -x 35.6812 -y 139.7671`.
   A `[geoshim] config: no readable plist at …` line *from locationd* means the daemon's
   sandbox is blocking the jbroot read (VERIFY item 4); from an app it means the app
   sandbox is (see Troubleshooting).
3. **The blacklisted app moves.** With the target app on roothide's blacklist (no
   injection into it), spoof a coordinate in another hemisphere and confirm its position
   changes anyway. In a `GEOSHIM_DEBUG=1` build, locationd logs
   `[geoshim] locationd: encode <real> -> <fake>` on each outbound fix — that line is
   proof the daemon path is doing the work. If the app does not move but the line is
   logged, locationd is *not* delivering via `encodeWithCoder:` on this version and the
   fallback in [Open VERIFY items](#open-verify-items) applies.
4. **The injectable app moves (client path).** In Maps (not blacklisted), tap locate. If
   it does not move, check whether `[geoshim] hook: delegate class …` was logged: no line
   means `setDelegate:` never fired and Maps is polling `-location` instead.
5. **Property sanity.** Compare a few consecutive deliveries against the table above.
   Constant accuracy or a stale timestamp means something is wrong.
6. **`sourceInformation` behaves as designed.** Build with `GEOSHIM_DEBUG=1`,
   `geoshim start … --debug-log-real`, read the `real fix:` lines with spoofing off. See
   [Open VERIFY items](#open-verify-items).
7. **No regression when disabled.** `geoshim stop`, restart the app *and*
   `killall -9 locationd`, confirm behaviour is identical to the tweak not being
   installed. This is the safety net; do not skip it.
8. **Then widen the filter,** one target at a time, testing after each.

`geoshim status` also reports the parsed point count and length of a loaded route, which
is the quickest way to confirm the GPX parser handled your file.

---

## Rollback

Read this before widening the injection filter.

This tweak injects into `locationd`, a system daemon that every process relies on for
location. A crash in our dylib is a crash in `locationd`. Have this ready **before** you
first install, not after.

```bash
ssh root@<device>
# jbroot is your randomized root; `jbroot /path` on device prints the real path.
mv "$(jbroot /Library/MobileSubstrate/DynamicLibraries/GeoShim.dylib)"{,.disabled}
killall -9 locationd SpringBoard
```

Moving the `.dylib` aside is enough — with the dylib gone the `.plist` filter matches
nothing. To remove it entirely: `dpkg -r xyz.regulad.geoshim`. If `locationd` itself is
crash-looping, the device stays usable (location just stops working) and SSH still works,
which is why the daemon target is survivable where SpringBoard would not be.

The filter ships matching `com.apple.Maps` and the `locationd` executable. Widening the
app side to `com.apple.corelocation` (anything linking the framework) is a deliberate
later step. Do **not** add `com.apple.springboard`, `backboardd`, or other UI-critical
processes casually — that is the difference between a bug that annoys you and a bug that
bootloops you.

---

## Open VERIFY items

Ordered by how likely they are to sink the locationd approach. The first two are the
ones the whole daemon path rests on.

**1. Does roothide inject into `locationd` on iOS 15.8.2 at all?** *(biggest unknown)*
roothide's release notes tag "injecting into some system daemons (see `resignList.plist`)"
as **iOS 16.0–17.0**. `launchd` injection is documented back to iOS 15.8, and
`/usr/libexec/locationd` is in the default `resignList.plist`, so the mechanism and the
allow-list entry both exist on 15 — but whether the daemon-injection path is actually
wired on 15.8.2 is unconfirmed. **Test first** (Verification step 1): if
`loaded in locationd` never logs, this project's core does not work on your build, and
no amount of the code below matters. There is no in-repo workaround; it is a property of
the bootstrap.

**2. Does `locationd` deliver client fixes via `-[CLLocation encodeWithCoder:]`?**
The interception assumes locationd serialises outbound positions as an NSSecureCoding
keyed archive — strongly implied by the `bplist17` payloads seen in the Frida teardown,
but not proven for 15.8.2. Confirm with a `GEOSHIM_DEBUG=1` build: if
`locationd: encode <real> -> <fake>` logs on every fix *and* clients move, it holds. If
the hook installs but never logs on the delivery path, locationd is building the XPC
dictionary from raw doubles instead. **Fallback:** class-dump `/usr/libexec/locationd`
on device, find the per-client delivery selector (look around `CLDaemon` /
`CLXPCConnection` / the position-broadcast method), and swizzle that, or rewrite the
outbound `xpc_dictionary` at the C layer. Both need the on-device dump this environment
could not produce.

**3. Can `locationd`'s sandbox read the prefs plist under the randomized jbroot?**
The plist lives at `jbroot(/var/mobile/Library/Preferences/…)`. An injected daemon
normally inherits roothide's sandbox extensions, but if locationd logs
`config: no readable plist`, it cannot reach jbroot. Remedy: stage the plist somewhere in
locationd's existing sandbox, or grant an extension. Isolated from the rest.

**4. What does a genuine fix report for `sourceInformation` on 15.8.2?**
Build with `GEOSHIM_DEBUG=1`, set `LogRealFixes`, read `real fix:` with spoofing off:

- `sourceInfo=(null)` → `SourceInfoMode = nil` is correct; the default needs no private
  API.
- non-nil with both flags `NO` → nil is anomalous; switch to `--source-info clean`.

Note the daemon path has a wrinkle here: replacing the encoded object only carries
`sourceInformation` if the private initializer (strategy 1) is live, because the
subclass fallback stores the object in an override, not the ivar `encodeWithCoder:`
reads. Coordinate/altitude/speed/course/timestamp always carry.

**5. Is `Depends: ellekit` right for roothide?**
roothide links `libroothide.dylib` and `libsubstrate.dylib` (ElleKit). `Depends: ellekit`
is the usual name; confirm with `dpkg -l | grep -iE "ellekit|substrate"` and edit
`control` if your bootstrap names it differently.

Resolved without a device, no further work:

- **roothide packaging** — `THEOS_PACKAGE_SCHEME = roothide` builds `iphoneos-arm64e`
  with jbroot-relative paths and links `jbroot()` from `libroothide.dylib` via the
  `.jbroot` symlink. Confirmed with `dpkg-deb -c` and `strings`/`nm` on the dylib.
- `-[CLLocationSourceInformation initWithSoftwareSimulationState:andExternalAccessoryState:]`
  is **public**, declared in `CLLocation.h` (iOS 15.0+). Confirmed in the SDK.
- The prefs path needs no coordination: the dylib and CLI both resolve it through the
  same `jbroot()` input at runtime.
- Whether a `CLLocation` initializer taking source info exists is answered at runtime by
  probe-and-validate, not a static guess.

---

## Troubleshooting

**`loaded in locationd` never appears** — daemon injection is not happening. Confirm
`/usr/libexec/locationd` is in `resignList.plist` and reboot; if it is present and still
no injection, roothide's daemon path is likely not wired on your iOS 15 build (VERIFY 1).

**`config: no readable plist`** — a sandbox is refusing the read. Confirm the file exists
and is `mobile`-readable (`ls -l` it; `geoshim` sets 0644 and chowns to 501:501 when run
as root). From an *app*, `libSandy` is the usual remedy. From *locationd*, it is VERIFY 3
— the daemon cannot reach jbroot.

**Blacklisted app does not move, but `locationd: encode …` logs** — locationd is not
delivering via `encodeWithCoder:` on this version (VERIFY 2); the fallback there applies.

**Blue dot does not move in an injectable app but the tweak logs on load** — the app is
polling `-location`, or it caches the first fix. Check for `hook: delegate class …` lines.

**Route mode behaves as static** — the route failed to load, and the config deliberately
degrades to the static coordinate. Run `geoshim status`; a point count under 2 means the
GPX had no `trkpt`/`rtept`/`wpt` elements the parser recognised.

---

## Known limits

This defeats `sourceInformation` checks. It does not defeat:

- **Injected-image detection.** `_dyld_image_count` / `_dyld_get_image_name` will list
  `GeoShim.dylib`. Any app that walks its own image list sees it.
- **Jailbreak detection** in general. Out of scope.
- **Class identity, in `clean`/`passthrough` mode with the subclass fallback.** If the
  private initializer is not available, `object_getClass()` on a delivered location
  returns `GSLocation`, not `CLLocation`. `isKindOfClass:` is satisfied; an exact class
  comparison is not. The default `nil` mode returns a genuine `CLLocation` and does not
  have this property.
- **Corroboration.** Wi-Fi BSSIDs in range, serving cell MCC/MNC/LAC/CID, IP
  geolocation, device timezone and barometric altitude all still describe where the
  phone actually is. A server-side check against any of them is unaffected by anything
  that happens inside `CLLocationManager`.
- **Sensor disagreement.** `CMMotionActivity` reports stationary while your position
  advances at highway speed. Route mode makes the location trace plausible *in
  isolation*; it does not fabricate matching accelerometer data.
- **Region and beacon callbacks.** `didEnterRegion`, `didExitRegion`, `didVisit`,
  beacon ranging and the rest of the delegate surface are not intercepted, so geofences
  still fire against the real position. Phase 3, if ever.

It also has consequences worth knowing:

- **The daemon hook is system-wide by design.** When it is active, *every* location
  client is spoofed at once — you cannot spoof one app and leave another real through the
  daemon path. Per-app control only exists on the client-injection side.
- **`encodeWithCoder:` replacement is broad within locationd.** Any outbound fix with a
  valid coordinate is rewritten, including ones locationd archives for its own use — so
  Settings → Privacy → Location → System Services → Significant Locations will accumulate
  spoofed entries while spoofing is on. Invalid-coordinate objects (regions, visits) are
  left alone, but this is a wider brush than a single client hook.

The failure mode for this kind of tool is a user who believes it is stronger than it is.

---

## Credit

`locsim` (<https://github.com/udevsharold/locsim>, GPLv3) is worth reading for its
coordinate and GPX plumbing, even though its delivery mechanism — `CLSimulationManager`,
gated by `com.apple.locationd.simulation` — is precisely the one this project avoids.
