#!/bin/zsh
# Interactive, opt-in runtime verification. Run only after the user agrees to administrator UI.
# Never targets an existing application and never empties the Trash.
set -euo pipefail
cd "${0:A:h:h}"
FIXTURE="$HOME/Applications/WonderBox-Trash-Tests-$(uuidgen)"
mkdir -m 700 "$FIXTURE"
mkdir -m 700 "$FIXTURE/Chrome Apps.localized"
printf 'WonderBox disposable Trash fixture\n' > "$FIXTURE/fixture-marker"
cleanup() {
  # Test failures may happen after the move; still remove our known, empty fixture parents.
  if [[ ! -e "$FIXTURE/Chrome Apps.localized/测试文档.app" && ! -e "$FIXTURE/Chrome Apps.localized/Test Drive.app" ]]; then
    rm -f "$FIXTURE/Chrome Apps.localized/.DS_Store" "$FIXTURE/.DS_Store"
    rmdir "$FIXTURE/Chrome Apps.localized" 2>/dev/null || return
    rm "$FIXTURE/fixture-marker"
    rmdir "$FIXTURE"
  fi
}
trap cleanup EXIT
for name in '测试文档.app' 'Test Drive.app'; do
  app="$FIXTURE/Chrome Apps.localized/$name"
  mkdir -p "$app/Contents"
  printf 'WonderBox disposable Trash fixture\n' > "$app/Contents/fixture-data"
  /usr/libexec/PlistBuddy -c 'Add :CFBundlePackageType string APPL' "$app/Contents/Info.plist" >/dev/null
  /usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string com.wondercraft.WonderBox.TrashFixture.$(uuidgen)" "$app/Contents/Info.plist"
  chmod 755 "$app" "$app/Contents"
done
# Quote the generated pathname through AppleScript's quoted form, not string interpolation.
/usr/bin/osascript - "$FIXTURE/Chrome Apps.localized/测试文档.app" "$FIXTURE/Chrome Apps.localized/Test Drive.app" <<'APPLESCRIPT'
on run argv
    set firstPath to quoted form of item 1 of argv
    set secondPath to quoted form of item 2 of argv
    do shell script "/usr/sbin/chown -R root:staff " & firstPath & " " & secondPath with administrator privileges
end run
APPLESCRIPT
echo "Disposable fixture: $FIXTURE"
WONDERBOX_TRASH_FIXTURE="$FIXTURE" swift test --filter SystemTrashRuntimeTests
