# Releasing

How to build a signed, notarized `CamControl-<version>.dmg` for direct distribution.
Run all commands from the repository root.

## One-time setup

1. Install a **Developer ID Application** certificate (with its private key) in the login keychain.
   Check that it is available:

   ```bash
   security find-identity -v -p codesigning
   ```

2. Create an app-specific password for your Apple ID at <https://account.apple.com>
   (Sign-In and Security → App-Specific Passwords).

3. Store the notarization credentials in the keychain under the profile `notary`:

   ```bash
   xcrun notarytool store-credentials notary --apple-id <apple-id> --team-id 4H9ZA7X4C4
   ```

   The command prompts for the app-specific password.

## 1. Bump the version

Edit `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `project.yml`, then regenerate
the Xcode project and commit:

```bash
xcodegen generate
git commit -am "Version <version>"
```

## 2. Set variables

```bash
VERSION=$(sed -n 's/.*MARKETING_VERSION: "\(.*\)"/\1/p' project.yml)
IDENTITY="Developer ID Application: Manuel Bleichenbacher (4H9ZA7X4C4)"
PROFILE=notary
OUT=build/release
echo "$VERSION"
```

## 3. Clean and test

```bash
rm -rf "$OUT"
xcodebuild test -project CamControl.xcodeproj -scheme CamControlTests -destination 'platform=macOS'
```

## 4. Archive and export

`ExportOptions.plist` exports with the `developer-id` method, so the app is signed
with the Developer ID certificate, hardened runtime and a secure timestamp.

```bash
xcodebuild archive -project CamControl.xcodeproj -scheme CamControl \
    -configuration Release -archivePath "$OUT/CamControl.xcarchive"

xcodebuild -exportArchive -archivePath "$OUT/CamControl.xcarchive" \
    -exportPath "$OUT/export" -exportOptionsPlist ExportOptions.plist \
    -allowProvisioningUpdates
```

## 5. Create the DMG

The DMG contains the app and an `Applications` link for drag-to-install.

```bash
mkdir -p "$OUT/dmg"
cp -R "$OUT/export/CamControl.app" "$OUT/dmg/"
ln -s /Applications "$OUT/dmg/Applications"

hdiutil create -volname "CamControl" -srcfolder "$OUT/dmg" \
    -ov -format ULFO "$OUT/CamControl-$VERSION.dmg"
```

## 6. Sign the DMG

```bash
codesign --sign "$IDENTITY" --timestamp "$OUT/CamControl-$VERSION.dmg"
```

## 7. Notarize and staple

Notarizing the DMG also notarizes the app inside it.

```bash
xcrun notarytool submit "$OUT/CamControl-$VERSION.dmg" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$OUT/CamControl-$VERSION.dmg"
```

If the status is `Invalid`, show the reason with:

```bash
xcrun notarytool log <submission-id> --keychain-profile "$PROFILE"
```

## 8. Verify

```bash
spctl -a -vv -t open --context context:primary-signature "$OUT/CamControl-$VERSION.dmg"
xcrun stapler validate "$OUT/CamControl-$VERSION.dmg"
```

`spctl` must report `accepted` and `source=Notarized Developer ID`.

## 9. Tag

```bash
git tag "v$VERSION"
git push origin "v$VERSION"
```

## Publishing (optional)

```bash
gh release create "v$VERSION" "$OUT/CamControl-$VERSION.dmg" --title "CamControl $VERSION"
```
