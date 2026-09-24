module ted::editor;

import milktea;
import std::collections::list;
import std::core::env;

// Commands are what the editor can do — move, select, edit, undo — as plain
// functions on the view, each acting on every selection. handle_key() at the
// bottom is only a key map onto them, so a menu, a command palette or a
// different set of bindings can call the same functions.
//
// Every change to the text goes through apply(), which records it for undo
// and carries the selections and decorations through it.

// ── editing ───────────────────────────────────────────────────────────────

fn Edit View.apply(&self, Step* step, sz start, sz end, String with) {
	step.record(start, self.buf.str()[start:end - start], with);
	Edit e = self.buf.replace(start, end, with);
	foreach (&s : self.sels) *s = s.map(e);
	foreach (&l : self.layers) l.map(e);
	return e;
}

// order_desc lists the selections from last in the buffer to first, the
// order to edit them in so each edit leaves the ones still to do in place.
fn sz[] View.order_desc(&self) {
	sz[] order = mem::talloc_array(sz, self.sels.len());
	foreach (i, &o : order) *o = i;
	for (sz i = 1; i < order.len; i++) {
		for (sz j = i; j > 0 && self.sels[order[j - 1]].start() < self.sels[order[j]].start(); j--) {
			@swap(order[j - 1], order[j]);
		}
	}
	return order;
}

fn void View.after_edit(&self, Step* step) {
	step.finish(self.sels.array_view());
	self.scroll_to_caret();
}

// insert_text replaces every selection with text, as typing and pasting do.
fn void View.insert_text(&self, String text, EditKind kind = OTHER) {
	@pool() {
		Step* step = self.history.begin(kind, self.sels.array_view());
		foreach (i : self.order_desc()) {
			Selection s = self.sels[i];
			self.apply(step, s.start(), s.end(), text);
			self.sels[i] = caret(s.start() + text.len);
		}
		self.after_edit(step);
	};
}

// newline breaks the line at each selection, carrying its indentation over.
fn void View.newline(&self) {
	@pool() {
		Step* step = self.history.begin(OTHER, self.sels.array_view());
		foreach (i : self.order_desc()) {
			Selection s = self.sels[i];
			String line = self.buf.line(self.buf.line_of(s.start()));
			sz ws = 0;
			while (ws < line.len && (line[ws] == ' ' || line[ws] == '\t')) ws++;
			String with = string::tformat("\n%s", line[:ws]);
			self.apply(step, s.start(), s.end(), with);
			self.sels[i] = caret(s.start() + with.len);
		}
		self.after_edit(step);
	};
}

// delete_back removes each selection, or the character before each caret —
// or, in a line's leading indentation, back to the previous indent stop.
fn void View.delete_back(&self, bool word = false) {
	@pool() {
		Step* step = self.history.begin(DELETING, self.sels.array_view());
		foreach (i : self.order_desc()) {
			Selection s = self.sels[i];
			sz start = s.start();
			sz end = s.end();
			if (s.is_empty()) {
				sz pair = word ? 0 : self.pair_around(s.head);
				if (pair > 0) {
					// Between an empty pair: both halves go.
					start = s.head - pair;
					end = next_char(self.buf.str(), s.head);
				} else {
					start = word ? self.word_start(s.head) : self.indent_or_char_before(s.head);
				}
			}
			self.apply(step, start, end, "");
			self.sels[i] = caret(start);
		}
		self.after_edit(step);
	};
}

// delete_forward removes each selection, or the character after each caret.
fn void View.delete_forward(&self, bool word = false) {
	@pool() {
		Step* step = self.history.begin(DELETING, self.sels.array_view());
		foreach (i : self.order_desc()) {
			Selection s = self.sels[i];
			sz end = s.end();
			if (s.is_empty()) end = word ? self.word_end(s.head) : next_char(self.buf.str(), s.head);
			self.apply(step, s.start(), end, "");
			self.sels[i] = caret(s.start());
		}
		self.after_edit(step);
	};
}

fn sz View.indent_or_char_before(&self, sz pos) {
	sz line_start = self.buf.line_start(self.buf.line_of(pos));
	String before = self.buf.str()[line_start:pos - line_start];
	sz unit = self.indent_unit.len;
	bool all_spaces = before.len > 0;
	foreach (c : before) if (c != ' ') all_spaces = false;
	if (all_spaces && unit > 1) {
		sz back = before.len % unit;
		return pos - (back == 0 ? unit : back);
	}
	return prev_char(self.buf.str(), pos);
}

