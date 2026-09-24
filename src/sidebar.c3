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

// BrowserSlot is the per-row id that the click handler reads to know which
// row in the file navigator was hit. The address is stable across frames
// because the slot lives on the Editor (the picker's own PickRowCtx, in
// contrast, is allocated fresh on tmem each frame).
struct BrowserSlot {
	Editor* ed;
	int index;
}

fn void browser_row_index_clicked(void* id, String id_str, int col, int row) @local {
	BrowserSlot* s = (BrowserSlot*)id;
	Editor* ed = s.ed;
	int i = s.index;
	if (i < 0 || i >= ed.browser.count) return;
	// Keep the picker's own state in sync: a click should move the keyboard
	// cursor there too, so the next arrow key continues from the same row.
	ed.browser.cursor = i;
	ed.browser.selected = i;
	String name = (String)ed.browser.names[i][:ed.browser.name_lens[i]];
	browser_row_clicked(ed, name, ed.browser.is_dirs[i], col, row);
}

fn void browser_row_hover_in(void* id, String id_str, int col, int row) @local {
	BrowserSlot* s = (BrowserSlot*)id;
	s.ed.browser_hover = s.index;
}

fn void browser_row_hover_out(void* id, String id_str, int col, int row) @local {
	BrowserSlot* s = (BrowserSlot*)id;
	if (s.ed.browser_hover == s.index) s.ed.browser_hover = -1;
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
// is its own node with on_click + on_hover_in/out; the file-navigator rows are
// the same shape, so UP/DOWN read as one continuous list. The editor view's
// on_press hooks the editor body so a click there focuses it. Focus is not
// consulted anywhere — clicks work from any state.
//
// The file-navigator rows are rendered in ted rather than via the picker's
// own tree_node(). The picker draws its cursor row with a `> ` caret in its
// own magenta style; the sidebar wants the cursor row to use the same accent
// highlight as the active file row, with no caret prefix — the two panels
// reading as one list means the highlight rules should be the same too.
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
		// The ▸ marker on the active file is always shown — the user needs to
		// see which file is in the editor from anywhere. The accent highlight,
		// though, belongs to the sidebar's keyboard cursor, which lives in
		// only one panel at a time: the open files panel when focus is on
		// it, the file-navigator otherwise. Highlighting both rows at once
		// would say "two things are selected" and confuse the arrows.
		bool files_active = ed.focus == FOCUS_SIDEBAR_FILES;
		for (int i = 0; i < ed.open_file_count; i++) {
			OpenFile* f = &ed.open_files[i];
			String path = (String)f.path_buf[:f.path_len];
			String name = sidebar_basename(path);
			bool is_current = i == ed.active_file;
			String prefix = is_current ? SIDEBAR_MARK : SIDEBAR_PAD;
			String mark = (is_current && ed.modified) ? " [+]" : "";
			String text = string::tformat("%s%s%s", prefix, name, mark);
			glaze::Style* s;
			if (files_active && is_current) { s = &file_row_focused; }
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

	// File-navigator header + rows. The picker's own tree_node() is not used:
	// its title and the cursor's `> ` marker do not fit the sidebar's shared
	// accent highlight, and the row click goes through ted's own BrowserSlot
	// so it can apply the same focus logic as the open-files panel above.
	sidebar_add_browser(ed, v, &bg, &file_row, &file_row_hover, &file_row_focused);

	return v;
}

// sidebar_add_browser appends the "Files" header and one row per visible file
// to the sidebar tree. Visible rows come from the picker's scroll/cursor
// reconciliation, the same rules its own tree_node() follows. The cursor
// row takes the same file_row_focused style as the active file above, so
// the two panels read as a single highlighted list.
fn void sidebar_add_browser(Editor* ed, xray::Node* v,
		glaze::Style* bg, glaze::Style* file_row,
		glaze::Style* file_row_hover, glaze::Style* file_row_focused) @local {
	Theme* th = &ed.theme;
	String header = string::tformat(" Files: %s", ed.browser.current_dir);
	v.add(milktea::text(*bg, header).height(milktea::cells(1)));

	// The picker's tree_node() reserves 4 rows for title + hint + padding;
	// the sidebar's header here replaces the title, so visible rows are the
	// height minus 1 (hint) minus padding rows when the directory is short.
	int visible = ed.browser.height - 4;
	if (visible < 1) visible = 1;
	// Reconcile scroll with cursor: picker's own tree_node() does the same.
	if (ed.browser.cursor < ed.browser.scroll) ed.browser.scroll = ed.browser.cursor;
	if (ed.browser.cursor >= ed.browser.scroll + visible) {
		ed.browser.scroll = ed.browser.cursor - visible + 1;
	}
	int end = ed.browser.scroll + visible;
	if (end > ed.browser.count) end = ed.browser.count;

	// Same rule as the open-files panel above: the accent highlight follows
	// the sidebar's keyboard cursor, which lives in one panel at a time.
	// When focus is on the files panel the browser row stays plain, and vice
	// versa — two highlighted rows would read as two selections.
	bool browser_active = ed.focus == FOCUS_SIDEBAR_BROWSER;
	for (int i = ed.browser.scroll; i < end; i++) {
		String name = (String)ed.browser.names[i][:ed.browser.name_lens[i]];
		String suffix = ed.browser.is_dirs[i] ? "/" : "";
		bool is_cursor = i == ed.browser.cursor;
		bool is_hover = i == ed.browser_hover;
		glaze::Style* s;
		if (browser_active && is_cursor) { s = file_row_focused; }
		else if (is_hover) { s = file_row_hover; }
		else { s = file_row; }
		String text = string::tformat("%s%s%s", SIDEBAR_PAD, name, suffix);
		ed.browser_slots[i] = { .ed = ed, .index = i };
		xray::Node* row = milktea::text(*s, text).height(milktea::cells(1));
		row.id_with(&ed.browser_slots[i])
			.on_click(&browser_row_index_clicked)
			.on_hover_in(&browser_row_hover_in)
			.on_hover_out(&browser_row_hover_out);
		v.add(row);
	}
	// Pad with blank rows so the sidebar keeps its height when the directory
	// is shorter than the slot — without this, the status bar would slide up.
	int pad = visible - (end - ed.browser.scroll);
	for (int i = 0; i < pad; i++) {
		v.add(milktea::text(*bg, "").height(milktea::cells(1)));
	}
	glaze::Style hint_style = { .fg = th.dim };
	v.add(milktea::text(hint_style, "Enter: open  Backspace: parent")
		.height(milktea::cells(1)));
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
	ed.browser_hover = -1;
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
