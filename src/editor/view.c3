module ted::editor;

import glaze;
import xray;
import milktea;
import boba;
import std::collections::list;

// View is the editor component: a buffer, the selections in it, the
// decoration layers drawn over it, and how it is scrolled. It is xray
// Content, so it goes into a layout tree like any other node.
//
// Everything on screen comes from one step, layout_line(), which turns a
// line of the buffer into glyphs — what to draw, how wide it is, and which
// byte it stands for, if any — and cuts them into rows. Drawing walks the
// glyphs; placing the caret finds its byte among them; a click finds the
// glyph under it. A hint or widget is a glyph with no byte, so all three
// handle it without knowing it is there.

struct View (xray::Content) {
	Buffer buf;
	// The selections, primary first. There is always at least one.
	list::List{Selection} sels;
	list::List{Layer} layers;
	History history;
	// Language knowledge, when there is some: see Assist.
	Assist assist;
	// Brackets and quotes that pair up as they are typed, openers and
	// closers alternating.
	list::List{String} pairs;
	Completion completion;
	// What the current run of Ctrl+K presses has cut, and whether the last
	// key was one of them.
	DString kill_buffer;
	bool killing;
	// Where the view was drawn last, on screen, for placing popups.
	xray::Rect rect;

	// Scroll position: the first line on screen, and how many of its wrapped
	// rows are above the top.
	sz top_line;
	sz top_row;
	// The first display column on screen, when lines do not wrap and one
	// can run past the right edge, and the part of a column a trackpad has
	// moved the view across without reaching a whole one.
	sz left_col;
	float left_px;
	// Blank rows above the first line while a trackpad pulls the view past
	// the start (see scroller).
	sz lead_blank;
	// Smooth scrolling in a window: a pixel position over the wrapped rows,
	// kept in step with top_line/top_row. no_rubber_band keeps the view from
	// being pulled past either end.
	boba::Scroller scroller;
	bool no_rubber_band;
	// The text area's size at the last render, in cells, for commands that
	// move by a screenful.
	sz text_width;
	sz height;

	bool focused;
	bool wrap;
	bool line_numbers;
	// A lighter background behind the caret's line, and which guides are
	// drawn in indentation.
	bool highlight_line;
	GuideMode guides;
	CaretKind caret_kind;
	sz tab_width;
	// What Tab inserts and indent/dedent add or remove.
	String indent_unit;

	glaze::Style text_style;
	glaze::Style gutter_style;
	glaze::Style gutter_current_style;
	glaze::Style selection_style;
	// Only the background is used: it takes the place of the text's.
	glaze::Style current_line_style;
	glaze::Style guide_style;
	glaze::Style guide_active_style;
	// A caret other than the primary one, which the terminal draws.
	glaze::Style caret_style;
	// Scrollbar at the right edge: a thin track with a thicker thumb in the
	// visible region. Both carry the editor background so the bar reads as
	// part of the page, not a panel stuck to its side.
	glaze::Style scrollbar_track_style;
	glaze::Style scrollbar_thumb_style;
	milktea::CursorStyle caret;
	// When the caret last moved or the text changed, on the frame clock: the
	// caret shows steadily for a moment after either, then blinks.
	sz blink_epoch;
	sz blink_head;
	sz blink_version;
	// The text area a GUI bar or underline caret was placed against, to tell
	// when the render that follows laid it out at another size.
	sz caret_width;
	sz caret_height;

	// Wrapped-row index each line starts at, plus the total at the end, for
	// the scrollbar. Laying out the whole document on every render to count
	// rows was the most expensive part of drawing a frame, so it is rebuilt
	// only when something rows depend on changes; row_key says what it was
	// built for.
	list::List{sz} row_starts;
	RowKey row_key;

	// Fired when a press lands in the view, after it has moved the caret.
	ViewPressFn on_press_fn;
	void* on_press_ctx;
}

alias ViewPressFn = fn void(void* ctx);

// GuideMode says which indent guides a view draws: none, only the one of
// the block the caret is in, or one at every level with that one brighter.
enum GuideMode : char {
	NONE,
	CURRENT,
	ALL,
}

// CaretKind is how the caret is drawn: over the whole cell, as a thin bar at
// its left edge, or as a line along its bottom.
enum CaretKind : char {
	BLOCK,
	BAR,
	UNDERLINE,
}

// RowKey is everything a line's wrapped row count depends on: the text, the
// width and wrap settings, and the INLINE decorations, whose texts take up
// cells. The layers are summarised by their item counts and text sizes.
struct RowKey {
	sz version;
	sz width;
	bool wrap;
	sz tab_width;
	usz layers;
}

// NO_POS marks a glyph that stands for no byte of the buffer.
const sz NO_POS = (sz)-1;

struct Glyph {
	String text;
	sz width;
	sz pos;
	glaze::Style style;
}

// Row is one screen row of a line: glyphs [first, first + count).
struct Row {
	sz first;
	sz count;
	sz width;
}

struct LineLayout {
	sz line;
	list::List{Glyph} glyphs;
	list::List{Row} rows;
}

