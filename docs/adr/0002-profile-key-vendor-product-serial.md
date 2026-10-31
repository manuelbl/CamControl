# Key saved profiles by vendor-product-serial, accepting identical-camera collisions

Saved profiles are keyed by `USBVideoDevice.uniqueID` (`vendor-product-serial`), which is stable
across USB ports and reboots — so "reapply when this camera reconnects" works no matter which port
it's plugged into. We knowingly accept that two identical cameras with empty or duplicate serial
numbers collide onto one profile.

## Status

accepted

## Considered Options

- **`vendor-product-serial` (chosen).** Port-independent, survives reboots — the right identity for
  "the same physical camera, wherever it's plugged in," which is the whole point of reapply-on-connect.
- **Location-based identity** (as in `AVCaptureDevice.uniqueID` = `location-vendor-product`, or a
  fallback for empty serials). Rejected: it changes with the USB port, so moving a camera to a
  different port would lose its profile — breaking the core promise.

## Consequences

- Identical cameras that report an empty or non-unique serial number (common on cheap webcams) share
  one profile. Same model → same preferences is a defensible behavior; reapply-on-connect then writes
  that shared profile to whichever identical camera is connected. Documented as a known limitation
  rather than worked around, because the hardware doesn't reliably provide a distinguishing
  identifier that is also port-independent.
