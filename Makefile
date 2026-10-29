# Builds Scriptographer.glyphsTool for Glyphs 4, and links it into Glyphs'
# plugins folder with `make install`.

GLYPHS = /Applications/Glyphs 4.app/Contents/Frameworks
PLUGINS = $(HOME)/Library/Application Support/Glyphs 4/Plugins
BUNDLE = build/Scriptographer.glyphsTool
SOURCES = $(wildcard src/*.m)
FLAGS = -fobjc-arc -fmodules -mmacosx-version-min=12.0 -arch arm64 -arch x86_64 \
	-Wall -Wno-unknown-pragmas -F "$(GLYPHS)"
FRAMEWORKS = -framework Cocoa -framework JavaScriptCore \
	-framework GlyphsCore -framework GlyphsApp -framework GlyphsKit

.PHONY: all test install uninstall clean

all: $(BUNDLE)

$(BUNDLE): $(SOURCES) $(wildcard src/*.h) js/glyphs.js vendor/paper-hosted.js \
		resources/Info.plist $(wildcard examples/*.js)
	rm -rf $(BUNDLE)
	mkdir -p $(BUNDLE)/Contents/MacOS $(BUNDLE)/Contents/Resources/Examples
	clang $(FLAGS) -bundle $(FRAMEWORKS) $(SOURCES) \
		-o $(BUNDLE)/Contents/MacOS/Scriptographer
	cp resources/Info.plist $(BUNDLE)/Contents/
	cp resources/ToolbarIconTemplate.pdf js/glyphs.js vendor/paper-hosted.js \
		$(BUNDLE)/Contents/Resources/
	cp examples/*.js $(BUNDLE)/Contents/Resources/Examples/

test:
	node --test test/*.test.cjs

install: $(BUNDLE)
	mkdir -p "$(PLUGINS)"
	ln -sfn "$(CURDIR)/$(BUNDLE)" "$(PLUGINS)/Scriptographer.glyphsTool"

uninstall:
	rm -f "$(PLUGINS)/Scriptographer.glyphsTool"

clean:
	rm -rf build