fn void View.init(&self) {
	self.buf.init();
	self.sels.init(mem);
	self.sels.push(caret(0));
	self.layers.init(mem);
	self.history.init();
	self.pairs.init(mem);
	self.completion.init();
	self.kill_buffer.init(mem);
	self.row_starts.init(mem);
	self.row_key.version = -1;
	self.set_pairs(&DEFAULT_PAIRS);
	self.text_width = 80;
	self.height = 24;
	self.wrap = false;
	self.line_numbers = true;
	self.highlight_line = true;
	self.guides = CURRENT;
	self.tab_width = 4;
	self.indent_unit = "    ";
	// A blinking caret, the terminal's own or painted (see draw_caret).
	// Field by field: a GUI has set caret.draw before init runs.
	self.caret.blink = true;
	self.caret.blink_ms = BLINK_MS;
	self.set_caret_kind(BLOCK);
}

fn void View.free(&self) {
	self.buf.free();
	self.sels.free();
	foreach (&l : self.layers) l.free();
	self.layers.free();
	self.history.free();
	self.pairs.free();
	self.completion.free();
	self.kill_buffer.free();
	self.row_starts.free();
}

// set_text replaces the whole document, as opening a file does: the caret
// goes to the top, decorations and history start over.
fn void View.set_text(&self, String s) {
	self.buf.set_text(s);
	self.sels.clear();
	self.sels.push(caret(0));
	foreach (&l : self.layers) l.clear();
	self.history.clear();
	self.completion.close();
	self.top_line = 0;
	self.top_row = 0;
	self.left_col = 0;
}

fn String View.text(&self) => self.buf.str();
fn Selection* View.primary(&self) => &self.sels[0];

// layer returns the layer with this name, making it on first use.
fn Layer* View.layer(&self, String name, sz order = 0) {
	foreach (&l : self.layers) if (l.name == name) return l;
	Layer l;
	l.init(name, order);
	sz i = self.layers.len();
	while (i > 0 && self.layers[i - 1].order > order) i--;
	self.layers.insert_at(i, l);
	return &self.layers[i];
}

// caret_line_col is the primary caret's line and column, both from zero,
// the column counted in characters.
fn void View.caret_line_col(&self, sz* line, sz* col) {
	sz head = self.primary().head;
	*line = self.buf.line_of(head);
	String before = self.buf.str()[self.buf.line_start(*line):head - self.buf.line_start(*line)];
	sz n = 0;
	foreach (c : before) if ((c & 0xC0) != 0x80) n++;
	*col = n;
}

// ── layout ────────────────────────────────────────────────────────────────

fn glaze::Style overlay(glaze::Style base, glaze::Style top) @local {
	glaze::Style s = base;
	if (top.fg.kind != glaze::ColorKind.NONE) s.fg = top.fg;
	if (top.bg.kind != glaze::ColorKind.NONE) s.bg = top.bg;
	s.bold = s.bold || top.bold;
	s.italic = s.italic || top.italic;
	s.underline = s.underline || top.underline;
	return s;
}

fn bool View.selected(&self, sz pos) {
	foreach (s : self.sels) {
		if (!s.is_empty() && pos >= s.start() && pos < s.end()) return true;
	}
	return false;
}

// first_at is the index of the first decoration in l starting at or after
// pos.
fn sz first_at(Layer* l, sz pos) @local {
	sz lo = 0;
	sz hi = l.items.len();
	while (lo < hi) {
		sz mid = (lo + hi) / 2;
		if (l.items[mid].start < pos) { lo = mid + 1; } else { hi = mid; }
	}
	return lo;
}

// style_at is the text style at pos with every layer's decorations over it,
// in layer order. A layer's STYLE decorations do not overlap one another, so
// the only one that can cover pos is the last to start at or before it.
fn glaze::Style View.style_at(&self, sz pos) {
	glaze::Style s = self.text_style;
	foreach (&l : self.layers) {
		sz i = first_at(l, pos + 1);
		while (i > 0) {
			Decoration* d = &l.items[i - 1];
			if (d.kind == STYLE) {
				if (pos < d.end) s = overlay(s, d.style);
				break;
			}
			i--;
		}
	}
	return s;
}

fn void View.push_inlines(&self, LineLayout* out, sz pos) {
	foreach (&l : self.layers) {
		for (sz i = first_at(l, pos); i < l.items.len() && l.items[i].start == pos; i++) {
			Decoration* d = &l.items[i];
			if (d.kind != INLINE) continue;
			String t = l.text_of(d);
			out.glyphs.push({ .text = t, .width = (sz)glaze::string_width(t), .pos = NO_POS,
				.style = overlay(self.text_style, d.style) });
		}
	}
}

// layout_line lays out one line at the given text width: its glyphs, and the
// rows they wrap into. The lists come from temp memory.
fn void View.layout_line(&self, sz line, sz width, LineLayout* out) {
	out.line = line;
	out.glyphs.init(tmem);
	out.rows.init(tmem);
	String text = self.buf.str();
	sz start = self.buf.line_start(line);
	sz end = self.buf.line_end(line);

	sz col = 0;
	sz pos = start;
	while (pos < end) {
		self.push_inlines(out, pos);
		glaze::Style s = self.style_at(pos);
		if (self.selected(pos)) s = overlay(s, self.selection_style);
		if (self.is_secondary_caret(pos)) s = overlay(s, self.caret_style);
		sz n = glaze::utf8_sequence_len(text, pos);
		if (text[pos] == '\t') {
			sz w = self.tab_width - col % self.tab_width;
			out.glyphs.push({ .text = "        "[:w], .width = w, .pos = pos, .style = s });
			col += w;
		} else {
			sz w = glaze::utf8_width_at(text, pos);
			out.glyphs.push({ .text = text[pos:n], .width = w, .pos = pos, .style = s });
			col += w;
		}
		pos += n;
	}
	self.push_inlines(out, end);
	// The newline has no glyph of its own; one stands in for it when it is
	// selected, or when another caret sits at the end of the line.
	bool eol_selected = end < self.buf.len() && self.selected(end);
	if (eol_selected || self.is_secondary_caret(end)) {
		glaze::Style s = self.text_style;
		if (eol_selected) s = overlay(s, self.selection_style);
		if (self.is_secondary_caret(end)) s = overlay(s, self.caret_style);
		out.glyphs.push({ .text = " ", .width = 1, .pos = end, .style = s });
	}
	self.wrap_rows(out, width);
}

