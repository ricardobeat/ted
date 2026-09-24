module ted;

import milktea;
import glaze;
import xray;
import boba;
import std::io;
import std::io::file;
import std::core::dstring;
import std::core::string;
import std::os::env;

const int BAR_ROWS = 1;
const int STATUS_ROWS = 1;
const int STATUS_PAD = 2;

// Focus model.
//
// EDITOR receives all printable keys plus cursor movement, backspace, and
// the standard textarea shortcuts; TAB inserts indentation like any other
// key and never leaves it. Only ESC leaves the editor, into MENU_BAR.
//
// MENU_BAR owns LEFT/RIGHT/ENTER/DOWN for the menu when no dropdown is open.
// TAB moves to the sidebar; ESC returns to EDITOR.
//
// The sidebar is one stop with two panels, and the focus value says which
// one the keyboard is in:
//   FOCUS_SIDEBAR_FILES    the open-files list at the top of the sidebar
//   FOCUS_SIDEBAR_BROWSER  the file browser at the bottom of the sidebar
// UP and DOWN run through both as one list: DOWN past the last open file
// lands on the browser's first row, UP from there goes back. TAB goes
// between MENU_BAR and the sidebar. ESC always returns to EDITOR.
enum Focus : int {
	FOCUS_EDITOR,
	FOCUS_MENU_BAR,
	FOCUS_SIDEBAR_FILES,
	FOCUS_SIDEBAR_BROWSER,
}

struct OpenFile {
	char[256] path_buf;
	sz path_len;
}

const int MAX_OPEN_FILES = 16;

struct Editor {
	Menu menu;
	Dialog shortcuts;
	Dialog about;
	Dialog quit_confirm;
	boba::FilePicker browser;
	boba::Textarea textarea;
	Theme theme;

	// Open files. The textarea always shows the active one; loading or
	// creating a new file pushes onto this list. For now we only support a
	// single buffer, but the data structure is here for future expansion.
	OpenFile[MAX_OPEN_FILES] open_files;
	int open_file_count;
	int active_file;
	// GUI-only: per-row click slot for the open-files panel of the sidebar.
	// Each row's id_with(&file_slots[i]) carries this address through the
	// node tree to the click handler. -1 in file_hover = no row hovered.
	FileSlot[MAX_OPEN_FILES] file_slots @feat(MILKTEA_GUI);
	int file_hover @feat(MILKTEA_GUI);

	// Cells reserved at the left of the top bar for window buttons drawn by
	// the platform (see gui_main.c3); zero in the terminal.
	int chrome_cells;
	Focus focus;
	// The path named on the command line, set by main() before the program
	// starts. It may not exist yet: then the buffer starts empty under that
	// name and the file appears on the first save.
	String open_arg;
	String current_file;
	String status_msg;
	bool modified;
	int win_w;
	int win_h;
}

