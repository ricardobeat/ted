module ted::editor;

import glaze;
import xray;
import milktea;
import std::collections::list;

// Completion: as a word is typed, offer the words it could become.
//
// Where the candidates come from is the Assist's business (a language knows
// its identifiers and keywords); without one, the words already in the
// buffer serve. The editor owns the rest: when to offer, narrowing as typing
// goes on, choosing, and putting the choice in.

const int MIN_PREFIX = 2;
const int MAX_SHOWN = 8;

struct Completion {
	bool open;
	// Where the word being completed starts; it runs to the caret.
	sz start;
	List{String} items;
	// The items' text, owned here: candidates are read from a buffer that
	// the next keystroke changes.
	DString texts;
	int selected;
}

fn void Completion.init(&self) {
	self.items.init(mem);
	self.texts.init(mem);
}

fn void Completion.free(&self) {
	self.items.free();
	self.texts.free();
}

fn void Completion.close(&self) {
	self.open = false;
	self.items.clear();
	self.texts.clear();
	self.selected = 0;
}

fn bool View.completing(&self) => self.completion.open;

// word_before is the start of the word that ends at pos.
fn sz View.word_before(&self, sz pos) {
	String t = self.buf.str();
	while (pos > 0 && is_word(t[pos - 1])) pos--;
	return pos;
}

// update_completion offers completions for the word at the caret, or closes
// the list when there is nothing to offer.
fn void View.update_completion(&self) {
	Completion* c = &self.completion;
	if (self.sels.len() != 1 || !self.primary().is_empty()) {
		c.close();
		return;
	}
	sz head = self.primary().head;
	sz start = self.word_before(head);
	if (head - start < MIN_PREFIX || self.context_at(head) == COMMENT) {
		c.close();
		return;
	}
	String prefix = self.buf.str()[start:head - start];

	@pool() {
		List{String} found;
		found.init(tmem);
		if (self.assist && &self.assist.completions) {
			self.assist.completions(head, prefix, &found);
		} else {
			self.buffer_words(start, &found);
		}

		// Keep the ones that extend the prefix, each once, shortest first.
		List{String} keep;
		keep.init(tmem);
		foreach (w : found) {
			if (w.len <= prefix.len || !starts_with_nocase(w, prefix) || keep.contains(w)) continue;
			keep.push(w);
		}
		for (sz i = 1; i < keep.len(); i++) {
			for (sz j = i; j > 0 && shorter(keep[j], keep[j - 1]); j--) @swap(keep[j - 1], keep[j]);
		}

		c.close();
		if (keep.len() == 0) return;
		c.open = true;
		c.start = start;
		// All the text first, then the items as slices of it, so none is
		// taken while texts may still move.
		sz n = keep.len() < MAX_SHOWN ? keep.len() : MAX_SHOWN;
		for (sz i = 0; i < n; i++) c.texts.append(keep[i]);
		sz at = 0;
		for (sz i = 0; i < n; i++) {
			c.items.push(c.texts.str_view()[at:keep[i].len]);
			at += keep[i].len;
		}
	};
}

fn bool shorter(String a, String b) @local => a.len < b.len || (a.len == b.len && a.compare_to(b) < 0);

fn bool starts_with_nocase(String s, String prefix) @local {
	if (s.len < prefix.len) return false;
	foreach (i, c : prefix) {
		if (c.to_lower() != s[i].to_lower()) return false;
	}
	return true;
}

// buffer_words collects the buffer's words, other than the one at `skip`.
fn void View.buffer_words(&self, sz skip, List{String}* out) {
	String t = self.buf.str();
	sz i = 0;
	while (i < t.len) {
		if (!is_word(t[i])) { i++; continue; }
		sz start = i;
		while (i < t.len && is_word(t[i])) i++;
		if (start != skip) out.push(t[start:i - start]);
	}
}

// accept_completion replaces the word at the caret with the chosen item.
fn void View.accept_completion(&self) {
	Completion* c = &self.completion;
	if (!c.open || c.items.len() == 0) return;
	String item = c.items[c.selected].tcopy();
	sz head = self.primary().head;
	c.close();
	Step* step = self.history.begin(OTHER, self.sels.array_view());
	self.apply(step, c.start, head, item);
	self.sels[0] = caret(c.start + item.len);
	self.after_edit(step);
}

// completion_key handles a key while the list is open, reporting whether it
// took it.
fn bool View.completion_key(&self, milktea::KeyMsg k) {
	Completion* c = &self.completion;
	if (!c.open) return false;
	switch (k.code) {
		case UP:
			c.selected = c.selected > 0 ? c.selected - 1 : (int)c.items.len() - 1;
		case DOWN:
			c.selected = (sz)c.selected + 1 < c.items.len() ? c.selected + 1 : 0;
		case TAB:
		case ENTER:
			self.accept_completion();
		case ESC:
			c.close();
		default:
			return false;
	}
	return true;
}

// ── drawing ───────────────────────────────────────────────────────────────

// completion_node draws the open list under the caret, for the host to put
// on top of everything else; null when there is nothing to show. It is
// placed with the view's rect from the last frame.
fn xray::Node* View.completion_node(&self, glaze::Style item_style, glaze::Style selected_style) {
	Completion* c = &self.completion;
	if (!c.open || c.items.len() == 0) return null;
	int col;
	int row;
	if (!self.caret_cell(&col, &row)) return null;

	int width = 0;
	foreach (item : c.items) if ((int)glaze::string_width(item) > width) width = (int)glaze::string_width(item);
	width += 2;

	// Line the items up under the start of the word, below the caret — or
	// above it when there is no room below.
	int prefix_cols = (int)(self.primary().head - c.start);
	int x = self.rect.x + col - prefix_cols - 1;
	if (x < 0) x = 0;
	int y = self.rect.y + row + 1;
	if (y + (int)c.items.len() > self.rect.y + self.rect.h) y = self.rect.y + row - (int)c.items.len();

	xray::Node* list = milktea::vstack()
		.width(milktea::cells(width))
		.height(milktea::cells((int)c.items.len()))
		.at(x, y);
	foreach (i, item : c.items) {
		glaze::Style s = i == c.selected ? selected_style : item_style;
		list.add(milktea::text(s.pad_x(1), item).height(milktea::cells(1)));
	}
	return list;
}

// caret_cell is where the primary caret is on screen, relative to the
// view's rect; false when it is scrolled out of sight.
fn bool View.caret_cell(&self, int* col, int* row) {
	sz head = self.primary().head;
	int line = self.buf.line_of(head);
	if (line < self.top_line) return false;
	int r = 0;
	for (int l = self.top_line; l < line && r <= self.height; l++) {
		r += self.rows_in(l) - (l == self.top_line ? self.top_row : 0);
	}
	LineLayout ll;
	self.layout_line(line, self.text_width, &ll);
	int lrow;
	int c;
	ll.locate(head, &lrow, &c);
	r += lrow - (line == self.top_line ? self.top_row : 0);
	if (r < 0 || r >= self.height) return false;
	*col = self.gutter_width() + c;
	*row = r;
	return true;
}
