# Builds Scriptographer.glyphsTool for Glyphs 4, and links it into Glyphs'
# plugins folder with `make install`.

GLYPHS = /Applications/Glyphs 4.app/Contents/Frameworks
PLUGINS = $(HOME)/Library/Application Support/Glyphs 4/Plugins
BUNDLE = build/Scriptographer.glyphsTool
SOURCES = $(wildcard src/*.m)
FLAGS = -fobjc-arc -fmodules -mmacosx-version-min=12.0 -arch arm64 -arch x86_64 \
	-Wall -Wno-unknown-pragmas -F "$(GLYPHS)"
FRAMEWORKS = -framework Cocoa -framework JavaScriptCore \
	-framework GlyphsCore -framework GlyphsApp -framework GlyphsKit \
	-lz -lcompression

.PHONY: all test install uninstall clean

all: $(BUNDLE)

$(BUNDLE): $(SOURCES) $(wildcard src/*.h) js/glyphs.js vendor/paper-hosted.js \
		vendor/scriptographer.js resources/Info.plist $(shell find examples -type f | sed 's/ /\\ /g')
	rm -rf $(BUNDLE)
	mkdir -p $(BUNDLE)/Contents/MacOS $(BUNDLE)/Contents/Resources
	clang $(FLAGS) -bundle $(FRAMEWORKS) $(SOURCES) \
		-o $(BUNDLE)/Contents/MacOS/Scriptographer
	cp resources/Info.plist $(BUNDLE)/Contents/
	cp js/glyphs.js vendor/paper-hosted.js \
		vendor/scriptographer.js $(BUNDLE)/Contents/Resources/
	cp -R examples $(BUNDLE)/Contents/Resources/Examples

test: build/components.test build/url.test build/script/script.test
	node --test test/*.test.cjs
	build/components.test
	build/url.test test
	HOME="$(CURDIR)/build/home" build/script/script.test

build/components.test: test/components.test.m src/SGComponentsView.m \
		src/SGComponentsView.h
	mkdir -p build
	clang -fobjc-arc -fmodules -mmacosx-version-min=12.0 -Wall -framework Cocoa \
		test/components.test.m src/SGComponentsView.m -o $@

build/url.test: test/url.test.m src/SGURLParser.m src/SGURLParser.h
	mkdir -p build
	clang -fobjc-arc -fmodules -mmacosx-version-min=12.0 -Wall \
		test/url.test.m src/SGURLParser.m -o $@

# Runs from build/script, next to the sources each realm loads, as the
# plugin's bundle has them:
build/script/script.test: test/script.test.m $(SOURCES) $(wildcard src/*.h) \
		js/glyphs.js vendor/paper-hosted.js vendor/scriptographer.js
	mkdir -p build/script
	cp js/glyphs.js vendor/paper-hosted.js vendor/scriptographer.js build/script/
	clang -fobjc-arc -fmodules -mmacosx-version-min=12.0 -Wall -F "$(GLYPHS)" \
		-Wl,-rpath,"$(GLYPHS)" $(FRAMEWORKS) test/script.test.m \
		$(filter-out src/SGScriptTool.m src/SGWindowController.m,$(SOURCES)) -o $@

install: $(BUNDLE)
	mkdir -p "$(PLUGINS)"
	ln -sfn "$(CURDIR)/$(BUNDLE)" "$(PLUGINS)/Scriptographer.glyphsTool"

uninstall:
	rm -f "$(PLUGINS)/Scriptographer.glyphsTool"

clean:
	rm -rf build