fn bool View.is_secondary_caret(&self, sz pos) {
	for (sz i = 1; i < self.sels.len(); i++) {
		if (self.sels[i].head == pos) return true;
	}
	return false;
}

// wrap_rows cuts the glyphs into rows no wider than width, breaking after a
// space where one is near enough.
fn void View.wrap_rows(&self, LineLayout* out, sz width) {
	Row row = { .first = 0 };
	sz last_space = NO_POS;
	for (sz i = 0; i < out.glyphs.len(); i++) {
		Glyph* g = &out.glyphs[i];
		if (self.wrap && width > 0 && row.width + g.width > width && row.count > 0) {
			// Back up to the last space in the row, unless that leaves it short.
			sz cut = i;
			if (last_space != NO_POS && last_space + 1 > row.first && last_space + 1 < i) cut = last_space + 1;
			Row done = { .first = row.first, .count = cut - row.first };
			for (sz j = done.first; j < cut; j++) done.width += out.glyphs[j].width;
			out.rows.push(done);
			row = { .first = cut };
			for (sz j = cut; j < i; j++) { row.count++; row.width += out.glyphs[j].width; }
			last_space = NO_POS;
		}
		row.count++;
		row.width += g.width;
		if (g.text == " ") last_space = i;
	}
	out.rows.push(row);
	// A caret after a full last row needs a row of its own to sit on.
	if (self.wrap && width > 0 && row.width >= width) out.rows.push({ .first = out.glyphs.len() });
}

// row_of finds where pos lands in a laid-out line: its row and column.
fn void LineLayout.locate(&self, sz pos, sz* row, sz* col) {
	for (sz r = 0; r < self.rows.len(); r++) {
		Row* rw = &self.rows[r];
		sz c = 0;
		for (sz i = rw.first; i < rw.first + rw.count; i++) {
			if (self.glyphs[i].pos == pos) {
				*row = (sz)r;
				*col = c;
				return;
			}
			c += self.glyphs[i].width;
		}
	}
	// Not a glyph: the end of the line.
	*row = (sz)self.rows.len() - 1;
	*col = self.rows[self.rows.len() - 1].width;
}

// pos_at finds the byte a column of a row stands for: the glyph under it,
// or the next real one after a hint, or the line's end past the text.
fn sz LineLayout.pos_at(&self, sz row, sz col, sz line_end) {
	Row* rw = &self.rows[row];
	sz c = 0;
	for (sz i = rw.first; i < self.glyphs.len(); i++) {
		Glyph* g = &self.glyphs[i];
		bool past_row = i >= rw.first + rw.count;
		if (g.pos != NO_POS && (past_row || c + g.width > col)) return g.pos;
		if (!past_row) c += g.width;
	}
	return line_end;
}

// ── scrolling ─────────────────────────────────────────────────────────────

// SCROLLBAR_W is the number of cells reserved on the right edge of the view
// for the scrollbar: one cell of gap, then one cell of bar. The bar itself is
// always one cell wide; the gap keeps it from kissing the text.
const sz SCROLLBAR_W = 2;

fn sz View.scrollbar_reserved(&self) => SCROLLBAR_W;

// total_rows is the document's wrapped row count — what the scrollbar tracks.
// Each line contributes the number of rows it wraps into at the view's text
// width; a line wider than the text area wraps into more than one row.
// Render is itself called inside an @pool(), so a fresh tmem is already in
// scope — layout_line's glyphs/rows lists live there and are released when
// the caller exits.
fn sz View.total_rows(&self) {
	self.update_row_starts();
	return self.row_starts[self.row_starts.len() - 1];
}

// update_row_starts rebuilds row_starts when its key no longer matches.
fn void View.update_row_starts(&self) {
	usz layers = 0;
	foreach (&l : self.layers) layers = layers * 31 + (usz)l.items.len() * 7919 + (usz)l.texts.len();
	RowKey key = { self.buf.version, self.text_width, self.wrap, self.tab_width, layers };
	if (self.row_starts.len() > 0 && key.version == self.row_key.version
		&& key.width == self.row_key.width && key.wrap == self.row_key.wrap
		&& key.tab_width == self.row_key.tab_width && key.layers == self.row_key.layers) return;
	self.row_key = key;
	self.row_starts.clear();
	sz total = 0;
	sz lines = self.buf.line_count();
	@pool() {
		for (sz l = 0; l < lines; l++) {
			self.row_starts.push(total);
			LineLayout ll;
			self.layout_line(l, self.text_width, &ll);
			total += (sz)ll.rows.len();
		}
	};
	self.row_starts.push(total);
}

// first_visible_row_index is the wrapped-row index of the top of the screen,
// counting from the document's start. The thumb's row comes from this.
fn sz View.first_visible_row_index(&self) {
	self.update_row_starts();
	sz line = self.top_line;
	if (line >= self.row_starts.len()) line = (sz)self.row_starts.len() - 1;
	return self.row_starts[line] + self.top_row;
}