// tab indents: at a caret it inserts up to the next indent stop; a
// selection over several lines indents them all.
fn void View.tab(&self) {
	foreach (s : self.sels) {
		if (self.buf.line_of(s.start()) != self.buf.line_of(s.end())) {
			self.indent_lines(true);
			return;
		}
	}
	if (self.indent_unit == "\t") {
		self.insert_text("\t");
		return;
	}
	// Up to the next stop, so Tab lines things up rather than adding a fixed
	// amount wherever it is pressed.
	int line;
	int col;
	self.caret_line_col(&line, &col);
	sz unit = self.indent_unit.len;
	self.insert_text(self.indent_unit[:unit - col % unit]);
}

// indent_lines adds (or with in = false, removes) one indent at the start of
// every line a selection touches.
fn void View.indent_lines(&self, bool in) {
	@pool() {
		Step* step = self.history.begin(OTHER, self.sels.array_view());
		// Every line touched, last first, each once.
		List{int} lines;
		lines.init(tmem);
		foreach (s : self.sels) {
			int last = self.buf.line_of(s.end());
			// A selection ending at the very start of a line leaves it alone.
			if (last > self.buf.line_of(s.start()) && self.buf.line_start(last) == s.end()) last--;
			for (int l = self.buf.line_of(s.start()); l <= last; l++) {
				if (!lines.contains(l)) lines.push(l);
			}
		}
		for (sz i = 1; i < lines.len(); i++) {
			for (sz j = i; j > 0 && lines[j - 1] < lines[j]; j--) @swap(lines[j - 1], lines[j]);
		}
		foreach (l : lines) {
			sz start = self.buf.line_start(l);
			if (in) {
				if (self.buf.line_end(l) > start) self.apply(step, start, start, self.indent_unit);
			} else {
				String line = self.buf.line(l);
				sz n = 0;
				if (line.len > 0 && line[0] == '\t') {
					n = 1;
				} else {
					while (n < line.len && n < self.indent_unit.len && line[n] == ' ') n++;
				}
				if (n > 0) self.apply(step, start, start + n, "");
			}
		}
		self.after_edit(step);
	};
}

fn void View.undo(&self) {
	if (self.history.done.len() == 0) return;
	Step step = self.history.done.pop()!!;
	for (sz i = step.changes.len(); i > 0; i--) {
		Change* c = &step.changes[i - 1];
		Edit e = self.buf.replace(c.at, c.at + c.inserted_len, step.removed(c));
		foreach (&l : self.layers) l.map(e);
	}
	self.set_selections(step.before.array_view());
	self.history.undone.push(step);
	self.history.seal();
	self.scroll_to_caret();
}

fn void View.redo(&self) {
	if (self.history.undone.len() == 0) return;
	Step step = self.history.undone.pop()!!;
	foreach (&c : step.changes) {
		Edit e = self.buf.replace(c.at, c.at + c.removed_len, step.inserted(c));
		foreach (&l : self.layers) l.map(e);
	}
	self.set_selections(step.after.array_view());
	self.history.done.push(step);
	self.history.seal();
	self.scroll_to_caret();
}

fn void View.set_selections(&self, Selection[] sels) {
	self.sels.clear();
	foreach (s : sels) self.sels.push(s);
	if (self.sels.len() == 0) self.sels.push(caret(0));
}

// ── clipboard ─────────────────────────────────────────────────────────────

// selected_text is the text of every selection, one per line.
fn String View.selected_text(&self) {
	DString out = dstring::temp();
	foreach (i, s : self.sels) {
		if (s.is_empty()) continue;
		if (out.len() > 0) out.append_char('\n');
		out.append(self.buf.str()[s.start():s.end() - s.start()]);
	}
	return out.str_view();
}

fn void View.select_all(&self) {
	self.set_selections({ { .anchor = 0, .head = self.buf.len(), .goal_col = -1 } });
	self.history.seal();
}

// ── moving ────────────────────────────────────────────────────────────────

