module ted;

import milktea;
import glaze;
import xray;
import boba;
import std::io;
import std::core::string;
import std::core::dstring;

const int SIDEBAR_WIDTH = 28;
// Cells between the panel's border and the text in it. One is enough to keep
// the names off the rule; the cursor marker takes this cell on the row it is
// on, so marked and unmarked rows still start in the same column.
const String SIDEBAR_PAD = " ";
const String SIDEBAR_MARK = "▸";

fn String sidebar_basename(String path) {
	sz last = 0;
	bool found = false;
	for (sz i = 0; i < path.len; i++) {
		if (path[i] == '/') { last = i; found = true; }
	}
	if (found && last + 1 < path.len) return path[last + 1..];
	return path;
}

// ── File-row click context ───────────────────────────────────────────────────
//
// Each open-file row in the sidebar owns one FileSlot, registered into the
// node tree's click context via .id_with(&slot). The static handlers below
// read the slot to figure out which file was clicked and what to do with it,
// without the click site needing any layout math — the framework passes
// rect-local cell coordinates, but the slot's index is the row's identity.
//
// The same code runs in the terminal and the GUI: milktea parses mouse input
// and dispatches clicks/hover in both, so a `$feat(MILKTEA_GUI)` gate around
// any of these would split behaviour the library already unifies.

struct FileSlot {
	Editor* ed;
	int index;
}

fn void file_row_clicked(void* id, String id_str, int col, int row) @local {
	FileSlot* s = (FileSlot*)id;
	s.ed.activate_file(s.index);
	// A click on a list row is also what puts the keyboard on that list, the
	// way it does in any desktop app: the arrows then move the selection the
	// user just clicked, instead of editing the file behind it.
	s.ed.focus = FOCUS_SIDEBAR_FILES;
}

fn void file_row_hover_in(void* id, String id_str, int col, int row) @local {
	FileSlot* s = (FileSlot*)id;
	s.ed.file_hover = s.index;
}

fn void file_row_hover_out(void* id, String id_str, int col, int row) @local {
	FileSlot* s = (FileSlot*)id;
	if (s.ed.file_hover == s.index) s.ed.file_hover = -1;
}

// ── Browser click handler ────────────────────────────────────────────────────
//
// The FilePicker fires on_row_click for any visible row; we just decide what
// to do with the (name, is_dir) tuple it hands us — open the file or navigate
// into the directory. The picker takes care of updating its own cursor and
// selected state, and the framework wires on_hover_in/out internally so the
// hover highlight follows the pointer without any work on our side. Which
// panel the keyboard ends up on follows from what the click meant: opening a
// file is editing, navigating a directory is browsing.

fn void browser_row_clicked(void* id, String name, bool is_dir, int col, int row) @local {
	Editor* ed = (Editor*)id;
	if (is_dir) {
		String path = ed.browser.current_dir;
		String full = string::tformat("%s/%s", path, name);
		ed.browser.load_dir(full);
		ed.status_msg = string::tformat("Open dir: %s", full);
		// Browsing a directory is work in the browser, so the keyboard stays
		// there for the arrows that follow. Opening a file below is the
		// opposite case: that is work in the editor.
		ed.focus = FOCUS_SIDEBAR_BROWSER;
	} else {
		String path = ed.browser.current_dir;
		String full = string::tformat("%s/%s", path, name);
		// Match load_file's behaviour: it opens (or activates if already open)
		// the file at full path, focusing the editor.
		ed.load_file(full);
		ed.focus_editor();
	}
}

// ── Textarea press handler ──────────────────────────────────────────────────
//
// A click inside the editor body puts the caret where it landed — the view
// does that itself — and focuses the editor, so the click is one action from
// the user's side: clicking the text is how you start editing at that spot.

fn void editor_pressed(void* id) @local {
	Editor* ed = (Editor*)id;
	ed.focus_editor();
}

// ── Render ──────────────────────────────────────────────────────────────────
//
// The sidebar is one tree in either build, so the terminal and the GUI see the
// same rows with the same highlights — the active file, the focused section,
// and the hover tint under the pointer. Clicks and hovers travel through
// milktea's mouse dispatcher in both backends; nothing here is platform-gated.
//
// Hover is a faint tint and nothing more: the accent row belongs to the file
// the editor is showing. The two reading the same was worse than no hover at
// all — a row under the pointer looked selected, so the selection moving with
// the arrows was invisible, and the arrows looked broken.
//
// FileSlot is held on the Editor rather than as a tnew per frame, so the
// address stays stable across frames even though the node tree is rebuilt
// each view() call. MAX_OPEN_FILES caps both the slot array and the active
// files list; the unused slots at the tail of file_slots[] are simply left
// uninitialised, which is harmless — only rows that exist in the open-files
// list ever carry a click handler.