fn milktea::Cmd Editor.init(Editor* self) @dynamic {
	self.theme = default_theme();
	Theme* th = &self.theme;

	self.menu = new_menu({ " File ", " Edit ", " View ", " Help " });
	self.menu.x_inset = self.chrome_cells;
	self.menu.set_items(0, { {"New", "Ctrl+N"}, {"Open", "Ctrl+O"}, {"Save", "Ctrl+S"}, {"Quit", "Ctrl+Q"} });
	self.menu.set_items(1, { {"Undo", "Ctrl+Z"}, {"Cut", "Ctrl+X"}, {"Copy", "Ctrl+C"}, {"Paste", "Ctrl+V"} });
	self.menu.set_items(2, { {"Sidebar", "Ctrl+B"}, {"Line Numbers", ""}, {"Word Wrap", ""}, {"Fullscreen", "F11"} });
	self.menu.set_items(3, { {"Shortcuts", "?"}, {"About", ""}, {"", ""}, {"", ""} });

	self.shortcuts = new_dialog("Keyboard Shortcuts",
		"Esc      Leave menu/sidebar\n"
		"Tab      menu → sidebar → browser\n"
		"Ctrl+N   New file\n"
		"Ctrl+O   Open file\n"
		"Ctrl+S   Save file\n"
		"Ctrl+B   Toggle sidebar\n"
		"Ctrl+Q   Quit\n"
		"?        Show this",
		"  OK  ", "Close");

	self.about = new_dialog("About ted",
		"A minimal text editor\nbuilt with milktea.\n\nVersion 0.1.0",
		"  OK  ", "Close");

	self.quit_confirm = new_dialog("Unsaved changes",
		"The current file has changes that haven't been saved. Quit anyway?",
		" Quit ", "Cancel");

	self.browser = boba::new_file_picker(".");
	self.browser.load_dir(".");
	self.focus = FOCUS_EDITOR;
	self.modified = false;
	self.textarea = boba::new_textarea(80, 24);
	self.status_msg = "Ready";
	self.win_w = 80;
	self.win_h = 24;
	self.open_file_count = 0;
	self.active_file = -1;
	// GUI: register the click handlers the sidebar uses. The terminal build
	// is keyboard-driven and never sees these paths.
	$if $feat(MILKTEA_GUI):
		sidebar_init(self);
	$endif

	// Layout-debug hooks for the snapshot harness (`./out/ted --render`).
	String? focus_opt = std::os::env::tget_var("TED_FOCUS");
	if (try f = focus_opt) {
		if (f == "menu") { self.focus = FOCUS_MENU_BAR; }
		else if (f == "files") { self.focus = FOCUS_SIDEBAR_FILES; }
		else if (f == "browser") { self.focus = FOCUS_SIDEBAR_BROWSER; }
	}
	String? open_opt = std::os::env::tget_var("TED_OPEN");
	if (try path = open_opt) {
		open_from_env(self, path);
	}
	if (self.open_arg.len > 0) self.open_path(self.open_arg);
	String? dialog_opt = std::os::env::tget_var("TED_DIALOG");
	if (try d = dialog_opt) {
		if (d == "shortcuts") { self.shortcuts.show(); }
		else if (d == "about") { self.about.show(); }
		else if (d == "quit") { self.quit_confirm.show(); }
		else if (d == "menu") { self.menu.open = true; }
	}

	return null;
}

// open_from_env opens every file TED_OPEN names, comma separated, and leaves
// the last one active. One path was enough while the sidebar only had to
// render; a list is what lets a snapshot show a selection moving between
// rows, which takes at least two of them.
fn void open_from_env(Editor* e, String spec) {
	sz start = 0;
	for (sz i = 0; i <= spec.len; i++) {
		if (i == spec.len || spec[i] == ',') {
			if (i > start) {
				String path = spec[start:i - start];
				int idx = e.open_file_add(path);
				if (idx >= 0) {
					e.active_file = idx;
					e.current_file = path;
					e.load_file(path);
				}
			}
			start = i + 1;
		}
	}
}

// open_file_add pushes a path onto the open-files list, returning the new
// index. If the path is already open, returns its existing index.
fn int Editor.open_file_add(&self, String path) {
	for (int i = 0; i < self.open_file_count; i++) {
		OpenFile* f = &self.open_files[i];
		if (f.path_len != path.len) continue;
		bool same = true;
		for (sz j = 0; j < path.len; j++) {
			if (f.path_buf[j] != path[j]) { same = false; break; }
		}
		if (same) return i;
	}
	if (self.open_file_count >= MAX_OPEN_FILES) return -1;
	OpenFile* f = &self.open_files[self.open_file_count];
	sz n = path.len < f.path_buf.len ? path.len : f.path_buf.len;
	for (sz i = 0; i < n; i++) f.path_buf[i] = path[i];
	f.path_len = n;
	return self.open_file_count++;
}

fn void Editor.load_file(&self, String path) {
	char[]? data = file::load_temp(path);
	if (catch err = data) {
		self.status_msg = string::tformat("Error: could not read %s", path);
		return;
	}

	self.textarea.clear();
	String content = (String)data;
	self.textarea.handle_paste(content);
	self.current_file = path;
	self.modified = false;

	int idx = self.open_file_add(path);
	if (idx >= 0) self.active_file = idx;
	self.status_msg = string::tformat("Opened: %s", path);
}

