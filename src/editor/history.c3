module ted::editor;

import std::collections::list;

// History is undo and redo. Each step is one user action — a keystroke's
// worth, or a run of them: consecutive typing, or consecutive deleting,
// merges into one step until something else happens (a caret move, a
// different kind of edit), the way editors usually group undo.
//
// A step keeps the text each change removed and inserted, and the
// selections from before and after, so undoing puts the caret back where it
// was too.

enum EditKind : char {
	OTHER,
	TYPING,
	DELETING,
}

struct Change {
	sz at;
	// Ranges of the step's texts: what the change removed, and what it put
	// in its place.
	sz removed_at;
	sz removed_len;
	sz inserted_at;
	sz inserted_len;
}

struct Step {
	EditKind kind;
	List{Change} changes;
	DString texts;
	List{Selection} before;
	List{Selection} after;
}

struct History {
	List{Step} done;
	List{Step} undone;
	// Set when the last step may take more edits of its kind.
	bool open;
}

fn void History.init(&self) {
	self.done.init(mem);
	self.undone.init(mem);
}

fn void Step.free(&self) {
	self.changes.free();
	self.texts.free();
	self.before.free();
	self.after.free();
}

fn void History.clear(&self) {
	foreach (&s : self.done) s.free();
	foreach (&s : self.undone) s.free();
	self.done.clear();
	self.undone.clear();
	self.open = false;
}

fn void History.free(&self) {
	self.clear();
	self.done.free();
	self.undone.free();
}

// seal ends the current step, so the next edit starts a new one.
fn void History.seal(&self) {
	self.open = false;
}

// begin starts recording an action of this kind, joining the last step when
// it is still open for the same kind.
fn Step* History.begin(&self, EditKind kind, Selection[] sels) {
	foreach (&s : self.undone) s.free();
	self.undone.clear();
	if (self.open && kind != OTHER && self.done.len() > 0 && self.done[self.done.len() - 1].kind == kind) {
		return &self.done[self.done.len() - 1];
	}
	Step step = { .kind = kind };
	step.changes.init(mem);
	step.texts.init(mem);
	step.before.init(mem);
	step.after.init(mem);
	foreach (s : sels) step.before.push(s);
	self.done.push(step);
	self.open = kind != OTHER;
	return &self.done[self.done.len() - 1];
}

fn void Step.record(&self, sz at, String removed, String inserted) {
	Change c = { .at = at, .removed_at = self.texts.len(), .removed_len = removed.len };
	self.texts.append(removed);
	c.inserted_at = self.texts.len();
	c.inserted_len = inserted.len;
	self.texts.append(inserted);
	self.changes.push(c);
}

fn void Step.finish(&self, Selection[] sels) {
	self.after.clear();
	foreach (s : sels) self.after.push(s);
}

fn String Step.removed(&self, Change* c) => self.texts.str_view()[c.removed_at:c.removed_len];
fn String Step.inserted(&self, Change* c) => self.texts.str_view()[c.inserted_at:c.inserted_len];
