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
	-lz -lcompression -licucore

.PHONY: all test wpt core install uninstall clean

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

test: build/components.test build/url.test build/color.test build/font.test \
		build/script/script.test
	node --test test/*.test.cjs
	build/components.test
	build/url.test test
	build/color.test
	build/font.test
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

build/color.test: test/color.test.m src/SGCSSColor.m src/SGCSSColor.h
	mkdir -p build
	clang -fobjc-arc -fmodules -mmacosx-version-min=12.0 -Wall \
		test/color.test.m src/SGCSSColor.m -o $@

build/font.test: test/font.test.m src/SGCSSFont.m src/SGCSSFont.h
	mkdir -p build
	clang -fobjc-arc -fmodules -mmacosx-version-min=12.0 -Wall \
		test/font.test.m src/SGCSSFont.m -o $@

# Runs from build/script, next to the sources each realm loads, as the
# plugin's bundle has them:
build/script/script.test: test/script.test.m $(SOURCES) $(wildcard src/*.h) \
		js/glyphs.js vendor/paper-hosted.js vendor/scriptographer.js
	mkdir -p build/script
	cp js/glyphs.js vendor/paper-hosted.js vendor/scriptographer.js build/script/
	clang -fobjc-arc -fmodules -mmacosx-version-min=12.0 -Wall -F "$(GLYPHS)" \
		-Wl,-rpath,"$(GLYPHS)" $(FRAMEWORKS) test/script.test.m \
		$(filter-out src/SGScriptTool.m src/SGWindowController.m,$(SOURCES)) -o $@

# WPT's OffscreenCanvas tests, from VectorCraft's corpus, against the
# failures VectorCraft expects (a copy of its tests/wpt-expected-failures.txt):
VECTORCRAFT = ../scriptographer-vectorcraft
wpt: build/script/wpt
	HOME="$(CURDIR)/build/home" build/script/wpt $(VECTORCRAFT)/corpus/wpt \
		"$(FILTER)" test/wpt/vectorcraft-expected-failures.txt

build/script/wpt: test/wpt.m build/script/script.test
	clang -fobjc-arc -fmodules -mmacosx-version-min=12.0 -Wall -F "$(GLYPHS)" \
		-Wl,-rpath,"$(GLYPHS)" $(FRAMEWORKS) test/wpt.m \
		$(filter-out src/SGScriptTool.m src/SGWindowController.m,$(SOURCES)) -o $@

# Scriptographer's bundle and Paper.js, from scriptographer-core, which
# VectorCraft shares:
CORE = ../scriptographer-core
core:
	cp $(CORE)/dist/scriptographer.js $(CORE)/vendor/paper-hosted.js vendor/

install: $(BUNDLE)
	mkdir -p "$(PLUGINS)"
	ln -sfn "$(CURDIR)/$(BUNDLE)" "$(PLUGINS)/Scriptographer.glyphsTool"

uninstall:
	rm -f "$(PLUGINS)/Scriptographer.glyphsTool"

clean:
	rm -rf build
