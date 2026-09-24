module ted::editor;

// Selection is a range of the buffer with a direction: anchor is where it
// started, head where the caret is. An empty selection is just a caret.
struct Selection {
	sz anchor;
	sz head;
	// The display column vertical moves aim for, so moving down through a
	// short line and on into a long one lands back where it started. -1 when
	// the last move was not vertical.
	int goal_col;
}

fn Selection caret(sz pos) => { .anchor = pos, .head = pos, .goal_col = -1 };

fn sz Selection.start(self) => self.anchor < self.head ? self.anchor : self.head;
fn sz Selection.end(self) => self.anchor < self.head ? self.head : self.anchor;
fn bool Selection.is_empty(self) => self.anchor == self.head;

// map carries the selection through an edit made somewhere in the buffer.
fn Selection Selection.map(self, Edit e) {
	return { .anchor = e.map(self.anchor), .head = e.map(self.head), .goal_col = -1 };
}
