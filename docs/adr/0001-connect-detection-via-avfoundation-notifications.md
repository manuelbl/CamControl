# Drive the camera list from AVFoundation notifications

The camera list (the cameras the user can pick and preview) is enumerated with
`AVCaptureDevice.DiscoverySession` and refreshed on AVFoundation's `wasConnectedNotification` /
`wasDisconnectedNotification`. These fire process-wide, without an active `AVCaptureSession`, and
while the app is in the background. Control access and reapply follow the USB registry instead
(ADR-0004).

## Status

accepted

## Considered Options

- **USB registry connect/disconnect (rejected for the list).** `USBRegistry` reports a camera at
  the moment its device is ready for control transfers, but it only sees USB devices. It has no
  localized name, no session identity for the preview, and no built-in or Continuity cameras,
  which the spec requires to be listed as previewable but not controllable.
- **AVFoundation notifications (chosen).** They report exactly the cameras AVFoundation can
  preview, with their localized names and session identities (`uniqueID`).

## Consequences

- Two event sources announce the same physical camera: AVFoundation for the list, the USB
  registry for control. Either can fire first. The list also republishes when `USBCameraService`
  availability changes, so a camera that AVFoundation announces first is shown as uncontrollable
  and becomes controllable as soon as its USB device is enumerated.
- `Camera.isControllable` comes from matching the AVFoundation session identity to a USB device
  by `CameraKey`.
- The USB registry's connect callbacks look like the obvious single event source. This ADR exists
  so the next reader doesn't remove the AVFoundation notifications in favour of them.
