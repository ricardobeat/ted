module ted::editor;

import std::collections::list;

// Buffer is the text being edited, and nothing else: no cursor, no styling.
// Every change goes through replace(), which reports what it did as an Edit
// so selections, decorations and history can follow it.
//
// The text is one contiguous string, which keeps reading it (for parsing,
// saving, searching) free; an edit moves the bytes after it. A line index —
// where each line starts — is kept up to date alongside, so going from a
// line number to a byte offset and back is a lookup rather than a scan.

struct Buffer {
	DString text;
	// Byte offset where each line starts. Line 0 starts at 0; there is always
	// at least one line, even in an empty buffer.
	List{sz} line_starts;
	// Bumped by every change, so a consumer can tell whether what it derived
	// from the text (a parse, a layout) is stale.
	int version;
}

// Edit says that the bytes [at, at + removed) became [at, at + inserted).
struct Edit {
	sz at;
	sz removed;
	sz inserted;
}

fn void Buffer.init(&self) {
	self.text.init(mem);
	self.line_starts.init(mem);
	self.line_starts.push(0);
}

fn void Buffer.free(&self) {
	self.text.free();
	self.line_starts.free();
}

fn String Buffer.str(&self) => self.text.str_view();
fn sz Buffer.len(&self) => self.text.len();
fn int Buffer.line_count(&self) => (int)self.line_starts.len();

fn sz Buffer.line_start(&self, int line) {
	if (line <= 0) return 0;
	if (line >= self.line_count()) return self.len();
	return self.line_starts[line];
}

// line_end is where the line's text ends, before its newline.
fn sz Buffer.line_end(&self, int line) {
	if (line + 1 >= self.line_count()) return self.len();
	return self.line_starts[(sz)line + 1] - 1;
}

fn String Buffer.line(&self, int line) {
	sz start = self.line_start(line);
	return self.str()[start:self.line_end(line) - start];
}

// line_of is the line holding byte pos.
fn int Buffer.line_of(&self, sz pos) {
	sz lo = 0;
	sz hi = self.line_starts.len();
	while (lo + 1 < hi) {
		sz mid = (lo + hi) / 2;
		if (self.line_starts[mid] <= pos) { lo = mid; } else { hi = mid; }
	}
	return (int)lo;
}

fn void Buffer.set_text(&self, String s) {
	self.replace(0, self.len(), s);
}

// replace swaps the bytes [start, end) for `with`.
fn Edit Buffer.replace(&self, sz start, sz end, String with) {
	if (end > self.len()) end = self.len();
	if (start > end) start = end;
	Edit e = { .at = start, .removed = end - start, .inserted = with.len };

	int first = self.line_of(start);
	int last = self.line_of(end);
	if (end > start) self.text.delete(start, end - start);
	if (with.len > 0) self.text.insert_chars_at(start, with);

	// Lines wholly inside the removed range go; the inserted text brings its
	// own; everything after shifts by the change in length.
	for (int i = last; i > first; i--) self.line_starts.remove_at(i);
	sz at = (sz)first + 1;
	foreach (i, c : with) {
		if (c == '\n') self.line_starts.insert_at(at++, start + i + 1);
	}
	for (sz i = at; i < self.line_starts.len(); i++) {
		self.line_starts[i] = self.line_starts[i] - e.removed + e.inserted;
	}
	self.version++;
	return e;
}

// map carries a position through an edit: before it, it stays; inside the
// replaced range, it moves to the range's end; after it, it shifts.
fn sz Edit.map(self, sz pos, bool stick_left = false) {
	if (pos < self.at) return pos;
	if (pos == self.at && stick_left) return pos;
	if (pos <= self.at + self.removed) return self.at + self.inserted;
	return pos - self.removed + self.inserted;
}