enum Motion : char {
	CHAR_LEFT,
	CHAR_RIGHT,
	WORD_LEFT,
	WORD_RIGHT,
	LINE_START,
	LINE_END,
	ROW_UP,
	ROW_DOWN,
	PAGE_UP,
	PAGE_DOWN,
	DOC_START,
	DOC_END,
}

// move moves every selection's head; extend keeps the anchor, selecting.
fn void View.move(&self, Motion m, bool extend = false) {
	@pool() {
		foreach (&s : self.sels) {
			// Left or right on a selection without extending lands on its edge.
			if (!extend && !s.is_empty() && (m == CHAR_LEFT || m == CHAR_RIGHT)) {
				*s = caret(m == CHAR_LEFT ? s.start() : s.end());
				continue;
			}
			int goal = s.goal_col;
			sz head = self.target(s.head, m, &goal);
			s.head = head;
			if (!extend) s.anchor = head;
			bool vertical = m == ROW_UP || m == ROW_DOWN || m == PAGE_UP || m == PAGE_DOWN;
			s.goal_col = vertical ? goal : -1;
		}
		self.merge_selections();
	};
	self.history.seal();
	self.scroll_to_caret();
}

fn sz View.target(&self, sz pos, Motion m, int* goal) {
	String text = self.buf.str();
	int line = self.buf.line_of(pos);
	switch (m) {
		case CHAR_LEFT: return prev_char(text, pos);
		case CHAR_RIGHT: return next_char(text, pos);
		case WORD_LEFT: return self.word_start(pos);
		case WORD_RIGHT: return self.word_end(pos);
		case LINE_START:
			// First to the text, then to the very start.
			sz start = self.buf.line_start(line);
			sz first = start;
			while (first < self.buf.line_end(line) && (text[first] == ' ' || text[first] == '\t')) first++;
			return pos == first ? start : first;
		case LINE_END: return self.buf.line_end(line);
		case ROW_UP: return self.by_rows(pos, -1, goal);
		case ROW_DOWN: return self.by_rows(pos, 1, goal);
		case PAGE_UP: return self.by_rows(pos, -(self.height > 2 ? self.height - 2 : 1), goal);
		case PAGE_DOWN: return self.by_rows(pos, self.height > 2 ? self.height - 2 : 1, goal);
		case DOC_START: return 0;
		case DOC_END: return self.buf.len();
	}
}

// by_rows moves n screen rows up or down, wrapped rows included, keeping to
// the goal column.
fn sz View.by_rows(&self, sz pos, int n, int* goal) {
	int line = self.buf.line_of(pos);
	LineLayout ll;
	self.layout_line(line, self.text_width, &ll);
	int row;
	int col;
	ll.locate(pos, &row, &col);
	if (*goal < 0) *goal = col;
	row += n;
	while (row < 0) {
		if (line == 0) return 0;
		line--;
		self.layout_line(line, self.text_width, &ll);
		row += (int)ll.rows.len();
	}
	while (row >= ll.rows.len()) {
		if (line + 1 >= self.buf.line_count()) return self.buf.len();
		row -= (int)ll.rows.len();
		line++;
		self.layout_line(line, self.text_width, &ll);
	}
	return ll.pos_at(row, *goal, self.buf.line_end(line));
}

// merge_selections joins selections that have come to overlap.
fn void View.merge_selections(&self) {
	for (sz i = 0; i < self.sels.len(); i++) {
		for (sz j = self.sels.len(); j > i + 1; j--) {
			Selection a = self.sels[i];
			Selection b = self.sels[j - 1];
			bool touch = a.is_empty() && b.is_empty() ? a.head == b.head
				: a.start() < b.end() && b.start() < a.end();
			if (!touch) continue;
			sz start = a.start() < b.start() ? a.start() : b.start();
			sz end = a.end() > b.end() ? a.end() : b.end();
			self.sels[i] = a.head >= a.anchor ? { .anchor = start, .head = end, .goal_col = -1 }
				: { .anchor = end, .head = start, .goal_col = -1 };
			self.sels.remove_at(j - 1);
		}
	}
}

fn bool is_word(char c) => c == '_' || c.is_alnum() || c >= 0x80;

fn sz View.word_start(&self, sz pos) {
	String t = self.buf.str();
	while (pos > 0 && (t[pos - 1] == ' ' || t[pos - 1] == '\t')) pos--;
	if (pos > 0 && is_word(t[pos - 1])) {
		while (pos > 0 && is_word(t[pos - 1])) pos--;
	} else if (pos > 0) {
		pos = prev_char(t, pos);
	}
	return pos;
}

