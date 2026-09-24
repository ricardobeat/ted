module ted::editor;

import glaze;
import xray;
import milktea;
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
	List{Selection} sels;
	List{Layer} layers;
	History history;
	// Language knowledge, when there is some: see Assist.
	Assist assist;
	// Brackets and quotes that pair up as they are typed, openers and
	// closers alternating.
	List{String} pairs;

	// Scroll position: the first line on screen, and how many of its wrapped
	// rows are above the top.
	int top_line;
	int top_row;
	// The text area's size at the last render, in cells, for commands that
	// move by a screenful.
	int text_width;
	int height;

	bool focused;
	bool wrap;
	bool line_numbers;
	int tab_width;
	// What Tab inserts and indent/dedent add or remove.
	String indent_unit;

	glaze::Style text_style;
	glaze::Style gutter_style;
	glaze::Style gutter_current_style;
	glaze::Style selection_style;
	// A caret other than the primary one, which the terminal draws.
	glaze::Style caret_style;
	milktea::CursorStyle caret;

	// Fired when a press lands in the view, after it has moved the caret.
	ViewPressFn on_press_fn;
	void* on_press_ctx;
}

alias ViewPressFn = fn void(void* ctx);

// NO_POS marks a glyph that stands for no byte of the buffer.
const sz NO_POS = (sz)-1;

struct Glyph {
	String text;
	int width;
	sz pos;
	glaze::Style style;
}

// Row is one screen row of a line: glyphs [first, first + count).
struct Row {
	sz first;
	sz count;
	int width;
}

struct LineLayout {
	int line;
	List{Glyph} glyphs;
	List{Row} rows;
}

fn void View.init(&self) {
	self.buf.init();
	self.sels.init(mem);
	self.sels.push(caret(0));
	self.layers.init(mem);
	self.history.init();
	self.pairs.init(mem);
	self.set_pairs(&DEFAULT_PAIRS);
	self.text_width = 80;
	self.height = 24;
	self.wrap = true;
	self.line_numbers = true;
	self.tab_width = 4;
	self.indent_unit = "    ";
}

fn void View.free(&self) {
	self.buf.free();
	self.sels.free();
	foreach (&l : self.layers) l.free();
	self.layers.free();
	self.history.free();
	self.pairs.free();
}

// set_text replaces the whole document, as opening a file does: the caret
// goes to the top, decorations and history start over.
fn void View.set_text(&self, String s) {
	self.buf.set_text(s);
	self.sels.clear();
	self.sels.push(caret(0));
	foreach (&l : self.layers) l.clear();
	self.history.clear();
	self.top_line = 0;
	self.top_row = 0;
}

fn String View.text(&self) => self.buf.str();
fn Selection* View.primary(&self) => &self.sels[0];

// layer returns the layer with this name, making it on first use.
fn Layer* View.layer(&self, String name, int order = 0) {
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
fn void View.caret_line_col(&self, int* line, int* col) {
	sz head = self.primary().head;
	*line = self.buf.line_of(head);
	String before = self.buf.str()[self.buf.line_start(*line):head - self.buf.line_start(*line)];
	int n = 0;
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
			out.glyphs.push({ .text = t, .width = (int)glaze::string_width(t), .pos = NO_POS,
				.style = overlay(self.text_style, d.style) });
		}
	}
}

