# One service owns every USB camera device; callers address cameras by key

`USBCameraService` is the single owner of every `USBDevice` the app talks to. It monitors USB
connect/disconnect itself, opens a camera's device lazily on first control access, closes it when
the camera detaches, and exposes reads/writes to callers that name a camera by `CameraKey` — the
`(locationID, vendorID, productID)` triple that AVFoundation's session identity and a USB device
agree on. No caller holds a device handle.

## Status

accepted (2026-07-27)

## Context

Ownership of a device used to be derived per caller: `AppModel` (foreground) and `ReapplyService`
(background) each resolved the selected camera to its own `UVCVideoDevice` wrapper over the *same*
`USBDevice`, and each wrapper closed that device in `deinit`. Whichever caller finished first closed
the device under the other, which then failed every request with "USB device is not open" until the
camera was replugged. Which caller finished first depended on the order the two paths happened to
pair in — sequential at app start (fine), interleaved on a replug (broken). Both wrappers were also
constructed concurrently on the cooperative pool, racing on `USBDevice.isOpen` and issuing
`SetConfiguration` twice on a camera mid-discovery.

## Considered Options

- **Ref-count `open`/`close` inside `USBDevice` (rejected).** The smallest fix for the crash, but it
  keeps per-caller wrappers, the concurrent construction, the duplicate `SetConfiguration`, and two
  independently-tuned pairing retry budgets. It makes the symptom go away without making the
  ownership rule expressible.
- **One service, cameras addressed by key (chosen).** Ownership stops being derivable by callers:
  there is exactly one open handle per physical connection, and its lifetime is the connection's,
  not any caller's.

## Consequences

- Blocking IOKit work stays on one app-wide serial queue, which is the service actor's executor.
  The availability snapshot (which cameras are attached, their names and persistence keys) sits
  behind a lock instead, so the UI can read it synchronously while building the camera list, and so
  it is published *before* observers are notified — an observer that immediately asks for controls
  always finds the camera.
- `AppModel` and `ReapplyService` hold a `CameraKey`, not a device. Dropping a selection or
  finishing a reapply cannot close anything.
- A camera's device is opened once per connection and stays open until it detaches — including
  while another app is using the camera, and including cameras that are attached but not selected.
- Connect detection for *reapply* moves from AVFoundation notifications to the USB registry: at the
  moment the service reports a camera, its device is enumerated and ready, so no pairing retry is
  needed. AVFoundation notifications still drive the camera *list* (they carry
  the localized name, the preview identity, and non-USB cameras), so both event sources remain —
  with a clear split of duties, and the list republishing on USB availability changes so a camera
  announced by AVFoundation first stops being shown as uncontrollable once its device appears.
- A replug into the same port produces the same `CameraKey` but a new USB device; the service
  compares IOKit registry entry IDs to retire the stale handle rather than talking to a device that
  is gone.