// append_scrollbar writes the gap cell and the bar cell at the end of a row.
// drawn is the row's screen index so the thumb lands in the right cell.
fn void View.append_scrollbar(&self, DString* out, sz drawn, sz bar_reserved, sz thumb_row) {
	if (bar_reserved <= 0) return;
	// The gap cell uses the text style so the background continues out to
	// the bar — the bar itself is just a vertical line, not a panel.
	out.append_string(self.text_style.render(" "));
	String bar;
	if (drawn == thumb_row) {
		bar = self.scrollbar_thumb_style.render("┃");
	} else {
		bar = self.scrollbar_track_style.render("│");
	}
	out.append_string(bar);
}

fn sz View.gutter_width(&self) {
	if (!self.line_numbers) return 0;
	sz digits = 1;
	for (sz n = self.buf.line_count(); n >= 10; n /= 10) digits++;
	if (digits < 3) digits = 3;
	return digits + 2;
}

fn sz View.rows_in(&self, sz line) {
	LineLayout ll;
	self.layout_line(line, self.text_width, &ll);
	return (sz)ll.rows.len();
}

// set_top_row puts the view's top at wrapped row g of the document; a g
// before the start leaves that many blank rows above the first line.
fn void View.set_top_row(&self, sz g) {
	self.update_row_starts();
	self.lead_blank = g < 0 ? -g : 0;
	if (g < 0) g = 0;
	sz total = self.row_starts[self.row_starts.len() - 1];
	if (total > 0 && g > total - 1) g = total - 1;
	// The last line whose first row is at or before g.
	sz lo = 0;
	sz hi = (sz)self.buf.line_count() - 1;
	while (lo < hi) {
		sz mid = (lo + hi + 1) / 2;
		if (self.row_starts[mid] <= g) { lo = mid; } else { hi = mid - 1; }
	}
	self.top_line = lo;
	self.top_row = g - self.row_starts[lo];
}

// scroll_state brings the scroller up to date with the document and with
// top_line/top_row, which keys and caret tracking move by rows.
fn boba::Scroller* View.scroll_state(&self) {
	self.scroller.rubber_band = !self.no_rubber_band;
	self.scroller.set_content(self.total_rows(), self.height);
	self.scroller.sync_row(self.lead_blank > 0 ? -self.lead_blank : self.first_visible_row_index());
	return &self.scroller;
}

// scroll_msg scrolls by what a window reports for a wheel or trackpad (see
// boba::Scroller.handle), and reports whether it did; a terminal's wheel is
// left to scroll().
fn bool View.scroll_msg(&self, milktea::MouseMsg m) {
	boba::Scroller* sc = self.scroll_state();
	if (!sc.handle(m)) return false;
	self.set_top_row(sc.top_row());
	return true;
}

// scroll_to_caret moves the view the least that brings the primary caret on
// screen.
fn void View.scroll_to_caret(&self) {
	self.lead_blank = 0;
	@pool() {
		sz head = self.primary().head;
		sz line = self.buf.line_of(head);
		LineLayout ll;
		self.layout_line(line, self.text_width, &ll);
		sz row;
		sz col;
		ll.locate(head, &row, &col);
		self.scroll_to_col(col);

		if (line < self.top_line || (line == self.top_line && row < self.top_row)) {
			self.top_line = line;
			self.top_row = row;
			return;
		}
		// Rows from the top of the screen down to the caret, counted only as
		// far as a screenful.
		sz above = row - (line == self.top_line ? self.top_row : 0);
		for (sz l = line - 1; l >= self.top_line && above < self.height; l--) {
			above += l == self.top_line ? self.rows_in(l) - self.top_row : self.rows_in(l);
		}
		if (above < self.height) return;
		// Below the screen: count a screenful up from the caret, so it lands
		// on the bottom row.
		sz l = line;
		sz r = row;
		for (sz up = self.height - 1; up > 0; up--) {
			if (r > 0) {
				r--;
			} else if (l > 0) {
				l--;
				r = self.rows_in(l) - 1;
			} else {
				break;
			}
		}
		self.top_line = l;
		self.top_row = r;
	};
}

// scroll_to_col keeps a column on screen when lines do not wrap, moving the
// view across by the least that does it.
fn void View.scroll_to_col(&self, sz col) {
	if (self.wrap) {
		self.left_col = 0;
		return;
	}
	if (col < self.left_col) self.left_col = col;
	if (col >= self.left_col + self.text_width) self.left_col = col - self.text_width + 1;
	if (self.left_col < 0) self.left_col = 0;
}

// line_width is how many columns a line takes on screen.
fn sz View.line_width(&self, sz line) {
	String text = self.buf.str();
	sz end = self.buf.line_end(line);
	sz col = 0;
	for (sz pos = self.buf.line_start(line); pos < end; pos += glaze::utf8_sequence_len(text, pos)) {
		col += text[pos] == '\t' ? self.tab_width - col % self.tab_width : glaze::utf8_width_at(text, pos);
	}
	return col;
}