// open_path opens the file at `path`, or, when there is none yet, starts an
// empty buffer that will be written there on save. Nothing touches the disk
// until then.
fn void Editor.open_path(&self, String path) {
	if (file::exists(path)) {
		self.load_file(path);
		return;
	}
	self.textarea.clear();
	self.current_file = path;
	self.modified = false;
	int idx = self.open_file_add(path);
	if (idx >= 0) self.active_file = idx;
	self.status_msg = string::tformat("New file: %s", path);
}

fn void Editor.save_file(&self) {
	if (self.current_file.len == 0) {
		self.status_msg = "No file to save";
		return;
	}
	String content = self.textarea.text();
	if (catch err = io::file::save(self.current_file, content)) {
		self.status_msg = string::tformat("Error: could not save %s", self.current_file);
		return;
	}
	self.modified = false;
	self.status_msg = string::tformat("Saved: %s", self.current_file);
}

fn void Editor.new_file(&self) {
	self.textarea.clear();
	self.current_file = "";
	self.modified = false;
	self.status_msg = "New file";
}

// activate_file switches the editor to the open file at `idx`. Called both
// from the sidebar keyboard handler and from the GUI click path — the click
// fires regardless of which panel holds keyboard focus, so the user can jump
// between open files without first focusing the sidebar.
fn void Editor.activate_file(&self, int idx) {
	if (idx < 0 || idx >= self.open_file_count) return;
	if (idx == self.active_file) return;
	OpenFile* f = &self.open_files[idx];
	String path = (String)f.path_buf[:f.path_len];
	self.active_file = idx;
	self.current_file = path;
	self.textarea.clear();
	self.modified = false;
	// A file named on the command line but never saved has nothing on disk.
	if (!file::exists(path)) return;
	char[]? data = file::load_temp(path);
	if (catch err = data) {
		self.status_msg = string::tformat("Error: could not read %s", path);
		return;
	}
	String content = (String)data;
	self.textarea.handle_paste(content);
	self.modified = false;
}

// ── Focus helpers ──────────────────────────────────────────────────────────

fn bool Editor.in_sidebar(&self) {
	return self.focus == FOCUS_SIDEBAR_FILES || self.focus == FOCUS_SIDEBAR_BROWSER;
}

// cycle_focus moves to the next stop after a TAB. TAB only cycles once the
// editor has been left with ESC (in the editor TAB inserts indentation), so
// the ring never contains the editor: menu → sidebar → menu. The sidebar is
// entered at the open files, or at the browser when nothing is open.
fn void Editor.cycle_focus(&self) {
	switch (self.focus) {
		case FOCUS_EDITOR:   self.focus = FOCUS_MENU_BAR;
		case FOCUS_MENU_BAR: self.focus = self.open_file_count > 0 ? FOCUS_SIDEBAR_FILES : FOCUS_SIDEBAR_BROWSER;
		default:             self.focus = FOCUS_MENU_BAR;
	}
}

// focus_editor returns to the editor from anywhere.
fn void Editor.focus_editor(&self) {
	self.focus = FOCUS_EDITOR;
}

// ── Update ──────────────────────────────────────────────────────────────────

