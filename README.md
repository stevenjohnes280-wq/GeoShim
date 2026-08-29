# GeoShim

A jailbreak tweak that spoofs iOS location **system-wide by hooking `locationd`**, the
system location daemon — not the individual apps.

That is the whole point. The usual location fakers hook CoreLocation *inside each app*,
which fails against an app you cannot inject into. Under roothide you can **blacklist**
an app so no tweak dylib is loaded into it (to hide the jailbreak). But every app still
gets its position from `locationd` over XPC — so hooking the daemon reaches the
blacklisted app anyway. `locationd` is the one interception point that works against a
process you cannot touch, and it is the reason this project exists.

A second, **optional path** covers apps that *do* permit injection: an in-process
CoreLocation fallback, scoped **per app** from a Settings picker and on by default as a
subsystem. It adds what the daemon cannot — a synthetic update timer that keeps an app
moving even when the real subsystem is silent — but the daemon stays the path that reaches
the blacklisted target.

It also cleanly defeats `sourceInformation.isSimulatedBySoftware`: tools built on
`CLSimulationManager` (Xcode's DDI, `locsim`) deliver through the channel iOS marks as
simulated, so on iOS 15+ every `CLLocation` they produce reports `isSimulatedBySoftware
== YES` to any app that checks. GeoShim constructs the `CLLocation` objects itself, so it
controls that property.

**Target:** iOS 15.8.2, **Dopamine2‑roothide** (ElleKit / systemhook), `arm64e`.
Package `xyz.regulad.geoshim`. Paths are resolved at runtime with `jbroot()`; nothing
hardcodes the randomized jailbreak root.

**Status: confirmed working on-device.** The daemon-only build spoofs a
roothide‑blacklisted app's location on iOS 15.8.2 / Dopamine2‑roothide, verified in the
log by `locationd: encode <real> -> <fake>`.

---

## How it works

GeoShim has two paths and splits at load time by process. **The `locationd` daemon path is
primary** — and the only one that reaches a roothide-blacklisted app. Inside the daemon it
hooks the two points where an outbound, location-bearing object is serialized to a client.

Positions leave `locationd` as an **NSSecureCoding keyed archive over XPC** (`bplist17`,
confirmed by [8kSec's Frida teardown](https://8ksec.io/advanced-frida-usage-part-4-sniffing-location-data-from-locationd-in-ios/)
and on-device here), so the serializer is the chokepoint:

- **`-[CLLocation encodeWithCoder:]`** — the main path. Rather than guess the archive's
  key names, GeoShim replaces the *object* being encoded: it builds a fully spoofed
  `CLLocation` and runs the original encoder against that. Whatever keys `CLLocation`
  normally writes, it writes for the fake. Objects with an invalid coordinate are left
  alone; anything that throws falls through to the real encode.
- **`-[CLVisit encodeWithCoder:]`** — `CLVisit` carries its own coordinate and rides the
  same path, so a visit-monitoring app would otherwise see the real place. GeoShim
  rewrites the coordinate on a *copy* (never mutating the daemon's own object), reaching
  it through the `CLVisit` coordinate ivar since the class has no public initializer. The
  ivar offset is discovered at load; if the layout is unexpected the hook is simply not
  installed (fail closed — the real visit is encoded).

Everything fails **open**: any nil/throw path encodes the real object untouched. A crash
here is a crash in `locationd`, so every hook is nil-checked and wrapped.

The CLI also pings this path: `geoshim status` posts a Darwin notification the daemon
answers with its live state, so the tool can tell you the hook is *actually loaded in
locationd* rather than just echoing the plist it wrote. No reply means the tweak isn't live.

### The app-side fallback

In an app that *does* permit injection, GeoShim also hooks CoreLocation in-process. This is
redundancy plus the one thing the daemon cannot do: a **synthetic update timer** that keeps
the app moving even when the real subsystem is silent (permission denied, GPS cold, or a
poll-only client). It is scoped **per app** — nothing installs unless the app is switched on
in **Settings → GeoShim → Apps** (an AltList picker, the same model VPNHide and Choicy use)
while the master switch (`geoshim fallback`, on by default) is on.

- **`-[CLLocationManager setDelegate:]`** — the delegate lives in the host app, so its
  callbacks can't be hooked by name. On first sight of a delegate class GeoShim swizzles
  `locationManager:didUpdateLocations:` and the legacy
  `locationManager:didUpdateToLocation:fromLocation:` once, substituting the location
  argument and calling on to the original.
- **`-[CLLocationManager location]`** — for apps that poll rather than subscribe.
- **`startUpdatingLocation` / `stopUpdatingLocation` / `requestLocation`** — drive the
  synthetic timer. It skips a tick if a real callback landed within the last 1.5 intervals
  (so the app is never fed two fixes for one moment) and delivers through the delegate's
  *original* IMP, so its own delivery is never re-substituted or mistaken for a real fix.

Reading the enable-list and coordinate from inside a sandboxed app is the interesting part:
cfprefsd denies a foreign app the cross-domain read, so GeoShim applies a
[libSandy](https://github.com/roothide/libSandy) profile
(`layout/Library/libSandy/GeoShim.plist`) in its constructor, granting a sandbox file-read
extension on the prefs plist and the staged route. The roothide libSandy fork runs
`jbroot()` on the profile path before issuing the extension, and GeoShim reads those same
`jbroot()`'d paths (`GSCommon.h`), so the grant and the read line up. The daemon path needs
none of this — `locationd` reads the plist directly.

### Making the fix look real

`GSLocationFactory` populates every field per delivery rather than leaving placeholders:

- coordinate jittered by a Gaussian ±`JitterMetres` (metres → degrees, latitude-corrected,
  `cos(lat)` clamped near the poles)
- `horizontalAccuracy` a random walk over 5–65 m, `verticalAccuracy` over 3–10 m — a walk,
  not a constant and not uniform noise, because that is how a receiver behaves as its
  solution firms up or degrades
- `speed` 0 ± small noise when stationary, derived from the polyline when moving;
  `speedAccuracy` a small positive value, never −1
- `course` −1 when stationary, the segment bearing when moving (blended across vertices,
  not snapped); `courseAccuracy` positive only when the course is valid
- `altitude` from config ± 0.5 m; `timestamp` is `[NSDate date]` at delivery

Route mode advances a distance cursor by `speed × elapsed` along the cumulative haversine
polyline, varies speed ±10%, and eases through sharp turns.

### `sourceInformation`

`SourceInfoMode` selects how the property reads, so you can A/B it against a target:

- **`nil`** (default) — the public initializer, so the property is `nil`. This is what any
  ordinary `CLLocation` looks like, and it needs no private API.
- **`clean`** — attaches `[[CLLocationSourceInformation alloc]
  initWithSoftwareSimulationState:NO andExternalAccessoryState:NO]`. That initializer is
  **public**, declared in `CLLocation.h` since iOS 15.0.
- **`passthrough`** — copies whatever the last genuine fix reported.

Attaching the object is the one part with no public answer. Two strategies, resolved once
and logged in debug builds: (1) a private initializer taking the source info, looked up by
name **and validated against its own `NSMethodSignature`** before being invoked, else
(2) a `CLLocation` subclass overriding `-sourceInformation`. See [Known limits](#known-limits)
for the class-identity caveat of strategy 2.

---

## Layout

| Path | What it is |
|---|---|
| `Tweak.x` | Both paths: the locationd `CLLocation`/`CLVisit` swizzles + status responder, and the app-side `CLLocationManager` fallback hooks |
| `GSLocationFactory.{h,m}` | Builds the spoofed `CLLocation`; noise, accuracy, `sourceInformation` |
| `GSRouteEngine.{h,m}` | GPX parsing, haversine cumulative distance, interpolation |
| `GSConfig.{h,m}` | Preferences snapshot (incl. `AppFallback` / `EnabledBundles`); Darwin-notification live reload |
| `GSCommon.h` | Identifier, `jbroot()`-based paths, status-ping notify names, logging gate |
| `cli/main.m` | The `geoshim` control tool (writes prefs, pings the daemon) |
| `cli/entitlements.plist` | roothide `no-sandbox` entitlements for the CLI (see Building) |
| `prefs/` | Settings bundle — the AltList app picker for the fallback |
| `GeoShim.plist` | Injection filter — `locationd` **and** `CLLocationManager`-using apps |
| `layout/Library/libSandy/GeoShim.plist` | libSandy profile granting the prefs/route file-read extension |
| `layout/Library/PreferenceLoader/Preferences/GeoShim.plist` | Settings entry |
| `examples/tokyo-loop.gpx` | A short loop for smoke-testing route mode |

---

## Building

Theos on Linux (this tree builds from WSL2 Fedora against the `iPhoneOS16.5.sdk` and the
Linux toolchain). Requirements beyond a stock Theos:

- **roothide Theos support** — the `roothide` package scheme and `jbroot()` (`<roothide.h>`)
  come from roothide's Theos fork. A stock Theos fails at `'roothide' package scheme does
  not exist`. Install per <https://roothidebootstrap.com/develop/> or switch Theos to the
  roothide branch.
- **`dpkg` and `ldid`**, which Fedora does not ship:

```bash
sudo dnf install -y dpkg
git clone --depth 1 https://github.com/ProcursusTeam/ldid.git && cd ldid
make && sudo install -m 0755 ldid /usr/local/bin/ldid
```

- **AltList and libSandy staged into Theos** — the Settings picker links AltList's
  `ATLApplicationListMultiSelectionController`, and the tweak links `-lsandy` (roothide's
  libSandy fork). roothide's Theos bundles both; if a link step fails, run AltList's
  `install_to_theos.sh` once. These are also runtime `Depends` in `control`
  (`com.opa334.altlist`, `com.opa334.libsandy`, `preferenceloader`).

Then:

```bash
export THEOS=$HOME/theos
export PATH=/usr/local/bin:$PATH

make package GEOSHIM_DEBUG=1    # 1 Hz logging in locationd — use for bring-up
make package FINALPACKAGE=1     # silent release — ship this
```

`THEOS_PACKAGE_SCHEME = roothide` (in the Makefile) produces an `iphoneos-arm64e` deb with
files staged at jbroot-relative paths (no `/var/jb`), linked against `libroothide.dylib`
via the `.jbroot` symlink. The `.deb` lands in `packages/`.

### The CLI needs roothide entitlements

`cli/entitlements.plist` (the four keys from roothide's `entitlements.md` —
`platform-application`, `com.apple.private.security.no-sandbox`, `…storage.AppBundles`,
`…storage.AppDataContainers`) is signed into `geoshim` via `geoshim_CODESIGN_FLAGS`.
**Without `no-sandbox` the tool runs containerized**: its preference writes land in a
private container `locationd` never sees, and dyld is denied access to jbroot libraries
(so it fails to load even when the file is present). This is not optional.

> **Build from Windows via `wsl.exe`:** pass the script on stdin
> (`wsl.exe -d <distro> -- bash < script.sh`). As `bash -lc '...'` the `$VAR` references
> get mangled in transit.

---

## Installing

**Install through Sileo/Zebra (or `apt`), not a bare `dpkg -i`.** roothide's package
manager runs the dpkg pipeline that creates the per-directory **`.jbroot` symlinks** the
binaries need to resolve `@loader_path/.jbroot/...` dependencies. A wrong-context
`dpkg -i` can leave `.jbroot` pointing at `//` (the rootfs root), which breaks dylib
resolution — the symptom is `dyld: Library not loaded: @loader_path/.jbroot/usr/lib/…`.

```bash
# copy the .deb over, then on-device:
sudo apt install ./xyz.regulad.geoshim_0.2.0_iphoneos-arm64e.deb
killall -9 locationd
geoshim status
```

Dopamine2‑roothide injects `locationd` natively: systemhook is inserted into launchd and
hooks `posix_spawn`/`execve`, so every process — daemons included — inherits injection.
`locationd` is **not** on Dopamine's tweak-injection exclusion list (only `xpcproxy`
always, and `logd`/`notifyd`/`usermanagerd` on iOS 16+), so no `resignList` step is
required — that mechanism is specific to the TrollStore roothide *Bootstrap*, a different
product. Just make sure Tweak Injection is enabled and you are not in safe mode
(`ls "$(jbroot /basebin/.safe_mode)"`).

---

## Using it

```
geoshim start -x 35.6812 -y 139.7671 [-a 40.0] [options]
geoshim route <file.gpx> [--speed 1.4] [--loop|--reverse|--stop]
geoshim stop
geoshim fallback <on|off>
geoshim status
```

Options for `start`:

| Flag | Effect |
|---|---|
| `--source-info <nil\|clean\|passthrough>` | how `CLLocation.sourceInformation` reads |
| `--jitter <metres>` | per-update coordinate noise (default 2 m) |
| `--debug-log-real` | log genuine fixes — needs a `GEOSHIM_DEBUG=1` build |
| `--interval <s>`, `--no-synthesize` | synthetic-timer cadence / disable it — used by the app-side fallback |

`geoshim fallback on|off` is the master switch for the app-side hooks (on by default); the
locationd path is always active. Choose *which* apps the fallback covers in **Settings →
GeoShim → Apps**. `geoshim status` pings locationd (see below) and prints both the live
daemon state and the configured prefs, including the master switch and the picked apps.

### The Settings panel

Everything the CLI does is also on the **Settings → GeoShim** page (a PreferenceLoader
entry backed by the `GeoShimPrefs` bundle), so you never need a terminal for day-to-day
use:

- **Status** — a live read-only readout of the current **state** (enabled/disabled),
  **coordinate**, and **mode**, refreshed each time the page appears.
- **Spoofing → Enabled** — the master `Enabled` switch. Flipping it writes the prefs and
  posts the reload notification, so `locationd` applies it live, exactly like
  `geoshim start`/`stop`.
- **Set location on map…** — a full-screen **MapKit** picker. Pan the map under the
  crosshair (the live coordinate shows at the bottom) and tap **Save**; it writes
  `Latitude`/`Longitude` to the domain and posts the reload. It opens centred on the
  current coordinate.
- **App-side fallback** — the `AppFallback` master switch plus the **Apps** picker
  (AltList), which is the same `EnabledBundles` list the `geoshim fallback` command and the
  tweak's self-gate use.

The panel reads and writes the `xyz.regulad.geoshim` domain through `cfprefsd` — the same
plist the tweak and CLI read — so the two stay in sync.

The tool writes the plist (readable by `mobile`) and posts
`xyz.regulad.geoshim/prefsChanged`. `locationd` re-reads it live via a Darwin-notification
observer — no respring. `geoshim route` stages the GPX under
`jbroot(/var/mobile/Library/GeoShim/)` so it is readable from the daemon. Convert routes to
GPX with <https://mapstogpx.com/>.

### Preferences

`jbroot(/var/mobile/Library/Preferences/xyz.regulad.geoshim.plist)`

| Key | Type | Default | Meaning |
|---|---|---|---|
| `Enabled` | bool | false | Master switch for spoofing (both paths) |
| `AppFallback` | bool | true | Master switch for the app-side hooks (`geoshim fallback`) |
| `EnabledBundles` | array | `[]` | Bundle IDs the app-side fallback covers (set in Settings) |
| `Latitude` / `Longitude` | real | — | Static coordinate; also the route fallback |
| `Altitude` | real | 0 | Metres. Set it — 0 m in Denver is a tell |
| `Mode` | string | `static` | `static` or `route` |
| `SourceInfoMode` | string | `nil` | `nil`, `clean`, `passthrough` |
| `JitterMetres` | real | 2.0 | Gaussian coordinate noise per update |
| `RoutePlistPath` | string | "" | Path to a `.gpx` or `.plist` route |
| `RouteLoop` | bool | true | Loop at the end of the route |
| `RouteEndBehavior` | string | from `RouteLoop` | `loop`, `reverse`, `stop` |
| `RouteSpeedMps` | real | 1.4 | Base speed; varied ±10% per tick |
| `LogRealFixes` | bool | false | Debug builds only; logs genuine fixes |

`UpdateIntervalSec` / `SynthesizeUpdates` drive the **app-side fallback's** synthetic
timer; they do nothing on the daemon path, which only rewrites fixes `locationd` already
emits. Anything unparseable — a missing plist, a bad coordinate, a route under two points —
resolves to *disabled*, not an error. The tweak fails open by construction.

---

## Verification

Use a `GEOSHIM_DEBUG=1` build and watch with `oslog | grep geoshim` (locationd is the only
process that logs `[geoshim]`) or `idevicesyslog | grep geoshim`.

1. **It loads.** `killall -9 locationd`, then expect
   `loaded in locationd (…)`, `CLLocation encodeWithCoder: hook installed`, and
   `CLVisit encodeWithCoder: hook installed (coordOffset=N …)`. A `coordOffset` ≥ 0 means
   the `CLVisit` ivar was found; `CLVisit coordinate ivar not found` means visits are left
   unspoofed on this build (report it and it's an easy fix).
2. **The blacklisted app moves.** `geoshim start -x 51.5074 -y -0.1278`, open the target
   app. Each outbound fix logs `locationd: encode <real> -> <fake>` — that line is the
   proof the daemon path is doing the work. Because the app gets no injection, its moving
   can *only* be the locationd hook.
3. **Property sanity.** Confirm accuracy/timestamp/speed vary per the fields above; a
   constant accuracy or stale timestamp means something is wrong.
4. **`sourceInformation` behaves as designed** — `--debug-log-real`, read `real fix:` with
   spoofing off; compare against [VERIFY](#open-verify-items).
5. **No regression when disabled.** `geoshim stop`, `killall -9 locationd`; behaviour must
   be identical to the tweak not being installed. The safety net — do not skip it.

`geoshim status` also reports a loaded route's parsed point count and length.

---

## Rollback

`locationd` is a daemon every process relies on; a crash in this dylib is a crash in it.
Keep this ready **before** first install.

```bash
ssh root@<device>
# `jbroot /path` on device prints the real path.
mv "$(jbroot /Library/MobileSubstrate/DynamicLibraries/GeoShim.dylib)"{,.disabled}
killall -9 locationd
```

With the dylib gone the filter matches nothing; to remove entirely, `apt remove
xyz.regulad.geoshim`. A crash-looping `locationd` leaves the device usable (location just
stops) and SSH working — which is why the daemon target is survivable. The filter targets
**only** `locationd`; do not add UI-critical processes.

---

## Open VERIFY items

Confirmed on-device (iOS 15.8.2 / Dopamine2‑roothide), previously the biggest unknowns:

- **Daemon injection works on iOS 15.** `loaded in locationd` fires; `locationd` inherits
  systemhook injection and is not excluded.
- **`locationd` delivers via `encodeWithCoder:`.** `locationd: encode <real> -> <fake>`
  logs on each fix and clients move. The bplist17/NSSecureCoding assumption held.
- **`locationd` can read the jbroot prefs.** The daemon reads and spoofs after
  `geoshim start`, so its sandbox reaches the plist.

Still open / device-specific:

- **`CLVisit` ivar layout.** The coordinate ivar offset is discovered at load and logged
  (`coordOffset=…`). If it ever reads `not found`, the class layout differs and the
  rewrite needs the ivar name adjusted; until then visits fail closed (real coordinate).
- **`sourceInformation` of a genuine fix on 15.8.2.** Run the `--debug-log-real` probe; if
  real fixes report a non-nil object with both flags `NO`, switch from `nil` to
  `--source-info clean`. In the daemon path, `clean`/`passthrough` only carry through the
  private initializer (strategy 1); the subclass fallback encodes nil sourceInformation —
  coordinate/altitude/speed/course/timestamp always carry.
- **`Depends: ellekit`.** Confirm with `dpkg -l | grep -iE "ellekit|substrate"`; edit
  `control` if your bootstrap names it differently.

---

## Troubleshooting

**`dyld: Library not loaded: @loader_path/.jbroot/usr/lib/…`** — the `.jbroot` symlink for
the binary's directory is wrong (often `-> //`). Reinstall through Sileo/`apt`, which
recreates it. If the CLI specifically fails, it also needs the `no-sandbox` entitlement
(see Building) — without it the sandbox denies dyld the jbroot path even when the file
exists.

**`loaded in locationd` never appears** — injection isn't reaching the daemon. Confirm
Tweak Injection is on and you're not in safe mode; on Dopamine2‑roothide no `resignList`
step is needed.

**`config: no readable plist`** — `locationd` cannot read the plist. Confirm it exists and
is `mobile`-readable (`geoshim` sets 0644, chowns 501:501 when run as root). If `geoshim`
itself wrote it to the wrong place, it is missing the `no-sandbox` entitlement.

**App does not move but `locationd: encode …` logs** — locationd isn't delivering that
app's fixes via `encodeWithCoder:`; class-dump `locationd` for the actual delivery selector
(around `CLDaemon` / `CLXPCConnection`).

**Route behaves as static** — the route failed to load and degraded to the static
coordinate. `geoshim status`; a point count under 2 means no `trkpt`/`rtept`/`wpt` were
parsed.

---

## Known limits

GeoShim owns the **CLLocation / CLVisit delivery path** out of locationd — which is what
the vast majority of apps use, and what `sourceInformation` checks read. It does **not**
touch any location signal an app gathers outside CoreLocation.

### The channels that still reveal the real location

For this deployment (a **Wi-Fi-only iPad**, so anything cellular is not applicable):

- **Connected Wi-Fi BSSID — primary.** `CNCopyCurrentNetworkInfo` /
  `NEHotspotNetwork.fetchCurrent` return the SSID/BSSID of the **currently connected** AP
  (not a scan — just the joined one), given the "Access WiFi Information" entitlement plus
  location permission. That BSSID maps to a real location through any Wi-Fi positioning DB
  and contradicts the spoof. locationd does **not** expose nearby-BSSID scans to apps, so
  the scan list is closed — but the connected AP is readable and out of our reach.
- **CoreBluetooth — primary.** `CBCentralManager` scanning runs outside locationd. iOS
  randomizes peripheral MACs, weakening generic fingerprinting, but **fixed-UUID iBeacons**
  in a known venue are a strong location signal. (iBeacon *ranging* via `CLLocationManager`
  goes through locationd and *is* covered; raw `CBCentralManager` scanning is not.)
- **IP geolocation (server-side).** A backend geolocates the public IP. Coarse
  (city/region), and it reveals a *mismatch* rather than a pinpoint — closed by egressing
  at the spoofed location (a VPN **upstream of the device**, e.g. on a router, so the iPad
  shows no `utun` interface for an app to detect).
- **Cellular — not applicable** on this Wi-Fi-only iPad.
- **Sensor disagreement.** `CMMotionActivity` reports stationary while a route advances;
  `CMAltimeter` and `NSTimeZone.localTimeZone` still describe the real environment.

### Within locationd but not covered

- **Region monitoring / `requestStateForRegion:`.** locationd computes region state from
  the **real** position and returns an *enum*, not a coordinate — so the encode-time hook
  can't touch it, and an app could binary-search its true position with a grid of regions.
  It requires **"Always"** authorization, so setting the app to **"While Using"** in
  Settings closes it (and visits, and significant-location-change) with no code. Covering
  it in-tweak means a deeper hook of locationd's region evaluation (private, class-dump
  needed).
- **`CLBeacon` ranging** — only leaks if the app ranges iBeacons; no coordinate to rewrite.

### Other properties worth knowing

- **Not defeated: injected-image detection** in locationd (`_dyld_get_image_name` lists
  `GeoShim.dylib`). Not reachable by a third-party app, but stated for completeness.
- **Class identity** in `clean`/`passthrough` with the subclass fallback: a delivered
  location's class is `GSLocation`, not `CLLocation`; `isKindOfClass:` passes, an exact
  comparison does not. The default `nil` mode returns a genuine `CLLocation`.
- **System-wide by design on the daemon path.** `locationd` spoofs every client at once;
  there is no per-app control there — and the roothide-blacklisted target is reachable
  *only* by the daemon. The **app-side fallback** does add per-app control (the AltList
  picker), but only for apps that permit injection, so it can never scope the target.
- **`encodeWithCoder:` is broad within locationd.** Every valid-coordinate outbound fix is
  rewritten, including ones locationd archives for itself — so Settings → Privacy →
  Location → System Services → Significant Locations accumulates spoofed entries while on.

**Bottom line for this iPad:** the realistic ways an app still learns the true location
are the **connected Wi-Fi BSSID** and **CoreBluetooth (iBeacons)** — both above
CoreLocation, closed by moving the VPN upstream and (for BSSID) by the app not holding the
Wi-Fi entitlement. The failure mode for this kind of tool is a user who believes it is
stronger than it is.

---

## Credit

`locsim` (<https://github.com/udevsharold/locsim>, GPLv3) is worth reading for its
coordinate and GPX plumbing, even though its delivery mechanism — `CLSimulationManager`,
gated by `com.apple.locationd.simulation` — is precisely the one this project avoids.

---

## License

[AGPLv3](LICENSE). The bundled [AltList](https://github.com/opa334/AltList) and
[libSandy](https://github.com/roothide/libSandy) are separate works under their own
licenses.
