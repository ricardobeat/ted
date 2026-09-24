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

struct FileSlot {
	Editor* ed;
	int index;
}

fn void file_row_clicked(void* id, String id_str, int col, int row) @feat(MILKTEA_GUI) @local {
	FileSlot* s = (FileSlot*)id;
	s.ed.activate_file(s.index);
	// A click on a list row is also what puts the keyboard on that list, the
	// way it does in any desktop app: the arrows then move the selection the
	// user just clicked, instead of editing the file behind it.
	s.ed.focus = FOCUS_SIDEBAR_FILES;
}

fn void file_row_hover_in(void* id, String id_str, int col, int row) @feat(MILKTEA_GUI) @local {
	FileSlot* s = (FileSlot*)id;
	s.ed.file_hover = s.index;
}

fn void file_row_hover_out(void* id, String id_str, int col, int row) @feat(MILKTEA_GUI) @local {
	FileSlot* s = (FileSlot*)id;
	if (s.ed.file_hover == s.index) s.ed.file_hover = -1;
}

// ── Browser click handler ────────────────────────────────────────────────────
//
// The FilePicker fires on_row_click for any visible row; we just decide what
// to do with the (name, is_dir) tuple it hands us — open the file or navigate
// into the directory. The picker takes care of updating its own cursor and
// selected state, and the GUI loop wires on_hover_in/out internally so the
// hover highlight follows the pointer without any work on our side. Which
// panel the keyboard ends up on follows from what the click meant: opening a
// file is editing, navigating a directory is browsing.

fn void browser_row_clicked(void* id, String name, bool is_dir, int col, int row) @feat(MILKTEA_GUI) @local {
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

fn void editor_pressed(void* id) @feat(MILKTEA_GUI) @local {
	Editor* ed = (Editor*)id;
	ed.focus_editor();
}

// ── Terminal render ─────────────────────────────────────────────────────────
//
// The terminal build gets the sidebar as a single styled string — no per-row
// click wiring because the terminal event loop already routes keys through
// the focus system. The GUI build replaces this with sidebar_tree() below.

fn String render_sidebar(Editor* ed) {
	Theme* th = &ed.theme;

	glaze::Style bg = { .bg = th.browser_bg, .fg = th.browser_fg };
	glaze::Style file_row = { .fg = th.browser_fg };
	glaze::Style empty_row = { .fg = th.dim };
	glaze::Style file_row_focused = {
		.fg = th.ink, .bg = th.accent, .bold = true,
	};

	DString out = dstring::temp();

	// ─ Open files ─
	out.append_string(section_header(th, "Open"));
	out.append_char('\n');

	bool files_active = ed.focus == FOCUS_SIDEBAR_FILES;
	if (ed.open_file_count == 0) {
		String empty = string::tformat("%s(none)", SIDEBAR_PAD);
		// The placeholder is the only row this section has, so it takes the
		// focus highlight. With nothing highlighted the sidebar would give no
		// sign that it is the focused panel.
		out.append_string(files_active
			? focus_row(file_row_focused, empty)
			: empty_row.render(empty));
		out.append_char('\n');
	} else {
		for (int i = 0; i < ed.open_file_count; i++) {
			OpenFile* f = &ed.open_files[i];
			String path = (String)f.path_buf[:f.path_len];
			String name = sidebar_basename(path);
			bool is_current = i == ed.active_file;
			String prefix = is_current ? SIDEBAR_MARK : SIDEBAR_PAD;
			String mark = (is_current && ed.modified) ? " [+]" : "";
			String text = string::tformat("%s%s%s", prefix, name, mark);
			// Only the active file is highlighted, and only while this section
			// holds the focus.
			out.append_string(files_active && is_current
				? focus_row(file_row_focused, text)
				: file_row.render(text));
			out.append_char('\n');
		}
	}

	out.append_char('\n');

	// ─ Browser ─
	out.append_string(section_header(th, "Files"));
	out.append_char('\n');

	// Reuse the file picker's view() but re-style the cursor line to use a
	// colored background when the Files section is focused.
	DString lines = dstring::temp();
	String raw = ed.browser.view();
	sz start = 0;
	bool browser_active = ed.focus == FOCUS_SIDEBAR_BROWSER;
	// The picker renders from its own scroll offset, so the cursor's row on
	// screen is its distance from there, not its index in the directory.
	int cursor_row = ed.browser.cursor - ed.browser.scroll;
	int visible_idx = 0;
	for (sz i = 0; i <= raw.len; i++) {
		if (i == raw.len || raw[i] == '\n') {
			String line = raw[start:i - start];
			String plain = strip_ansi(line);
			// Skip the picker's own header and footer; the sidebar labels the
			// section itself.
			if (plain.starts_with("Files:")
				|| plain.starts_with("Enter:")
				|| plain.starts_with("Backspace:")) {
				start = i + 1;
				continue;
			}
			// Every entry the picker draws is re-indented here, cursor or
			// not: it writes its own two-cell gutter ("> " on the cursor,
			// two spaces elsewhere), and re-styling only the cursor row
			// would leave it a column out of line with the rest.
			bool is_cursor = plain.starts_with("> ");
			if (is_cursor || plain.starts_with("  ")) {
				String name = plain[2..];
				if (is_cursor && browser_active && visible_idx == cursor_row) {
					lines.append_string(focus_row(file_row_focused,
						string::tformat("%s%s", SIDEBAR_MARK, name)));
				} else {
					// The picker marks its cursor with a magenta arrow, which reads
					// as a highlight on a section that does not hold the focus.
					// Draw the row like its neighbours instead.
					int idx = visible_idx + ed.browser.scroll;
					bool is_dir = idx < ed.browser.count
						&& ed.browser.is_dirs[idx];
					glaze::Style s = is_dir ? ed.browser.dir_style
						: ed.browser.file_style;
					lines.append_string(s.render(string::tformat("%s%s", SIDEBAR_PAD, name)));
				}
			} else {
				lines.append_string(line);
			}
			lines.append_char('\n');
			visible_idx++;
			start = i + 1;
		}
	}
	String body = lines.str_view();
	out.append_string(bg.render(body));

	return out.str_view();
}

// ── GUI render ──────────────────────────────────────────────────────────────
//
// sidebar_tree() builds the sidebar as a clickable node tree. Each open-file
// row is its own node with on_click + on_hover_in/out; the browser is the
// picker's own tree_node() (which exposes per-row clicks the same way). The
// editor view's on_press hooks the editor body so a click there focuses it. Focus is not consulted anywhere — clicks work from any state.
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

const int SIDEBAR_FILES_PANEL_H = 1; // "Open" header
const int SIDEBAR_BROWSER_PANEL_H = 1; // "Files" header

fn xray::Node* sidebar_tree(Editor* ed) @feat(MILKTEA_GUI) {
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
		.height(milktea::cells(SIDEBAR_FILES_PANEL_H)));

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
		.height(milktea::cells(SIDEBAR_BROWSER_PANEL_H)));
	v.add(ed.browser.tree_node().width(milktea::cells(SIDEBAR_WIDTH)));

	return v;
}