fn milktea::Cmd Editor.update(Editor* self, milktea::Msg msg) @dynamic {
	if (msg.kind == milktea::MsgKind.WINDOW_SIZE) {
		self.win_w = msg.window_size.width;
		self.win_h = msg.window_size.height;
		return null;
	}

	if (msg.kind == milktea::MsgKind.MOUSE) return self.handle_mouse_result();
	if (msg.kind != milktea::MsgKind.KEY) return null;
	milktea::KeyMsg k = msg.key;

	// Modal dialogs take precedence over the focus model.
	if (self.shortcuts.open) return self.handle_shortcuts_key(k);
	if (self.about.open) return self.handle_about_key(k);
	if (self.quit_confirm.open) return self.handle_quit_confirm_key(k);

	// While the dropdown is open, the menu owns every key (LEFT/RIGHT/UP/DOWN/
	// ENTER/ESC). Anything else is ignored.
	if (self.menu.open) return self.handle_menu_key(k);

	// '?' opens shortcuts from anywhere.
	if (k.code == milktea::KeyCode.RUNE && k.rune == '?' && !k.ctrl) {
		self.shortcuts.show();
		return null;
	}

	// Global Ctrl shortcuts work in any focus.
	if (k.ctrl) return self.handle_ctrl_key(k);

	// From the editor, TAB is indentation like any other key: the textarea
	// handles it and focus does not move. Only ESC leaves the editor, into
	// the menu bar; once outside, TAB goes between the menu and the sidebar
	// and ESC returns to the editor.
	if (k.code == milktea::KeyCode.TAB && self.focus != FOCUS_EDITOR) {
		self.cycle_focus();
		return null;
	}
	if (k.code == milktea::KeyCode.ESC) {
		if (self.focus != FOCUS_EDITOR) {
			self.focus_editor();
			return null;
		}
		// ESC in the editor moves into the focus ring rather than quitting;
		// quit is Ctrl+Q from any focus.
		self.focus = FOCUS_MENU_BAR;
		return null;
	}

	switch (self.focus) {
		case FOCUS_MENU_BAR: return self.handle_menu_bar_key(k);
		case FOCUS_SIDEBAR_FILES: return self.handle_sidebar_files_key(k);
		case FOCUS_SIDEBAR_BROWSER: return self.handle_sidebar_browser_key(k);
		case FOCUS_EDITOR:
		default: return self.handle_editor_key(k);
	}
}

// set_zoom steps the GUI font size, or returns it to the default when steps
// is zero. The terminal build has no font of its own — the terminal owns it —
// so there it says so rather than pretending to have changed something.
fn void Editor.set_zoom(&self, int steps) {
	$if $feat(MILKTEA_GUI):
		bool moved = steps == 0 ? set_text_size(GUI_TEXT_DEFAULT) : zoom(steps);
		self.status_msg = moved
			? string::tformat("Font %d pt", text_size())
			: string::tformat("Font %d pt (no further)", text_size());
	$else
		self.status_msg = "Font size is the terminal's to set";
	$endif
}

fn milktea::Cmd Editor.handle_ctrl_key(&self, milktea::KeyMsg k) {
	switch (k.code) {
		case milktea::KeyCode.RUNE:
			switch (k.rune) {
				case 'q': return self.quit();
				case 's': self.save_file();
				case 'n': self.new_file();
				case 'o': self.focus = FOCUS_SIDEBAR_BROWSER;
				case 'b':
					if (self.in_sidebar()) { self.focus = FOCUS_EDITOR; }
					else { self.focus = FOCUS_SIDEBAR_FILES; }
				case '=': self.set_zoom(1);
				case '-': self.set_zoom(-1);
				case '0': self.set_zoom(0);
				default:
			}
			return null;
		default:
	}
	return null;
}

fn milktea::Cmd Editor.handle_menu_bar_key(&self, milktea::KeyMsg k) {
	switch (k.code) {
		case milktea::KeyCode.LEFT:
			if (self.menu.selected > 0) self.menu.selected--;
		case milktea::KeyCode.RIGHT:
			if (self.menu.selected < MENU_COLS - 1) self.menu.selected++;
		case milktea::KeyCode.DOWN:
		case milktea::KeyCode.ENTER:
			self.menu.open = true;
			self.menu.item = 0;
		default:
	}
	return null;
}

fn milktea::Cmd Editor.handle_editor_key(&self, milktea::KeyMsg k) {
	self.textarea.handle_key(k);
	self.modified = true;
	return null;
}

