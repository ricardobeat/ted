module ted::editor;

// Assist is what the editor asks of whoever knows the language of its text:
// whether a position is in code, a string or a comment, and which tag a
// just-finished start tag should be closed with. The editor knows nothing
// about languages itself; without an assist every position is code and no
// tags are closed. Which brackets pair is the view's own list (set_pairs).
interface Assist {
	fn Context context_at(sz pos) @optional;
	fn String? tag_to_close(sz pos) @optional;
}

enum Context : char {
	CODE,
	STRING,
	COMMENT,
}

// The pairs a view starts with, and goes back to for a language that names
// none of its own: openers and closers, alternating.
const String[12] DEFAULT_PAIRS = { "(", ")", "[", "]", "{", "}", "\"", "\"", "'", "'", "`", "`" };

// set_pairs replaces the brackets and quotes that pair up; empty turns
// pairing off.
fn void View.set_pairs(&self, String[] pairs) {
	self.pairs.clear();
	foreach (p : pairs) self.pairs.push(p);
}

fn Context View.context_at(&self, sz pos) {
	if (self.assist && &self.assist.context_at) return self.assist.context_at(pos);
	return CODE;
}

// closer_for is the closer that pairs with an opener, if s is one.
fn String? View.closer_for(&self, String s) {
	for (sz i = 0; i + 1 < self.pairs.len(); i += 2) {
		if (self.pairs[i] == s) return self.pairs[i + 1];
	}
	return NOT_PAIRED~;
}

fn bool View.is_closer(&self, String s) {
	for (sz i = 1; i < self.pairs.len(); i += 2) {
		if (self.pairs[i] == s) return true;
	}
	return false;
}

faultdef NOT_PAIRED;

// type_text is typing: it inserts like insert_text, with the conveniences
// an editor adds around brackets and quotes —
//
//  - an opener typed in code, before whitespace, a closer or the end of the
//    line, brings its closer, the caret between them;
//  - a closer typed right before the same closer steps over it;
//  - an opener typed with text selected wraps the selection;
//  - a quote after a word character (it's) is only a quote;
//
// and, after the > that finishes a start tag, the tag's end tag.
fn void View.type_text(&self, String text) {
	String? close = self.closer_for(text);
	@pool() {
		Step* step = self.history.begin(TYPING, self.sels.array_view());
		foreach (i : self.order_desc()) {
			Selection s = self.sels[i];
			String t = self.buf.str();
			String next = s.end() < t.len ? t[s.end():next_char(t, s.end()) - s.end()] : "";

			if (s.is_empty() && self.is_closer(text) && next == text) {
				// Step over the closer already there.
				self.sels[i] = caret(s.head + text.len);
				continue;
			}
			if (try c = close) {
				if (!s.is_empty()) {
					// Wrap: closer first, so the opener's offset still holds.
					self.apply(step, s.end(), s.end(), c);
					self.apply(step, s.start(), s.start(), text);
					sz start = s.start() + text.len;
					sz end = s.end() + text.len;
					self.sels[i] = s.anchor <= s.head ? { .anchor = start, .head = end, .goal_col = -1 }
						: { .anchor = end, .head = start, .goal_col = -1 };
					continue;
				}
				if (self.should_pair(s.head, text, next)) {
					self.apply(step, s.head, s.head, string::tformat("%s%s", text, c));
					self.sels[i] = caret(s.head + text.len);
					continue;
				}
			}
			self.apply(step, s.start(), s.end(), text);
			self.sels[i] = caret(s.start() + text.len);
		}
		if (text == ">") self.close_tags(step);
		self.after_edit(step);
	};
}

fn bool View.should_pair(&self, sz pos, String open, String next) {
	if (self.context_at(pos) != CODE) return false;
	// Only where nothing would end up inside the pair unintentionally.
	bool free = next.len == 0 || next == " " || next == "\t" || next == "\n" || self.is_closer(next);
	if (!free) return false;
	// A quote right after a word is an apostrophe or a suffix, not a string.
	String? c = self.closer_for(open);
	if (try cl = c) {
		if (cl == open && pos > 0 && is_word(self.buf.str()[pos - 1])) return false;
	}
	return true;
}

// close_tags adds the end tag after each caret that has just finished a
// start tag.
fn void View.close_tags(&self, Step* step) {
	if (!self.assist || !&self.assist.tag_to_close) return;
	foreach (i : self.order_desc()) {
		Selection s = self.sels[i];
		if (!s.is_empty()) continue;
		String? tag = self.assist.tag_to_close(s.head);
		if (catch tag) continue;
		self.apply(step, s.head, s.head, string::tformat("</%s>", tag));
		self.sels[i] = caret(s.head);
	}
}

// pair_around is the length of an empty pair around pos — an opener just
// before and its closer just after — or 0.
fn sz View.pair_around(&self, sz pos) {
	String t = self.buf.str();
	if (pos == 0 || pos >= t.len) return 0;
	String prev = t[prev_char(t, pos):pos - prev_char(t, pos)];
	String next = t[pos:next_char(t, pos) - pos];
	if (try c = self.closer_for(prev)) {
		if (c == next) return prev.len;
	}
	return 0;
}
