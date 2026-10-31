# Context: CamControl

A macOS utility for adjusting and persisting USB webcam image/framing settings.

## Glossary

**Camera** — A video capture device presented by AVFoundation (`AVCaptureDevice`). May or may not
be *controllable*. The MacBook built-in camera is a Camera but is not controllable.

**Controllable camera** — A Camera whose settings can be changed, i.e. it has a backing USB Video
Class (UVC) device (`+isControllable:` is true). Only controllable cameras can have a *Profile*.

**Unsupported camera** — A Camera that is *not* controllable (no backing USB device). Its live feed
is still shown, but it has no Controls; the *Empty state* view explains why, in place of the
control sections.

**USB video device** — The UVC control interface behind a controllable Camera (`UVCVideoDevice`),
used to read ranges and read/write Control values over USB. Distinct from the AVFoundation preview
path. Owned exclusively by the *USB camera service*; no other part of the app holds one.

**USB camera service** — The single owner of every USB camera device (`USBCameraService`): it
monitors USB attach/detach, opens and closes the devices, and performs all Control traffic. Callers
name a camera by *Camera key* and hold no device handle, so no caller's teardown can close a device
another one is using (ADR-0004).

**Camera key** — The port-dependent USB identity `(locationID, vendorID, productID)` (`CameraKey`),
parsed from a Camera's *Session identity*. The vocabulary the UI and the USB camera service share.
Same physical port + model ⇒ same key across a replug; the service distinguishes connections by
IOKit registry entry ID.

**Control** — One adjustable camera parameter (e.g. Brightness, Zoom, White balance). Backed by a
UVC Processing Unit (PU) or Camera Terminal (CT) control. Each Control has a native integer range
(minimum, maximum, resolution, default) that varies per camera. A Control the camera doesn't
support is **hidden**; only supported Controls render. ("Disabled but visible" survives solely for
an intra-control dependency — the White balance temperature slider frozen while WB Auto is on.)

**Empty state** — A centered native empty-state view (`ContentUnavailableView`) shown in place of
the control sections when the selected camera has nothing to adjust. Two variants share one title
("No Adjustable Settings") and icon, differing only in a one-line description: one for an
*Unsupported camera* ("can't be adjusted"), one for a controllable camera that reports zero Controls
("doesn't expose any settings"). Not an error banner.

**Native value** — A Control's value in the camera's own integer units, as read/written over USB.
The canonical value; what a *Snapshot* stores and what reapply writes.

**Display unit** — A human-friendly rendering of a native value, for read-out only: percentage
(relative to min/max), Kelvin (white balance), or degrees (pan/tilt = native/3600). Never
round-trips back to hardware.

**Profile** — The persisted per-camera record: a *Snapshot* plus the *Reapply-on-connect* flag.
Exists exactly while *Reapply-on-connect* is on; kept current by *Autosave*. Keyed by *Persistence
identity*.

**Snapshot** — A full set of every currently-supported Control's native value for one camera,
captured by *Autosave* (not a delta of only user-touched controls).

**Reapply-on-connect** — A per-camera flag (part of the Profile) that, when on, causes the camera's
Snapshot to be written to the hardware whenever that camera connects — including while the app is
backgrounded. Not a global switch. Persists immediately when toggled: on creates the Profile from
the current values; off deletes the Profile (ADR-0005).

**Persistence identity** — The port-independent camera key used for Profiles:
`USBDevice.persistenceKey` = `vendor-product-serial`. Stable across USB ports and reboots. Identical
cameras with empty/duplicate serials collide onto one key (accepted).

**Session identity** — The port-dependent AVFoundation key `AVCaptureDevice.uniqueID` =
`location-vendor-product`. Used for the live preview and to pair a Camera to its USB video device.

**Autosave** — While Reapply-on-connect is on, the current Snapshot is written to disk once
interaction settles (after the settle read-back, so it holds the camera's actual values) and after
Reset. There is no explicit Save action (ADR-0005).

**Reset to Defaults** — Write every supported Control to its built-in default. If Reapply-on-connect
is on, it stays on and the defaults are autosaved as the Snapshot. Scoped to the selected camera;
confirmed via alert.