// handle_sidebar_files_key moves through the open-files list. Moving the
// selection switches the editor to that file, the same as clicking the row
// does: a sidebar that says one file is current while the editor shows
// another is worse than either half alone. activate_file ignores an index
// out of range, so UP at the top does nothing; DOWN at the bottom moves on
// into the browser, the list's continuation.
fn milktea::Cmd Editor.handle_sidebar_files_key(&self, milktea::KeyMsg k) {
	switch (k.code) {
		case milktea::KeyCode.UP:
			self.activate_file(self.active_file - 1);
		case milktea::KeyCode.DOWN:
			// Past the last open file the list carries on into the browser.
			if (self.active_file >= self.open_file_count - 1) {
				self.focus = FOCUS_SIDEBAR_BROWSER;
				self.browser.cursor = 0;
			} else {
				self.activate_file(self.active_file + 1);
			}
		case milktea::KeyCode.ENTER:
			if (self.open_file_count > 0) self.focus_editor();
		default:
	}
	return null;
}

fn milktea::Cmd Editor.handle_sidebar_browser_key(&self, milktea::KeyMsg k) {
	// Above the browser's first row are the open files.
	if (k.code == milktea::KeyCode.UP && self.browser.cursor == 0 && self.open_file_count > 0) {
		self.focus = FOCUS_SIDEBAR_FILES;
		return null;
	}
	if (k.code == milktea::KeyCode.ENTER && self.browser.cursor < self.browser.count
		&& !self.browser.is_dirs[self.browser.cursor]) {
		String name = (String)self.browser.names[self.browser.cursor][:self.browser.name_lens[self.browser.cursor]];
		DString path = dstring::temp();
		path.append_string(self.browser.current_dir);
		path.append_char('/');
		path.append_string(name);
		self.load_file(path.str_view());
		self.focus_editor();
		return null;
	}
	self.browser.handle_key(k);
	return null;
}

fn milktea::Cmd Editor.handle_menu_key(&self, milktea::KeyMsg k) {
	switch (self.menu.handle_key(k)) {
		case Chosen.PICKED:
			self.focus = FOCUS_EDITOR;
			return self.run_menu_item(self.menu.current_item().label);
		case Chosen.DISMISSED:
			self.focus = FOCUS_EDITOR;
			self.status_msg = "Ready";
		default:
	}
	return null;
}

fn milktea::Cmd Editor.run_menu_item(&self, String label) {
	switch (label) {
		case "New":
			self.new_file();
			self.focus = FOCUS_EDITOR;
		case "Open":
			self.focus = FOCUS_SIDEBAR_BROWSER;
		case "Save":
			self.save_file();
			self.focus = FOCUS_EDITOR;
		case "Quit":
			return self.quit();
		case "Shortcuts":
			self.shortcuts.show();
		case "About":
			self.about.show();
		case "Sidebar":
			if (self.in_sidebar()) { self.focus = FOCUS_EDITOR; }
			else { self.focus = FOCUS_SIDEBAR_FILES; }
		default:
			self.status_msg = "Not implemented";
	}
	return null;
}

fn milktea::Cmd Editor.handle_shortcuts_key(&self, milktea::KeyMsg k) {
	switch (self.shortcuts.handle_key(k)) {
		case Pressed.CONFIRMED:
			self.status_msg = "Ready";
		case Pressed.DISMISSED:
			self.status_msg = "Ready";
		default:
	}
	return null;
}

// quit leaves at once when there is nothing to lose, and otherwise asks
// first.
fn milktea::Cmd Editor.quit(&self) {
	if (!self.modified) return milktea::quit();
	self.quit_confirm.show();
	self.quit_confirm.focused = 1; // Cancel: a stray Enter shouldn't lose work
	return null;
}

fn milktea::Cmd Editor.handle_quit_confirm_key(&self, milktea::KeyMsg k) {
	// Ctrl+Q again means "yes, quit", so it takes two presses to leave with
	// unsaved changes rather than a trip to the Quit button.
	if (k.ctrl && k.code == milktea::KeyCode.RUNE && k.rune == 'q') return milktea::quit();
	if (self.quit_confirm.handle_key(k) == Pressed.CONFIRMED) return milktea::quit();
	return null;
}

