# macOS app for controlling a webcam

The purpose of the app is that user's can set brightness, contrast, backlight compensation, white balance etc. Users should be able to save settings. These settings are automatically applied when the same camera is plugged in the next time.

The app should strictly adhere to native macOS design. It will be a native application built with SwiftUI.

The following features should be available:

- A preview area showing the live camera feed with the current settings applied.
- A selection of the camera as multiple ones might be connected.
- Saving of the current camera settings so they are reapplied when the camera is connected again.
- A way to enable/disable if the settings are reapplied.
- A way to reset the settings to the camera's built-in default settings.

For the individual camera settings, text fields or fields to enter a number should be avoid. Instead, UI controls that are easier to modify and test the effect in the preview (such as sliders) should be preferred.

Typical camera settings include:

- Brightness (percentage between 0% and 100%)
- Contrast (percentage between 0% and 100%)
- Saturation (percentage between 0% and 100%)
- Sharpness (percentage between 0% and 100%)
- Anti-flickering (disabled, 50Hz, 60Hz)
- Backlight compensation (on, off)
- White balance (automatic, or value between 0 and 100)
- Zoom (50% to 200%)
- Pan (-40 degree to +40 degree)
- Tilt (-40 degree to +40 degree)

The actual value range can vary from camera to camera. The camera can be queried about what settings it supports and what the range of each setting is. The currently set value should be displayed as a number (in addition to the slider or whatever UI control is used).

The app will only support USB camera. Other cameras such as the builtin camera of Mac Book should also be available and display the live feed. However, their settings can't be adjusted and the user is informed that the camera is not supported.

The app should be a utility app with a single window.

The layout follows native macOS "System Settings" style: a 560px-wide single window with a live
preview (sized to the camera's aspect ratio, 16:9 when unknown, never cropped), a camera picker row, a scrollable region showing only the supported grouped control
sections (EXPOSURE & COLOR / IMAGE / FRAMING) — or a centered native empty-state view when the
camera exposes no controls — and a footer with a per-camera "Reapply on connect" toggle and Reset to
Defaults.

The code for communicating with USB cameras lives in `CamControl/UVC` (pure Swift: USB registry, device access and UVC control transfers).

## Design decisions

**Control values, ranges and display units**
- Sliders operate directly in each control's **native hardware range** — slider min/max/step come
  from the UVC `GET_MIN` / `GET_MAX` / `GET_RES` requests, and `GET_DEF` marks the reset point
  (boolean controls use a synthesized 0/1 range). The value written to hardware is always the exact native integer (no round-tripping
  through a normalized scale).
- The **numeric read-out** shown next to each slider is the native value converted to a friendly
  unit for display only:
  - Brightness, Contrast, Saturation, Sharpness, Zoom → **percentage** = (value − min)/(max − min)×100
  - White balance temperature → **Kelvin** (the native value directly)
  - Pan, Tilt → **degrees** = value / 3600 (native arc-second units)
- Read-outs appear **only on sliders**. Toggles and segmented controls are self-describing; no
  separate number.

**Control → UI widget mapping**
- Sliders (native range, with read-out): Brightness (PU), Contrast (PU), Saturation (PU),
  Sharpness (PU), White balance temperature (PU), Zoom (CT `ZoomAbsolute`), Pan + Tilt
  (both halves of CT `PanTiltAbsolute`).
- Toggle: Backlight compensation (PU) — **off = control minimum, on = control maximum** (robust to
  ranges wider than 0/1).
- Segmented: Anti-flicker (PU `PowerLineFrequency`) — **0 = Off, 1 = 50 Hz, 2 = 60 Hz**; add an
  **Auto** segment only if the camera reports a max ≥ 3.
- White balance: an **Auto toggle** (PU `WhiteBalanceTemperatureAuto`) plus the temperature slider.
  Auto on → slider **disabled, frozen** at the last-read value (not polled). Auto off → slider
  enabled, initialized from the current read-back. The WB row renders whenever the temperature
  control exists: both controls → Auto checkbox + slider; temperature only → bare slider. Auto
  only or neither → the row is hidden (a lone Auto checkbox controls nothing observable).

**Interaction model**
- Slider/toggle changes apply to the camera hardware **immediately** — the live preview reflects
  changes in real time. While "Reapply on connect" is on, the settled values are also autosaved
  to disk for future reconnects (there is no Save button).
- **Only supported controls are shown.** A control the camera doesn't support (per the control
  bitmaps in its UVC descriptors, `hasPUControl` / `hasCTControl`) is **hidden** — not shown
  disabled. There is no "—" read-out. A group section (EXPOSURE & COLOR · IMAGE · FRAMING) with
  zero supported controls is hidden entirely (header and card). The preview (top) and footer
  (bottom) stay pinned; the camera picker and control sections between them form one grouped
  `Form` that scrolls when it doesn't fit. The empty-state view is centered over that region,
  below the picker.