// layout_line lays out one line at the given text width: its glyphs, and the
// rows they wrap into. The lists come from temp memory.
fn void View.layout_line(&self, int line, int width, LineLayout* out) {
	out.line = line;
	out.glyphs.init(tmem);
	out.rows.init(tmem);
	String text = self.buf.str();
	sz start = self.buf.line_start(line);
	sz end = self.buf.line_end(line);

	int col = 0;
	sz pos = start;
	while (pos < end) {
		self.push_inlines(out, pos);
		glaze::Style s = self.style_at(pos);
		if (self.selected(pos)) s = overlay(s, self.selection_style);
		if (self.is_secondary_caret(pos)) s = overlay(s, self.caret_style);
		sz n = glaze::utf8_sequence_len(text, pos);
		if (text[pos] == '\t') {
			int w = self.tab_width - col % self.tab_width;
			out.glyphs.push({ .text = "        "[:w], .width = w, .pos = pos, .style = s });
			col += w;
		} else {
			int w = glaze::utf8_width_at(text, pos);
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
fn void View.wrap_rows(&self, LineLayout* out, int width) {
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
fn void LineLayout.locate(&self, sz pos, int* row, int* col) {
	for (sz r = 0; r < self.rows.len(); r++) {
		Row* rw = &self.rows[r];
		int c = 0;
		for (sz i = rw.first; i < rw.first + rw.count; i++) {
			if (self.glyphs[i].pos == pos) {
				*row = (int)r;
				*col = c;
				return;
			}
			c += self.glyphs[i].width;
		}
	}
	// Not a glyph: the end of the line.
	*row = (int)self.rows.len() - 1;
	*col = self.rows[self.rows.len() - 1].width;
}

// pos_at finds the byte a column of a row stands for: the glyph under it,
// or the next real one after a hint, or the line's end past the text.
fn sz LineLayout.pos_at(&self, int row, int col, sz line_end) {
	Row* rw = &self.rows[row];
	int c = 0;
	for (sz i = rw.first; i < self.glyphs.len(); i++) {
		Glyph* g = &self.glyphs[i];
		bool past_row = i >= rw.first + rw.count;
		if (g.pos != NO_POS && (past_row || c + g.width > col)) return g.pos;
		if (!past_row) c += g.width;
	}
	return line_end;
}

// ── scrolling ─────────────────────────────────────────────────────────────

fn int View.gutter_width(&self) {
	if (!self.line_numbers) return 0;
	int digits = 1;
	for (int n = self.buf.line_count(); n >= 10; n /= 10) digits++;
	if (digits < 3) digits = 3;
	return digits + 2;
}

fn int View.rows_in(&self, int line) {
	LineLayout ll;
	self.layout_line(line, self.text_width, &ll);
	return (int)ll.rows.len();
}

// scroll_to_caret moves the view the least that brings the primary caret on
// screen.
fn void View.scroll_to_caret(&self) {
	@pool() {
		sz head = self.primary().head;
		int line = self.buf.line_of(head);
		LineLayout ll;
		self.layout_line(line, self.text_width, &ll);
		int row;
		int col;
		ll.locate(head, &row, &col);

		if (line < self.top_line || (line == self.top_line && row < self.top_row)) {
			self.top_line = line;
			self.top_row = row;
			return;
		}
		// Rows from the top of the screen down to the caret, counted only as
		// far as a screenful.
		int above = row - (line == self.top_line ? self.top_row : 0);
		for (int l = line - 1; l >= self.top_line && above < self.height; l--) {
			above += l == self.top_line ? self.rows_in(l) - self.top_row : self.rows_in(l);
		}
		if (above < self.height) return;
		// Below the screen: count a screenful up from the caret, so it lands
		// on the bottom row.
		int l = line;
		int r = row;
		for (int up = self.height - 1; up > 0; up--) {
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

// scroll moves the view by rows without moving the caret, as a wheel does.
fn void View.scroll(&self, int rows) {
	@pool() {
		while (rows > 0) {
			int left = self.rows_in(self.top_line) - self.top_row;
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

fn String spaces(int n) @local {
	DString d = dstring::temp();
	for (int i = 0; i < n; i++) d.append_char(' ');
	return d.str_view();
}

fn String pad_left(String s, int width) @local {
	return width > s.len ? string::tformat("%s%s", spaces(width - (int)s.len), s) : s;
}

fn bool same_style(glaze::Style* a, glaze::Style* b) @local {
	return mem::equals(a, b, @sizeof(*a));
}

fn String View.render(&self, xray::Rect r) @dynamic {
	int gutter = self.gutter_width();
	self.text_width = r.w - gutter;
	self.height = r.h;
	if (self.text_width < 1) self.text_width = 1;
	int caret_line = self.buf.line_of(self.primary().head);

	DString out = dstring::temp();
	int drawn = 0;
	for (int line = self.top_line; line < self.buf.line_count() && drawn < r.h; line++) {
		LineLayout ll;
		self.layout_line(line, self.text_width, &ll);
		for (sz ri = line == self.top_line ? self.top_row : 0; ri < ll.rows.len() && drawn < r.h; ri++) {
			if (drawn > 0) out.append_char('\n');
			if (gutter > 0) {
				glaze::Style gs = line == caret_line ? self.gutter_current_style : self.gutter_style;
				String num = ri == 0 ? pad_left(string::tformat("%d  ", line + 1), gutter) : spaces(gutter);
				out.append_string(gs.render(num));
			}
			Row* row = &ll.rows[ri];
			// Runs of glyphs in the same style go out as one styled string.
			sz i = row.first;
			while (i < row.first + row.count) {
				DString run = dstring::temp();
				glaze::Style* s = &ll.glyphs[i].style;
				while (i < row.first + row.count && same_style(&ll.glyphs[i].style, s)) {
					run.append_string(ll.glyphs[i].text);
					i++;
				}
				out.append_string(s.render(run.str_view()));
			}
			int pad = self.text_width - row.width;
			if (pad > 0) out.append_string(self.text_style.render(spaces(pad)));
			drawn++;
		}
	}
	// Past the end of the document the view is blank, in the text's colors.
	for (; drawn < r.h; drawn++) {
		if (drawn > 0) out.append_char('\n');
		out.append_string(self.text_style.render(spaces(r.w)));
	}
	return out.str_view();
}

fn int View.measure(&self, int width) @dynamic => self.buf.line_count();
fn int View.measure_width(&self, int height) @dynamic => self.text_width + self.gutter_width();

// cursor puts the terminal's caret on the primary selection's head.
fn xray::ContentCursor View.cursor(&self, xray::Rect r) @dynamic {
	if (!self.focused) return {};
	sz head = self.primary().head;
	int line = self.buf.line_of(head);
	if (line < self.top_line) return {};
	int row = 0;
	for (int l = self.top_line; l < line && row <= r.h; l++) {
		row += self.rows_in(l) - (l == self.top_line ? self.top_row : 0);
	}
	LineLayout ll;
	self.layout_line(line, self.text_width, &ll);
	int lrow;
	int col;
	ll.locate(head, &lrow, &col);
	row += lrow - (line == self.top_line ? self.top_row : 0);
	return xray::place_cursor(r, self.gutter_width() + col, row, self.caret);
}

// pos_at_cell is the buffer position under a cell of the view.
fn sz View.pos_at_cell(&self, int col, int row) {
	col -= self.gutter_width();
	if (col < 0) col = 0;
	int line = self.top_line;
	int skip = self.top_row + row;
	@pool() {
		while (line < self.buf.line_count()) {
			LineLayout ll;
			self.layout_line(line, self.text_width, &ll);
			if (skip < ll.rows.len()) return ll.pos_at(skip, col, self.buf.line_end(line));
			skip -= (int)ll.rows.len();
			line++;
		}
	};
	return self.buf.len();
}

fn xray::Node* View.node(&self) {
	return xray::content_node(self).id_with(self).on_click(&view_pressed);
}

fn void View.on_press(&self, ViewPressFn f, void* ctx) {
	self.on_press_fn = f;
	self.on_press_ctx = ctx;
}

fn void view_pressed(void* id, String id_str, int col, int row) @local {
	View* v = (View*)id;
	v.sels.clear();
	v.sels.push(caret(v.pos_at_cell(col, row)));
	if (v.on_press_fn) v.on_press_fn(v.on_press_ctx);
}