fn sz View.word_end(&self, sz pos) {
	String t = self.buf.str();
	while (pos < t.len && (t[pos] == ' ' || t[pos] == '\t')) pos++;
	if (pos < t.len && is_word(t[pos])) {
		while (pos < t.len && is_word(t[pos])) pos++;
	} else if (pos < t.len) {
		pos = next_char(t, pos);
	}
	return pos;
}

fn sz prev_char(String t, sz pos) {
	if (pos == 0) return 0;
	pos--;
	while (pos > 0 && (t[pos] & 0xC0) == 0x80) pos--;
	return pos;
}

fn sz next_char(String t, sz pos) {
	if (pos >= t.len) return t.len;
	pos++;
	while (pos < t.len && (t[pos] & 0xC0) == 0x80) pos++;
	return pos;
}

// ── keys ──────────────────────────────────────────────────────────────────

// clipboard holds what copy and cut took, for paste. It is the editor's own:
// the system clipboard is the host's to wire up.
DString clipboard;

// The key map, per platform. On macOS, Cmd is the command key (select all,
// clipboard, undo) and moves to the ends of lines and the document; Option
// moves by words; Ctrl+A and Ctrl+E go to the start and end of the line, as
// in every macOS text field. Elsewhere Ctrl does all of that, and Home/End
// take the ends of lines. A terminal never sees Cmd, so on a Mac the Ctrl
// forms of undo and the clipboard work too.
const bool MAC = env::DARWIN;

// handle_key runs the command a key is bound to, reporting whether it was
// one of the editor's.
fn bool View.handle_key(&self, milktea::KeyMsg k) {
	bool word = k.alt || k.ctrl;
	bool cmd = MAC && k.super;
	switch (k.code) {
		case LEFT: self.move(cmd ? LINE_START : word ? WORD_LEFT : CHAR_LEFT, k.shift);
		case RIGHT: self.move(cmd ? LINE_END : word ? WORD_RIGHT : CHAR_RIGHT, k.shift);
		case UP: self.move(cmd ? DOC_START : ROW_UP, k.shift);
		case DOWN: self.move(cmd ? DOC_END : ROW_DOWN, k.shift);
		case HOME: self.move(k.ctrl ? DOC_START : LINE_START, k.shift);
		case END: self.move(k.ctrl ? DOC_END : LINE_END, k.shift);
		case PAGE_UP: self.move(PAGE_UP, k.shift);
		case PAGE_DOWN: self.move(PAGE_DOWN, k.shift);
		case ENTER: self.newline();
		case BACKSPACE: self.delete_back(word);
		case DELETE: self.delete_forward(word);
		// Terminals report Ctrl+C as a key of its own.
		case CTRL_C: return self.command('c', false);
		case TAB:
			if (k.shift) { self.indent_lines(false); } else { self.tab(); }
		case RUNE:
			if (k.super) return self.command(k.rune, k.shift);
			if (k.ctrl) return self.ctrl_key(k.rune, k.shift);
			if (k.alt) return false;
			DString s = dstring::temp();
			s.append_char32(k.rune);
			self.type_text(s.str_view());
		default:
			return false;
	}
	return true;
}

fn bool View.ctrl_key(&self, uint rune, bool shift) {
	if (MAC) {
		switch (rune) {
			case 'a': self.move(LINE_START, shift); return true;
			case 'e': self.move(LINE_END, shift); return true;
			default:
		}
	}
	return self.command(rune, shift);
}

// command runs what the command key does with a letter: Cmd on macOS, Ctrl
// elsewhere.
fn bool View.command(&self, uint rune, bool shift) {
	switch (rune) {
		case 'z':
			if (shift) { self.redo(); } else { self.undo(); }
		case 'y': self.redo();
		case 'a': self.select_all();
		case 'c':
			clipboard.clear();
			clipboard.append(self.selected_text());
		case 'x':
			clipboard.clear();
			clipboard.append(self.selected_text());
			self.insert_text("");
		case 'v':
			if (clipboard.len() > 0) self.insert_text(clipboard.str_view());
		default:
			return false;
	}
	return true;
}