- **"Disabled but visible" survives only for an intra-control dependency:** the White balance
  temperature slider is shown disabled/frozen while WB Auto is on.
- Slider drags are written at a manageable cadence: while a write is in flight, only the **latest
  pending value** per control is kept and written next; stale intermediates are dropped (the final
  resting value is always written). Preview tracks the thumb without a backlog.
- All UVC reads/writes flow through `USBCameraService`, an actor whose executor is a **single
  serial queue** (the IOKit control transfers block and must not run concurrently); the
  background reapply-on-connect handler uses the same service.
- "Reset to Defaults" (currently selected camera only) resets the live hardware to the camera's
  built-in defaults (`resetPUControl` / `resetCTControl`: read `GET_DEF`, write it as `SET_CUR`)
  and the sliders snap to the values read back afterwards. If "Reapply on connect" is on, it stays on and the defaults replace the saved
  snapshot. It shows a **confirmation alert** first (it can overwrite persisted data).

**Persistence (autosave while Reapply is on — see ADR-0005)**
- A camera's **profile** = `{ control-values snapshot, reapplyOnConnect flag }`. A profile exists
  **exactly while Reapply-on-connect is on** for that camera.
- The snapshot is a **full snapshot** of every currently-supported control's current value, not a
  sparse delta of only user-touched controls. For White balance it holds both the Auto flag and
  the temperature.
- Turning Reapply **on** creates the profile from the current values. Turning it **off** deletes
  the profile.