// clamp_left_col keeps the view from being scrolled further across than the
// widest line on screen needs, with a column to spare for a caret at its
// end. A window made wider, or a view scrolled to shorter lines, comes back
// towards the left edge by itself.
fn void View.clamp_left_col(&self) {
	if (self.wrap) {
		self.left_col = 0;
		return;
	}
	sz widest = 0;
	sz last = self.top_line + self.height;
	for (sz l = self.top_line; l < self.buf.line_count() && l <= last; l++) {
		sz w = self.line_width(l);
		if (w > widest) widest = w;
	}
	sz most = widest + 1 - self.text_width;
	if (self.left_col > most) self.left_col = most;
	if (self.left_col < 0) self.left_col = 0;
}

// scroll_cols moves the view across by columns without moving the caret.
fn void View.scroll_cols(&self, sz cols) {
	if (self.wrap) return;
	self.left_col += cols;
	self.clamp_left_col();
}

// scroll_msg_x moves the view across by what a window reports for a
// sideways trackpad swipe, in pixels, positive towards the start of the
// line as scroll_dy is towards the start of the document. Reports whether it
// took the message.
fn bool View.scroll_msg_x(&self, milktea::MouseMsg m) {
	if (self.wrap || m.scroll_dx == 0) return false;
	float unit = (float)milktea::layout_metrics().unit_w();
	self.left_px -= m.scroll_dx;
	sz cols = (sz)(self.left_px / unit);
	if (cols != 0) {
		self.left_px -= (float)cols * unit;
		self.scroll_cols(cols);
	}
	return true;
}

// scroll moves the view by rows without moving the caret, as a wheel does.
fn void View.scroll(&self, sz rows) {
	self.lead_blank = 0;
	@pool() {
		while (rows > 0) {
			sz left = self.rows_in(self.top_line) - self.top_row;
			if (self.top_line >= self.buf.line_count() - 1 && left <= 1) return;
			if (left > 1) { self.top_row++; } else { self.top_line++; self.top_row = 0; }
			rows--;
		}
		while (rows < 0) {
			if (self.top_row > 0) {
				self.top_row--;
			} else if (self.top_line > 0) {
				self.top_line--;
				self.top_row = self.rows_in(self.top_line) - 1;
			} else {
				return;
			}
			rows++;
		}
	};
}

// ── drawing ───────────────────────────────────────────────────────────────

fn String spaces(sz n) @local {
	DString d = dstring::temp();
	for (sz i = 0; i < n; i++) d.append_char(' ');
	return d.str_view();
}

fn String pad_left(String s, sz width) @local {
	return width > s.len ? string::tformat("%s%s", spaces(width - (sz)s.len), s) : s;
}

fn bool same_style(glaze::Style* a, glaze::Style* b) @local {
	return mem::equals(a, b, @sizeof(*a));
}

fn bool same_color(glaze::Color a, glaze::Color b) @local {
	return mem::equals(&a, &b, @sizeof(a));
}

// Piece is one glyph of a row on its way to the screen, at its display
// column from the start of the line.
struct Piece @local {
	String text;
	sz col;
	sz width;
	glaze::Style style;
}

// emit_row writes the pieces that fall in columns [from, from + width), runs
// of one style together, cutting a glyph that straddles either edge down to
// the blanks it shows, and fills what is left of the row with pad.
fn void emit_row(DString* out, Piece[] pieces, sz from, sz width, glaze::Style pad) @local {
	sz to = from + width;
	sz at = from;
	DString run = dstring::temp();
	glaze::Style run_style;
	bool open = false;
	foreach (&p : pieces) {
		if (p.col + p.width <= from || p.col >= to) continue;
		sz lo = p.col < from ? from : p.col;
		sz hi = p.col + p.width > to ? to : p.col + p.width;
		String t = lo != p.col || hi != p.col + p.width ? spaces(hi - lo) : p.text;
		if (open && !same_style(&run_style, &p.style)) {
			out.append_string(run_style.render(run.str_view()));
			run = dstring::temp();
		}
		run_style = p.style;
		open = true;
		run.append_string(t);
		at = hi;
	}
	if (open) out.append_string(run_style.render(run.str_view()));
	if (at < to) out.append_string(pad.render(spaces(to - at)));
}

// ── indentation ───────────────────────────────────────────────────────────

// How far up and down a blank line looks for text to take its guides from.
const sz GUIDE_SCAN = 200;

// indent_width is the columns one level of indentation takes.
fn sz View.indent_width(&self) {
	if (self.indent_unit.len == 0 || self.indent_unit[0] == '\t') return self.tab_width > 0 ? self.tab_width : 4;
	return self.indent_unit.len;
}

// line_indent is the display width of a line's leading whitespace, or -1
// for a line with nothing else on it.
fn sz View.line_indent(&self, sz line) {
	String t = self.buf.str();
	sz end = self.buf.line_end(line);
	sz col = 0;
	for (sz p = self.buf.line_start(line); p < end; p++) {
		switch (t[p]) {
			case ' ': col++;
			case '\t': col += self.tab_width - col % self.tab_width;
			case '\r': continue;
			default: return col;
		}
	}
	return -1;
}

// guide_indent is how far into a line the indent guides reach: its own
// indentation, or, for a blank line, the lesser of the lines either side,
// so the guides run unbroken through a gap in a block.
fn sz View.guide_indent(&self, sz line) {
	sz own = self.line_indent(line);
	if (own >= 0) return own;
	sz up = 0;
	sz down = 0;
	for (sz l = line - 1; l >= 0 && l >= line - GUIDE_SCAN; l--) {
		sz i = self.line_indent(l);
		if (i >= 0) { up = i; break; }
	}
	for (sz l = line + 1; l < self.buf.line_count() && l <= line + GUIDE_SCAN; l++) {
		sz i = self.line_indent(l);
		if (i >= 0) { down = i; break; }
	}
	return up < down ? up : down;
}