fn milktea::Cmd Editor.handle_about_key(&self, milktea::KeyMsg k) {
	switch (self.about.handle_key(k)) {
		case Pressed.CONFIRMED:
			self.status_msg = "Ready";
		case Pressed.DISMISSED:
			self.status_msg = "Ready";
		default:
	}
	return null;
}

fn milktea::Cmd Editor.handle_mouse_result(&self) {
	switch (self.menu.take_pending()) {
		case Chosen.PICKED:
			self.focus = FOCUS_EDITOR;
			return self.run_menu_item(self.menu.current_item().label);
		case Chosen.DISMISSED:
			self.status_msg = "Ready";
		default:
	}
	switch (self.shortcuts.take_pending()) {
		case Pressed.CONFIRMED:
			self.status_msg = "Ready";
		default:
	}
	if (self.quit_confirm.take_pending() == Pressed.CONFIRMED) return milktea::quit();
	switch (self.about.take_pending()) {
		case Pressed.CONFIRMED:
			self.status_msg = "Ready";
		default:
	}
	return null;
}

// ── View ───────────────────────────────────────────────────────────────────

fn milktea::View Editor.view(Editor* self) @dynamic {
	Theme* th = &self.theme;

	glaze::Style status_style = { .bg = th.status_bg, .fg = th.status_fg };
	glaze::Style key_style = { .bg = th.accent, .fg = th.ink, .bold = true };

	String file_label;
	if (self.current_file.len > 0) {
		String mod_marker = self.modified ? " [+]" : "";
		file_label = string::tformat("  %s%s", self.current_file, mod_marker);
	} else {
		file_label = "  [new]";
	}
	String cursor_label = string::tformat("  Ln %d, Col %d  ",
		self.textarea.cursor_row + 1, self.textarea.cursor_col + 1);

	String mode_hint;
	switch (self.focus) {
		case FOCUS_MENU_BAR:        mode_hint = "[MENU] ";
		case FOCUS_SIDEBAR_FILES:   mode_hint = "[FILES] ";
		case FOCUS_SIDEBAR_BROWSER: mode_hint = "[BROWSE] ";
		case FOCUS_EDITOR:
		default:                    mode_hint = "";
	}
	String hint_label = string::tformat(
		"  %s  %s focus  %s cycle  %s sidebar  %s shortcuts  %s quit ",
		mode_hint,
		key_style.render("Esc"),
		key_style.render("Tab"),
		key_style.render("Ctrl+B"),
		key_style.render("?"),
		key_style.render("Ctrl+Q"));

	String right_info = string::tformat("%s%s │ %s",
		file_label, cursor_label, self.status_msg);

	int editor_h = self.win_h - BAR_ROWS - STATUS_ROWS;
	if (editor_h < 1) editor_h = 1;

	self.textarea.width = self.win_w - SIDEBAR_WIDTH - 2;
	self.textarea.height = editor_h - 2;
	self.textarea.focused = self.focus == FOCUS_EDITOR;

	// The textarea paints its own cells over the padded area behind it, so
	// every style it renders with has to carry the editor background. A style
	// that only sets a foreground leaves those cells on the terminal's default
	// background, which shows through as a rectangle of the wrong colour.
	self.textarea.focused_style = glaze::style()
		.foreground(th.editor_fg).background(th.editor_bg);
	self.textarea.blurred_style = glaze::style()
		.foreground(th.dim).background(th.editor_bg);
	self.textarea.line_number_style = glaze::style()
		.foreground(th.line_num).background(th.editor_bg);
	self.textarea.placeholder_style = glaze::style()
		.foreground(th.dim).background(th.editor_bg);
	self.textarea.cursor_style = glaze::style()
		.foreground(th.ink).background(th.cursor);

	self.browser.width = SIDEBAR_WIDTH;
	self.browser.height = editor_h;

	xray::Node* editor_row = milktea::hstack().fill(1);
	editor_row.add(sidebar_node(self));

	// Editor area with 1-cell padding on every side, so the textarea and
	// line-number gutter sit inside a margin rather than flush against the
	// sidebar and the status bar.
	editor_row.add(milktea::vbox(glaze::style().background(th.editor_bg).pad(1))
		.fill(1)
		.add(self.textarea.node().fill(1)));

	xray::Node* status_row = milktea::hstack()
		.height(milktea::cells(1))
		.add(milktea::text(status_style, hint_label).fill(1))
		.add(milktea::text(status_style, right_info).fit_width());

	// The padding is the bar's own, so the whole strip reads as one bar out
	// to the ends the row of hints does not reach.
	xray::Node* statusbar = milktea::vbox(status_style.pad_x(STATUS_PAD))
		.height(milktea::cells(STATUS_ROWS))
		.add(status_row);

	xray::Rect editor_area = {
		.x = SIDEBAR_WIDTH,
		.y = BAR_ROWS,
		.w = self.win_w - SIDEBAR_WIDTH,
		.h = self.win_h - BAR_ROWS - STATUS_ROWS,
	};

	// In the GUI the top row stands in for the title bar, so it carries the
	// window buttons the platform no longer draws. In the terminal there is
	// no window to close and both ends stay empty.
	xray::Node* lead = null;
	xray::Node* trail = null;
	$if $feat(MILKTEA_GUI):
		if (chrome_on_left()) {
			lead = window_lights(th, self);
		} else {
			trail = window_lights(th, self);
		}
	$endif

	return milktea::draw(milktea::root()
		.add(milktea::vstack()
			.add(self.menu.bar(th, self.focus == FOCUS_MENU_BAR, lead, trail))
			.add(editor_row)
			.add(statusbar))
		.add(self.menu.dropdown(BAR_ROWS, th))
		.add(self.shortcuts.node(th, editor_area))
		.add(self.about.node(th, editor_area))
		.add(self.quit_confirm.node(th, editor_area)));
}