- While Reapply is on, the snapshot is **autosaved** after every edit, once interaction settles
  (the 500ms settle read-back, so it stores the camera's actual values), and after Reset.
  An edit still waiting for its settle is saved with its in-memory values when the selection
  changes or the app quits.
- "Reapply on connect" is a **per-camera** flag stored in that camera's profile — not a global
  switch. On reapply, White balance is written in dependency order: Auto flag first, then (if Auto
  is off) the temperature. Saved values are written as stored; controls the connected camera
  doesn't support are skipped.
- One JSON file (`profiles.json`, with a schema version) in
  `~/Library/Application Support/CamControl/`, keyed by `USBDevice.persistenceKey`
  (= `vendor-product-serial`, stable across USB ports and reboots).
  - **Known collision:** identical cameras with an empty/duplicate serial number share one key —
    accepted as a known limitation (same model → same preferences); reapply then applies to
    whichever identical camera is connected.

**Camera selection, connect detection and empty states**
- Camera identity has two forms: the **persistence identity** `USBDevice.persistenceKey`
  (`vendor-product-serial`, port-independent) and the AVFoundation **session identity**
  `AVCaptureDevice.uniqueID` (`location-vendor-product`, port-dependent, used for the preview and,
  parsed into a `CameraKey`, to address the camera's USB device).
- **Connect detection** has two sources, by design (ADR-0004). The camera *list* comes from
  AVFoundation `AVCaptureDeviceWasConnected` / `...WasDisconnected` notifications
  (session-independent, fire while backgrounded); *reapply* and all USB access come from the USB
  registry via `USBCameraService`, which reports a camera only once its device is enumerated. A
  camera AVFoundation announces first shows as uncontrollable and flips as soon as its USB device
  appears — the list republishes on that event.
- On launch, select the **first controllable camera**; if none are controllable but a
  camera exists (e.g. only the built-in), select the first available so its preview + empty state show;
  empty state only when zero cameras.
- When the selected camera is unplugged, **auto-select the next available**; if none, empty state.
- When a **controllable** camera is plugged in, it is **auto-selected**, replacing the current
  selection — the physical plug-in is the intent signal. This holds whether the main window is
  visible or closed: camera tracking starts at app launch, so reopening the window shows the most
  recently plugged controllable camera, its controls already discovered in the background (the
  preview stays off while the window is closed). If several controllable cameras appear in one
  connect event, the first in enumeration order wins. Non-controllable arrivals (e.g. Continuity
  Camera coming into range) never steal the selection. If the Reset-to-Defaults confirmation alert is open when the steal happens, it is
  dismissed so a confirmed reset can't target a different camera than the one named.
- **Empty state:** preview placeholder ("No Camera Connected"), picker empty/disabled, no control
  sections. Background reapply still fires when a camera later appears.
- **Unsupported camera** (no attached UVC device behind it, e.g. MacBook built-in): show the live
  preview and, **in place of** the control sections, a centered native **empty-state view**
  (`ContentUnavailableView`) — title "No Adjustable Settings", icon `slider.horizontal.3`,
  description "This camera's settings can't be adjusted by CamControl." Footer disabled. It is
  neutral (a native empty state, not an alarming banner).
- **Zero-control controllable camera** (`isControllable` true but no supported controls): the
  **same** empty-state view and the **same title** ("No Adjustable Settings"), differing only in a
  one-line description ("This camera doesn't expose any settings that CamControl can adjust").
  Footer disabled (nothing to reapply or reset). This case is keyed off "zero supported controls,"
  separate from the `isControllable` check that drives the unsupported case — only the descriptions
  differ.

**Error handling**
- **Best-effort, silent I/O**, no modal error alerts. Failed UVC transfers are logged and
  swallowed (a failed read yields 0), so UI correctness comes from connect/disconnect state, not
  from transfer results: a mid-adjustment unplug is handled by the disconnect notification; a
  background reapply runs once per attach and logs failed writes; a camera whose USB device can't
  be opened shows no controls (the zero-control empty state). Profile-file I/O errors are logged;
  a missing or unreadable file reads as "no profiles".

**Preview & permissions**
- The live preview runs an `AVCaptureSession` only while the window is open, for the selected
  camera; closing the window (→ accessory) stops it; reopening restarts it; switching cameras swaps
  the input.
- Camera access (TCC) is requested on first preview. **If denied, the preview shows a placeholder
  with a link to Privacy & Security settings, but the controls still work** — UVC control writes go
  over USB (`device.usb` entitlement), independent of camera-access permission.
- If access is **restricted** (MDM or parental controls), the placeholder says so without a link —
  the user can't change it.

**Lifecycle / background behavior**
- Settings must reapply on camera connect even when the app isn't in the foreground, so the app
  keeps running after its window is closed (menu bar accessory) rather than quitting.
- Dock presence toggles dynamically: regular app (Dock icon, normal window) while the window is
  open; accessory (menu bar only, no Dock icon) once it's closed.
- Menu bar icon shows a dropdown: Open CamControl, About CamControl, Settings…, Quit CamControl.
- "Launch at Login" (via `SMAppService`) is off by default; the user opts in via a toggle in a
  standard Settings scene (Cmd+,), per Apple HIG guidance against silently adding login items.
  If the login item awaits the user's approval, the toggle stays on and a row below it explains
  this, with a button that opens System Settings › Login Items.
- Background reapply is pure UVC control writes over USB (via `USBCameraService`) — it does not
  require an active `AVCaptureSession`/live video stream, so it stays lightweight while backgrounded.
- Quitting the app (from the menu bar) stops background monitoring until the next login or manual
  relaunch; the login item itself stays registered.

**Platform / scope**
- Minimum deployment target: macOS 15 Sequoia.
- Single window, System Settings style, with a **fixed width of 560pt**. The height is
  user-resizable (minimum 580pt); the first launch opens at 760pt, clamped to the screen, and the
  frame is remembered across launches. The window doesn't resize when switching cameras; the
  control region scrolls when it doesn't fit (preview + footer stay pinned).
- App Sandbox with `com.apple.security.device.usb` and `com.apple.security.device.camera`
  entitlements — raw USB control access alongside AVFoundation video capture.

**Pan/Tilt on the wire**
- UVC represents Pan/Tilt as a single combined control (CT `PanTiltAbsolute`, an SInt32 tuple),
  while the UI shows Pan and Tilt as two independent sliders. `USBCameraService` decomposes the
  tuple on read and does a read-modify-write of the whole tuple on write, preserving the other
  axis. Resetting either one resets both axes.