// ActiveGuide is the guide of the block the caret is in: the column it is
// drawn at and the lines it runs down, those strictly inside the block.
struct ActiveGuide {
	bool on;
	sz col;
	sz first;
	sz last;
}

// active_guide finds the caret's block. With a syntax tree, that is the
// innermost node around the caret that starts on an earlier line; its guide
// sits at the indentation of the line it starts on. Without one, it is the
// run of lines around the caret indented deeper than one level less than
// the caret's own line.
fn ActiveGuide View.active_guide(&self) {
	sz head = self.primary().head;
	sz line = self.buf.line_of(head);
	if (self.assist && &self.assist.scope_at) {
		sz start;
		sz end;
		if (self.assist.scope_at(head, &start, &end)) {
			sz first = self.buf.line_of(start);
			sz last = self.buf.line_of(end);
			sz col = self.line_indent(first);
			if (col < 0) col = 0;
			// A block closed by a line of its own (a brace) stops above it;
			// one that ends with its last statement (Python) takes it in.
			if (self.guide_indent(last) <= col) last--;
			if (last <= first) return {};
			return { .on = true, .col = col, .first = first + 1, .last = last };
		}
		return {};
	}
	sz w = self.indent_width();
	sz indent = self.guide_indent(line);
	if (indent < w) return {};
	sz col = (indent - 1) / w * w;
	sz first = line;
	sz last = line;
	while (first > 0 && first > line - GUIDE_SCAN && self.guide_indent(first - 1) > col) first--;
	while (last + 1 < self.buf.line_count() && last < line + GUIDE_SCAN && self.guide_indent(last + 1) > col) last++;
	return { .on = true, .col = col, .first = first, .last = last };
}

fn bool is_blank(String t) @local {
	foreach (c : t) if (c != ' ') return false;
	return true;
}

// row_pieces lays a row's glyphs out as pieces: the caret's line on its own
// background, and guides in the blanks of the indentation.
fn void View.row_pieces(&self, LineLayout* ll, sz ri, bool current, sz indent,
	ActiveGuide* active, list::List{Piece}* out) {
	Row* row = &ll.rows[ri];
	glaze::Color line_bg = self.current_line_style.bg;
	sz w = self.indent_width();
	bool in_active = active.on && ll.line >= active.first && ll.line <= active.last;
	// Where the row starts on the line: wrapped rows go on from the last.
	sz col = 0;
	for (sz i = 0; i < row.first; i++) col += ll.glyphs[i].width;
	sz guides_to = ri == 0 && self.guides != NONE ? indent : 0;
	for (sz i = row.first; i < row.first + row.count; i++) {
		Glyph* g = &ll.glyphs[i];
		glaze::Style st = g.style;
		if (current && same_color(st.bg, self.text_style.bg)) st.bg = line_bg;
		if (col < guides_to && g.pos != NO_POS && is_blank(g.text)) {
			for (sz k = 0; k < g.width; k++) self.guide_cell(col + k, guides_to, w, in_active, active, st, out);
		} else {
			out.push({ .text = g.text, .col = col, .width = g.width, .style = st });
		}
		col += g.width;
	}
	// A blank line's guides go on through where its text would be.
	glaze::Style pad = current ? self.current_line_style : self.text_style;
	for (; col < guides_to; col++) self.guide_cell(col, guides_to, w, in_active, active, pad, out);
}

fn void View.guide_cell(&self, sz col, sz indent, sz w, bool in_active, ActiveGuide* active,
	glaze::Style under, list::List{Piece}* out) {
	bool is_active = in_active && col == active.col;
	bool every = self.guides == ALL && col % w == 0;
	if (col >= indent || (!every && !is_active)) {
		out.push({ .text = " ", .col = col, .width = 1, .style = under });
		return;
	}
	glaze::Style st = under;
	st.fg = is_active ? self.guide_active_style.fg : self.guide_style.fg;
	out.push({ .text = "│", .col = col, .width = 1, .style = st });
}

