APP_NAME = PowerMate
DIST = dist/$(APP_NAME).app
VERSION := $(shell /usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Support/Info.plist)
DMG = dist/$(APP_NAME)-$(VERSION).dmg

# Developer ID signing: auto-detected from the keychain. Empty means
# ad-hoc (set SIGN_ID= explicitly to force an unsigned build).
SIGN_ID ?= $(shell security find-identity -v -p codesigning 2>/dev/null \
	| awk -F'"' '/Developer ID Application/ {print $$2; exit}')

# Notarization credentials: a notarytool keychain profile by default
# (one-time setup: xcrun notarytool store-credentials perimtr-notary
# --key AuthKey_XXXX.p8 --key-id XXXX --issuer <issuer-uuid>).
# CI overrides with --key/--key-id/--issuer arguments instead.
NOTARY_ARGS ?= --keychain-profile perimtr-notary

.PHONY: build app run install dmg dmg-only notarize-app notarize-dmg release clean

build:
	swift build -c release

app: build
	rm -rf $(DIST)
	mkdir -p $(DIST)/Contents/MacOS $(DIST)/Contents/Resources
	cp .build/release/$(APP_NAME) $(DIST)/Contents/MacOS/$(APP_NAME)
	cp Support/Info.plist $(DIST)/Contents/Info.plist
	cp Support/AppIcon.icns $(DIST)/Contents/Resources/AppIcon.icns
ifneq ($(SIGN_ID),)
	codesign --force --options runtime --timestamp \
		--entitlements Support/PowerMate.entitlements \
		--sign "$(SIGN_ID)" $(DIST)
	@echo "Built $(DIST) (Developer ID, hardened runtime)"
else
	codesign --force --entitlements Support/PowerMate.entitlements --sign - $(DIST)
	@echo "Built $(DIST) (ad-hoc)"
endif

run: app
	open $(DIST)

install: app
	@pkill -x $(APP_NAME) 2>/dev/null || true
	rm -rf /Applications/$(APP_NAME).app
	cp -R $(DIST) /Applications/
	touch /Applications/$(APP_NAME).app
	@echo "Installed /Applications/$(APP_NAME).app - launch it from Spotlight."

# The custom-icon flag has to be set on the mounted volume itself:
# hdiutil -srcfolder does not carry the staging folder's Finder flags
# onto the volume root, so build writable, flag, then compress.
# dmg-only exists so the release flow can package an already-stapled
# app without a rebuild wiping the staple.
dmg: app dmg-only

dmg-only:
	rm -rf dist/dmg-staging dist/dmg-rw.dmg dist/dmg-mount $(DMG)
	mkdir -p dist/dmg-staging
	cp -R $(DIST) dist/dmg-staging/
	ln -s /Applications dist/dmg-staging/Applications
	cp Support/AppIcon.icns dist/dmg-staging/.VolumeIcon.icns
	hdiutil create -volname $(APP_NAME) -srcfolder dist/dmg-staging \
		-ov -format UDRW dist/dmg-rw.dmg
	hdiutil attach dist/dmg-rw.dmg -nobrowse -mountpoint dist/dmg-mount
	SetFile -a C dist/dmg-mount
	hdiutil detach dist/dmg-mount
	hdiutil convert dist/dmg-rw.dmg -format UDZO -o $(DMG)
	rm -rf dist/dmg-staging dist/dmg-rw.dmg dist/dmg-mount
	@echo "Built $(DMG)"

notarize-app:
	ditto -c -k --keepParent $(DIST) dist/$(APP_NAME)-notarize.zip
	xcrun notarytool submit dist/$(APP_NAME)-notarize.zip $(NOTARY_ARGS) --wait
	xcrun stapler staple $(DIST)
	rm -f dist/$(APP_NAME)-notarize.zip

notarize-dmg:
	codesign --force --timestamp --sign "$(SIGN_ID)" $(DMG)
	xcrun notarytool submit $(DMG) $(NOTARY_ARGS) --wait
	xcrun stapler staple $(DMG)

# Full distribution artifact: signed app, notarized and stapled, inside
# a signed, notarized and stapled disk image.
release:
	$(MAKE) app
	$(MAKE) notarize-app
	$(MAKE) dmg-only
	$(MAKE) notarize-dmg
	@echo "Release artifact: $(DMG) (signed, notarized, stapled)"

clean:
	rm -rf .build dist
