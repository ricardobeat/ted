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
// The sidebar is one styled string in either build, so both show the same
// panel: the same rows, the same highlight on the file the editor is showing
// and on the row the browser's cursor is on. Nothing per-row is clickable —
// the keyboard is what moves the focus — which also means the GUI and the
// terminal draw from exactly the same code.

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

// sidebar_node is the panel the sidebar is drawn as: the string above, in a
// box with a border, at the sidebar's width. Both builds call this.
fn xray::Node* sidebar_node(Editor* ed) {
	Theme* th = &ed.theme;
	glaze::Style panel = {
		.bg = th.browser_bg, .fg = th.browser_fg,
		.border = glaze::NORMAL, .border_color = th.border,
	};
	return milktea::text(panel, render_sidebar(ed))
		.width(milktea::cells(SIDEBAR_WIDTH));
}

// sidebar_init registers the press handler the editor's node carries. Called
// once from Editor.init(), and only by the GUI: the terminal build is
// keyboard-driven and never has a pointer to press with.
fn void sidebar_init(Editor* ed) @feat(MILKTEA_GUI) {
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
