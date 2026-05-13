# auto-wifi — Phase 1 build targets
#
# `make app` is the everyday target: it produces a launchable .app bundle in dist/.
# `make release` produces a notarized DMG (requires Developer ID + notarytool profile).

.PHONY: build test app run release sign notarize dmg distribute clean help

help:
	@echo "Common targets:"
	@echo "  make build      — swift build (debug)"
	@echo "  make test       — run Swift Testing suites"
	@echo "  make app        — build and assemble a launchable .app in dist/"
	@echo "  make run        — make app, then open it"
	@echo "  make distribute — make app, then zip into dist/auto-wifi.zip for sharing"
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
	swift run AlgorithmsRunner

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

distribute: app
	@echo "▸ Packaging for distribution…"
	@rm -f dist/auto-wifi.zip
	@cd dist && ditto -c -k --keepParent auto-wifi.app auto-wifi.zip
	@./Scripts/make-dmg.sh
	@echo
	@echo "✓ dist/auto-wifi.dmg ($$(du -sh dist/auto-wifi.dmg | cut -f1)) — drag-to-Applications install, standard Mac flow"
	@echo "✓ dist/auto-wifi.zip ($$(du -sh dist/auto-wifi.zip | cut -f1)) — for AirDrop / direct send"
	@echo "  Tell recipients to read README.md for first-launch steps (right-click→Open, manual Location grant)."

release: app-release sign notarize dmg
	@echo
	@echo "✓ Release pipeline complete. Distributable: dist/auto-wifi.dmg"

clean:
	rm -rf .build dist
