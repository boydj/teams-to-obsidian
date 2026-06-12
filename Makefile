APP_NAME = TeamsToObsidian
BUNDLE = dist/$(APP_NAME).app

.PHONY: build test app sign install whisper clean

build:
	swift build -c release

test:
	swift test

app: build
	./scripts/make-app.sh

sign: app
	codesign --force --sign - $(BUNDLE)

install: sign
	ditto $(BUNDLE) /Applications/$(APP_NAME).app
	@echo "Installed /Applications/$(APP_NAME).app"

whisper:
	./scripts/setup-whisper.sh

clean:
	rm -rf .build dist