// sidebar_tree builds the sidebar as a clickable node tree. Each open-file row
// is its own node with on_click + on_hover_in/out; the browser is the picker's
// own tree_node() (which exposes per-row clicks the same way). The editor
// view's on_press hooks the editor body so a click there focuses it. Focus
// is not consulted anywhere — clicks work from any state.
fn xray::Node* sidebar_tree(Editor* ed) {
	Theme* th = &ed.theme;
	glaze::Style bg = { .bg = th.browser_bg, .fg = th.browser_fg };
	glaze::Style file_row = { .fg = th.browser_fg };
	glaze::Style file_row_hover = { .fg = th.text, .bg = th.selection };
	glaze::Style file_row_focused = {
		.fg = th.ink, .bg = th.accent, .bold = true,
	};

	xray::Node* v = xray::vstack().width(milktea::cells(SIDEBAR_WIDTH));

	// "Open" header
	v.add(milktea::text(bg, section_header(th, "Open"))
		.height(milktea::cells(1)));

	// Open-file rows.
	if (ed.open_file_count == 0) {
		glaze::Style empty_row = { .fg = th.dim };
		v.add(milktea::text(empty_row, string::tformat("%s(none)", SIDEBAR_PAD))
			.height(milktea::cells(1)));
	} else {
		for (int i = 0; i < ed.open_file_count; i++) {
			OpenFile* f = &ed.open_files[i];
			String path = (String)f.path_buf[:f.path_len];
			String name = sidebar_basename(path);
			bool is_current = i == ed.active_file;
			String prefix = is_current ? SIDEBAR_MARK : SIDEBAR_PAD;
			String mark = (is_current && ed.modified) ? " [+]" : "";
			String text = string::tformat("%s%s%s", prefix, name, mark);
			// Highlight choice: the file the editor is showing always takes
			// the accent; the row under the pointer gets a faint tint, and
			// only when it is not that file — a hover must never be mistaken
			// for the selection, or the arrows look like they do nothing.
			glaze::Style* s;
			if (is_current) { s = &file_row_focused; }
			else if (i == ed.file_hover) { s = &file_row_hover; }
			else { s = &file_row; }
			ed.file_slots[i] = { .ed = ed, .index = i };
			xray::Node* row = milktea::text(*s, text).height(milktea::cells(1));
			row.id_with(&ed.file_slots[i])
				.on_click(&file_row_clicked)
				.on_hover_in(&file_row_hover_in)
				.on_hover_out(&file_row_hover_out);
			v.add(row);
		}
	}

	v.add(milktea::text(bg, "").height(milktea::cells(1)));

	// "Files" header + browser tree.
	v.add(milktea::text(bg, section_header(th, "Files"))
		.height(milktea::cells(1)));
	v.add(ed.browser.tree_node().width(milktea::cells(SIDEBAR_WIDTH)));

	return v;
}

// sidebar_node is the panel the sidebar is drawn as in both backends. It is
// always the clickable tree — the terminal routes the same mouse messages
// through the same framework, so a styled-string fallback would just split
// behaviour for no reason. The panel border would frame a single string, not
// a tree, so it is left off: the sidebar stands on its own background instead.
// (A border can come back once xray can frame an arbitrary node tree.)
fn xray::Node* sidebar_node(Editor* ed) {
	return sidebar_tree(ed);
}

// sidebar_init wires the click handlers every interactive node needs. Called
// once from Editor.init(). It runs in both builds: the terminal parses
// mouse events and dispatches them through the same framework the GUI does,
// so any handler registered here fires identically in either backend.
fn void sidebar_init(Editor* ed) {
	ed.file_hover = -1;
	ed.browser.on_row_click(&browser_row_clicked, ed);
	ed.doc.on_press(&editor_pressed, ed);
}

// section_header renders a section label followed by a dim rule that fills
// the panel, so the sidebar reads as two labelled groups instead of running
// the titles into the lists below them.
fn String section_header(Theme* th, String label) {
	glaze::Style title = { .fg = th.accent, .bold = true };
	glaze::Style rule = { .fg = th.border };
	String head = string::tformat("%s%s ", SIDEBAR_PAD, label);
	int fill = SIDEBAR_WIDTH - 2 - glaze::string_width(head);

	DString out = dstring::temp();
	out.append_string(title.render(head));
	if (fill > 0) {
		DString dashes = dstring::temp();
		for (int i = 0; i < fill; i++) dashes.append_string("─");
		out.append_string(rule.render(dashes.str_view()));
	}
	return out.str_view();
}
