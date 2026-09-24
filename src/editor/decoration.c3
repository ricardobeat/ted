module ted::editor;

import glaze;
import std::collections::list;

// Decorations are everything drawn on the text that is not the text: syntax
// colors, search matches, diagnostics, inline hints. Each belongs to a named
// layer, so whoever owns one (the highlighter, a linter) replaces its own
// without touching the others, and the view draws them all without knowing
// where they came from.
//
// A decoration is anchored to buffer bytes, not to screen cells, so it
// survives scrolling, wrapping and resizing; layers carry their decorations
// through edits the way selections are carried.

enum DecorationKind : char {
	// Restyles the text in [start, end).
	STYLE,
	// Draws `text` before the byte at start, taking columns without being
	// part of the buffer: a type hint, a parameter name, ghost text.
	INLINE,
}

struct Decoration {
	DecorationKind kind;
	sz start;
	sz end;
	glaze::Style style;
	// An INLINE decoration's text, as a range of its layer's texts.
	sz text_at;
	sz text_len;
}

struct Layer {
	String name;
	// Layers draw in order; a later layer's style goes over an earlier one's.
	int order;
	// Kept sorted by start, so the view can walk them alongside the text.
	List{Decoration} items;
	// Owned copies of INLINE texts, freed with the layer.
	DString texts;
}

fn void Layer.init(&self, String name, int order) {
	self.name = name;
	self.order = order;
	self.items.init(mem);
	self.texts.init(mem);
}

fn void Layer.free(&self) {
	self.items.free();
	self.texts.free();
}

fn void Layer.clear(&self) {
	self.items.clear();
	self.texts.clear();
}

// style colors the bytes [start, end). A layer's styles must not overlap:
// the view finds the one covering a byte by looking only at the last to
// start before it.
fn void Layer.style(&self, sz start, sz end, glaze::Style style) {
	if (end <= start) return;
	self.add({ .kind = STYLE, .start = start, .end = end, .style = style });
}

// inline_text draws text before the byte at pos.
fn void Layer.inline_text(&self, sz pos, String text, glaze::Style style) {
	sz at = self.texts.len();
	self.texts.append(text);
	self.add({ .kind = INLINE, .start = pos, .end = pos, .style = style,
		.text_at = at, .text_len = text.len });
}

fn String Layer.text_of(&self, Decoration* d) => self.texts.str_view()[d.text_at:d.text_len];

// add keeps items sorted by start. Adding in order, as a highlighter does,
// appends; anything else goes where it belongs.
fn void Layer.add(&self, Decoration d) {
	sz i = self.items.len();
	while (i > 0 && self.items[i - 1].start > d.start) i--;
	self.items.insert_at(i, d);
}

// map carries the layer's decorations through an edit. One that the edit
// removed entirely is dropped.
fn void Layer.map(&self, Edit e) {
	sz kept = 0;
	for (sz i = 0; i < self.items.len(); i++) {
		Decoration d = self.items[i];
		bool swallowed = d.start >= e.at && d.end <= e.at + e.removed && e.removed > 0
			&& d.kind == STYLE;
		if (swallowed) continue;
		d.start = e.map(d.start, true);
		d.end = d.kind == INLINE ? d.start : e.map(d.end);
		self.items[kept++] = d;
	}
	while (self.items.len() > kept) self.items.remove_last()!!;
}