fn String View.render(&self, xray::Rect r) @dynamic {
	sz gutter = self.gutter_width();
	// The scrollbar lives in the last two cells of every row: one cell of
	// breathing room, then the bar itself. Reserve that space before laying
	// out text so a wrapped line never lands under it.
	sz bar_reserved = self.scrollbar_reserved();
	self.rect = r;
	self.text_width = r.w - gutter - bar_reserved;
	// A smooth scroll part-way into a row asks for one row more than fits.
	bool extra = milktea::layout_metrics().pixels && self.scroller.shift() > 0;
	self.height = extra ? r.h - 1 : r.h;
	if (self.text_width < 1) self.text_width = 1;
	sz caret_line = self.buf.line_of(self.primary().head);
	self.clamp_left_col();
	if (self.caret_kind != BLOCK && (self.text_width != self.caret_width || self.height != self.caret_height)) {
		milktea::frames_until(milktea::frame_ms() + 50);
	}
	ActiveGuide active = self.guides != NONE ? self.active_guide() : {};

	// The thumb sits at the row of the visible range that matches the view's
	// place in the document. total_rows is the whole document's wrapped line
	// count; visible_rows is what fits on screen. When the document fits, the
	// thumb degenerates to a single cell that fills the column, so the bar is
	// always present, never absent.
	sz total_rows = self.total_rows();
	sz visible_rows = r.h;
	sz thumb_row = -1;
	if (total_rows > visible_rows && visible_rows > 1) {
		// Which row of the document is on top of the screen, and how far
		// the thumb's top edge should sit from the column's top.
		sz first_visible = self.first_visible_row_index();
		sz last_first = total_rows - visible_rows;
		sz span = visible_rows - 1;
		if (last_first > 0) thumb_row = (first_visible * span + last_first / 2) / last_first;
	} else if (total_rows > 0 && total_rows <= visible_rows) {
		// Everything fits: hide the thumb, leave the track so the column
		// still reads as a scrollbar.
		thumb_row = -1;
	}

	DString out = dstring::temp();
	sz drawn = 0;
	// Rows before the start, while a trackpad pulls the view past it.
	for (; drawn < self.lead_blank && drawn < r.h; drawn++) {
		if (drawn > 0) out.append_char('\n');
		out.append_string(self.text_style.render(spaces(r.w - bar_reserved)));
		self.append_scrollbar(&out, drawn, bar_reserved, thumb_row);
	}
	for (sz line = self.top_line; line < self.buf.line_count() && drawn < r.h; line++) {
		LineLayout ll;
		self.layout_line(line, self.text_width, &ll);
		bool current = self.highlight_line && line == caret_line;
		glaze::Style base = current ? self.current_line_style : self.text_style;
		sz indent = self.guides != NONE ? self.guide_indent(line) : 0;
		for (sz ri = line == self.top_line ? self.top_row : 0; ri < ll.rows.len() && drawn < r.h; ri++) {
			if (drawn > 0) out.append_char('\n');
			if (gutter > 0) {
				glaze::Style gs = line == caret_line ? self.gutter_current_style : self.gutter_style;
				String num = ri == 0 ? pad_left(string::tformat("%d  ", line + 1), gutter) : spaces(gutter);
				out.append_string(gs.render(num));
			}
			list::List{Piece} pieces;
			pieces.init(tmem);
			self.row_pieces(&ll, ri, current, indent, &active, &pieces);
			// A wrapped row starts at its own first column; an unwrapped line
			// shows from the view's left column.
			sz from = self.left_col;
			if (self.wrap) {
				from = 0;
				for (sz i = 0; i < ll.rows[ri].first; i++) from += ll.glyphs[i].width;
			}
			emit_row(&out, pieces.array_view(), from, self.text_width, base);
			self.append_scrollbar(&out, drawn, bar_reserved, thumb_row);
			drawn++;
		}
	}
	// Past the end of the document the view is blank, in the text's colors.
	for (; drawn < r.h; drawn++) {
		if (drawn > 0) out.append_char('\n');
		out.append_string(self.text_style.render(spaces(r.w - bar_reserved)));
		self.append_scrollbar(&out, drawn, bar_reserved, thumb_row);
	}
	return out.str_view();
}

fn sz View.measure(&self, sz width) @dynamic => self.buf.line_count();
fn sz View.measure_width(&self, sz height) @dynamic => self.text_width + self.gutter_width();

// ── Caret ───────────────────────────────────────────────────────────────────
//
// A terminal places a cursor of its own, so the caret is left to it: a
// blinking block (see init). A GUI window has no cursor to place, so it asks
// for one painted into the grid instead, through View.caret.draw (see
// gui_main.c3). Either way the position comes from cursor() below.

// How long the caret stays on, and then off, while it blinks.
const sz BLINK_MS = 500;

// The GUI bar and underline carets, in points.
const sz CARET_THIN = 2;

// What a painted caret draws with, its kind, and when it last moved, on the
// frame clock. xray's cursor callback carries no context to read them from,
// so the view leaves them here on the way past (see cursor).
glaze::Style g_caret_style @local;
CaretKind g_caret_kind @local;
sz g_caret_epoch @local;

// set_caret_kind picks how the caret looks: the shape a terminal's cursor
// takes, and in a window whether it is painted into the grid (a block) or
// drawn over it (see caret_node).
fn void View.set_caret_kind(&self, CaretKind kind) {
	self.caret_kind = kind;
	switch (kind) {
		case BLOCK: self.caret.shape = (sz)milktea::CursorShape.CURSOR_BLOCK;
		case BAR: self.caret.shape = (sz)milktea::CursorShape.CURSOR_BAR;
		case UNDERLINE: self.caret.shape = (sz)milktea::CursorShape.CURSOR_UNDERLINE;
	}
}

// caret_on reports whether the caret is in its on phase: on for a moment
// after it moves or the text changes, so it is never missing while it is
// being followed, and then flipping on the blink clock.
fn bool View.caret_on(&self) {
	sz now = milktea::frame_ms();
	sz head = self.primary().head;
	if (head != self.blink_head || self.buf.version != self.blink_version) {
		self.blink_head = head;
		self.blink_version = self.buf.version;
		self.blink_epoch = now;
	}
	if (now - self.blink_epoch < BLINK_MS) return true;
	return (now / BLINK_MS) % 2 == 0;
}

// draw_caret paints the caret into the grid as a block. xray hands it the
// character already in the cell so the block can show it through, and a cell
// with nothing in it, past the end of a line, draws as a blank block. It
// stays on for a moment after the caret moves or the text changes, so it is
// never missing while it is being followed, and then blinks; an empty
// return is the off phase, which leaves the cell as it was.
fn String draw_caret(sz x, sz y, bool blink, String under) {
	// The other kinds are a node over the grid (see caret_node); this
	// callback still runs for them, which keeps the blink repainting.
	if (g_caret_kind != BLOCK) return "";
	if (!blink && milktea::frame_ms() - g_caret_epoch >= BLINK_MS) return "";
	String ch = under.len > 0 ? under : " ";
	return g_caret_style.render(ch);
}