// The GUI build (ted-gui) supplies its own main() in gui_main.c3.
fn int main(String[] args) @feat(!MILKTEA_GUI) {
	if (args.len > 1 && args[1] == "--render") return dump_render();
	Editor e = { };
	if (args.len > 1) e.open_arg = args[1];
	return milktea::@run(&e);
}

fn int dump_render() {
	DString out = dstring::temp();
	Editor e = { };
	milktea::Program p = milktea::@test_program_input(&e, &out, 100, 30, (char[]){ 0x11 });
	p.run()!!;

	String? focus_opt = std::os::env::tget_var("TED_FOCUS");
	if (try f = focus_opt) {
		if (f == "menu") { e.focus = FOCUS_MENU_BAR; }
		else if (f == "files") { e.focus = FOCUS_SIDEBAR_FILES; }
		else if (f == "browser") { e.focus = FOCUS_SIDEBAR_BROWSER; }
	}
	String? open_opt = std::os::env::tget_var("TED_OPEN");
	if (try path = open_opt) {
		open_from_env(&e, path);
	}
	String? dialog_opt = std::os::env::tget_var("TED_DIALOG");
	if (try d = dialog_opt) {
		if (d == "shortcuts") { e.shortcuts.show(); }
		else if (d == "about") { e.about.show(); }
		else if (d == "quit") { e.quit_confirm.show(); }
		else if (d == "menu") { e.menu.open = true; }
	}

	DString out2 = dstring::temp();
	milktea::Program p2 = milktea::@test_program_input(&e, &out2, 100, 30, (char[]){ 0x11 });
	p2.run()!!;

	String captured = out2.str_view();
	DString plain = dstring::temp();
	bool in_esc = false;
	for (usz i = 0; i < captured.len; i++) {
		char c = captured[i];
		if (in_esc) {
			if (c == 'm' || c == 'K' || c == 'J' || c == 'H' || c == 'l' || c == 'h') in_esc = false;
			continue;
		}
		if (c == 0x1b) { in_esc = true; continue; }
		if (c == '\r') continue;
		plain.append_char(c);
	}
	io::printfn("%s", plain.str_view());
	return 0;
}
