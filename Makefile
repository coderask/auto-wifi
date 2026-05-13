# auto-wifi — Phase 1 build targets
#
# `make app` is the everyday target: it produces a launchable .app bundle in dist/.
# `make release` produces a notarized DMG (requires Developer ID + notarytool profile).

.PHONY: build test app run release sign notarize dmg clean help

help:
	@echo "Common targets:"
	@echo "  make build      — swift build (debug)"
	@echo "  make test       — run Swift Testing suites"
	@echo "  make app        — build and assemble a launchable .app in dist/"
	@echo "  make run        — make app, then open it"
	@echo
	@echo "Release pipeline (requires DEVELOPER_ID_APPLICATION + notary profile):"
	@echo "  make sign       — re-sign dist/auto-wifi.app with Developer ID"
	@echo "  make notarize   — submit + staple ticket"
	@echo "  make dmg        — wrap the stapled .app into a DMG"
	@echo "  make release    — build → sign → notarize → dmg, end-to-end"
	@echo
	@echo "  make clean      — remove .build and dist/"

build:
	swift build

test:
	swift test

app:
	./Scripts/make-app.sh debug

app-release:
	./Scripts/make-app.sh release

run: app
	open dist/auto-wifi.app

sign:
	./Scripts/sign.sh

notarize:
	./Scripts/notarize.sh

dmg:
	./Scripts/make-dmg.sh

release: app-release sign notarize dmg
	@echo
	@echo "✓ Release pipeline complete. Distributable: dist/auto-wifi.dmg"

clean:
	rm -rf .build dist