// caret_cell finds the primary caret on screen, in cells from the top left
// of the view, gutter included. False when it is scrolled out of sight.
fn bool View.caret_cell(&self, sz* col, sz* row) {
	sz head = self.primary().head;
	sz line = self.buf.line_of(head);
	if (line < self.top_line) return false;
	sz r = 0;
	for (sz l = self.top_line; l < line && r <= self.height; l++) {
		r += self.rows_in(l) - (l == self.top_line ? self.top_row : 0);
	}
	LineLayout ll;
	self.layout_line(line, self.text_width, &ll);
	sz lrow;
	sz c;
	ll.locate(head, &lrow, &c);
	r += lrow - (line == self.top_line ? self.top_row : 0) + self.lead_blank;
	c -= self.left_col;
	if (r < 0 || r >= self.height || c < 0 || c > self.text_width) return false;
	*col = self.gutter_width() + c;
	*row = r;
	return true;
}

// cursor puts the caret on the primary selection's head, and notes when it
// last moved for the blink.
fn xray::ContentCursor View.cursor(&self, xray::Rect r) @dynamic {
	g_caret_style = self.caret_style;
	g_caret_kind = self.caret_kind;
	if (!self.focused) return {};
	self.caret_on();
	g_caret_epoch = self.blink_epoch;
	sz col;
	sz row;
	if (!self.caret_cell(&col, &row)) return {};
	return xray::place_cursor(r, col, row, self.caret);
}

// caret_node is the GUI's bar or underline caret: a thin line over the
// caret's cell, so the character there stays readable. It is placed against
// the last render's layout, which differs from this frame's only right after
// a resize; render asks for another frame then (see caret_width).
fn xray::Node* View.caret_node(&self) {
	if (!self.focused || self.caret_kind == BLOCK) return null;
	self.caret_width = self.text_width;
	self.caret_height = self.height;
	sz col;
	sz row;
	if (!self.caret_cell(&col, &row) || !self.caret_on()) return null;
	xray::LayoutMetrics m = milktea::layout_metrics();
	sz x = col * m.unit_w();
	sz y = row * m.unit_h() - self.scroller.shift();
	if (y < 0) return null;
	xray::Node* n = xray::vstack();
	if (self.caret_kind == BAR) {
		n.width(xray::pixels(CARET_THIN)).height(milktea::cells(1));
	} else {
		n.width(milktea::cells(1)).height(xray::pixels(CARET_THIN));
		y += m.unit_h() - CARET_THIN;
	}
	return n.at(x, y, PX).decorate(xray::solid(self.caret_style.bg));
}

// pos_at_cell is the buffer position under a cell of the view.
fn sz View.pos_at_cell(&self, sz col, sz row) {
	row -= self.lead_blank;
	if (row < 0) row = 0;
	col -= self.gutter_width();
	if (col < 0) col = 0;
	col += self.left_col;
	sz line = self.top_line;
	sz skip = self.top_row + row;
	@pool() {
		while (line < self.buf.line_count()) {
			LineLayout ll;
			self.layout_line(line, self.text_width, &ll);
			if (skip < ll.rows.len()) return ll.pos_at(skip, col, self.buf.line_end(line));
			skip -= (sz)ll.rows.len();
			line++;
		}
	};
	return self.buf.len();
}

fn xray::Node* View.node(&self) {
	xray::Node* n = xray::content_node(self).id_with(self)
		.on_click(&view_pressed).on_drag(&view_dragged)
		.pointer(xray::PointerShape.TEXT);
	boba::Scroller* sc = self.scroll_state();
	sc.apply(n);
	if (sc.springing || self.lead_blank > 0 || sc.top_row() != self.first_visible_row_index()) {
		self.set_top_row(sc.top_row());
	}
	if (!milktea::layout_metrics().pixels) return n;
	xray::Node* caret = self.caret_node();
	if (!caret) return n;
	return xray::zstack().add(n).add(caret);
}

fn void View.on_press(&self, ViewPressFn f, void* ctx) {
	self.on_press_fn = f;
	self.on_press_ctx = ctx;
}

fn void view_pressed(void* id, String id_str, sz col, sz row) @local {
	View* v = (View*)id;
	v.sels.clear();
	v.sels.push(caret(v.pos_at_cell(col, row)));
	v.completion.close();
	if (v.on_press_fn) v.on_press_fn(v.on_press_ctx);
}

// view_dragged moves the head of the selection the press started to where
// the pointer is, keeping its anchor. Past the top or bottom of the view it
// scrolls a row towards the pointer for each move.
fn void view_dragged(void* id, String id_str, sz col, sz row) @local {
	View* v = (View*)id;
	if (row < 0) {
		v.scroll(-1);
		row = 0;
	} else if (row >= v.height) {
		v.scroll(1);
		row = v.height - 1;
	}
	Selection s = *v.primary();
	sz head = v.pos_at_cell(col, row);
	if (head == s.head) return;
	v.sels.clear();
	v.sels.push({ .anchor = s.anchor, .head = head, .goal_col = -1 });
	v.scroll_to_caret();
}