// sidebar_node returns the sidebar in whatever form suits the backend:
// terminal gets a single styled string, GUI gets a clickable node tree.
fn xray::Node* sidebar_node(Editor* ed) {
	Theme* th = &ed.theme;
	glaze::Style panel = {
		.bg = th.browser_bg, .fg = th.browser_fg,
		.border = glaze::NORMAL, .border_color = th.border,
	};
	$if $feat(MILKTEA_GUI):
		// The GUI version is a real tree; the panel border would frame a
		// single string, not a tree, so we skip the border in the GUI build
		// and let the sidebar stand on its own background. A border can be
		// added back once xray can frame an arbitrary node tree the same way.
		return sidebar_tree(ed);
	$else
		return milktea::text(panel, render_sidebar(ed))
			.width(milktea::cells(SIDEBAR_WIDTH));
	$endif
}

// sidebar_init registers the click hooks the GUI uses. Called once from
// Editor.init(). The terminal build does not need any of this.
fn void sidebar_init(Editor* ed) @feat(MILKTEA_GUI) {
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

// focus_row renders a row with the focused style, padded to the panel's
// inner width so the highlight reads as a selection bar across the sidebar
// instead of a box that stops where the name does.
fn String focus_row(glaze::Style s, String text) {
	int inner = SIDEBAR_WIDTH - 2;
	int w = glaze::string_width(text);
	if (w >= inner) return s.render(text);

	DString padded = dstring::temp();
	padded.append_string(text);
	for (int i = w; i < inner; i++) padded.append_char(' ');
	return s.render(padded.str_view());
}

// strip_ansi removes ESC[...m sequences from a string.
fn String strip_ansi(String s) {
	DString out = dstring::temp();
	sz i = 0;
	while (i < s.len) {
		if (s[i] == 0x1b && i + 1 < s.len && s[i+1] == '[') {
			i += 2;
			while (i < s.len && s[i] != 'm') i++;
			if (i < s.len) i++;
			continue;
		}
		out.append_char(s[i]);
		i++;
	}
	return out.str_view();
}
