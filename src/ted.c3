module ted;

import milktea;
import glaze;
import xray;
import boba;
import dye;
import ted::editor;
import std::io;
import std::io::file;
import std::core::dstring;
import std::core::string;
import std::os::env;

const sz BAR_ROWS = 1;
const sz STATUS_ROWS = 1;
const sz BAR_PADDING_Y = 4;
const sz BAR_PADDING_X = 8;
// The window buttons are this tall, so the bar never gets shorter.
const sz WINDOW_BUTTON_HEIGHT = 14;

fn sz top_bar_pixel_height() {
	sz height = milktea::layout_metrics().unit_h();
	if (height < WINDOW_BUTTON_HEIGHT) height = WINDOW_BUTTON_HEIGHT;
	return height + BAR_PADDING_Y * 2;
}
const sz STATUS_PAD = 2;

// Focus model.
//
// EDITOR receives all printable keys plus cursor movement, backspace, and
// the editor's own shortcuts (see editor/commands.c3); TAB indents like any
// other key and never leaves it. Only ESC leaves the editor, into MENU_BAR.
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
enum Focus : sz {
	FOCUS_EDITOR,
	FOCUS_MENU_BAR,
	FOCUS_SIDEBAR_FILES,
	FOCUS_SIDEBAR_BROWSER,
}

struct OpenFile {
	char[256] path_buf;
	sz path_len;
}

const sz MAX_OPEN_FILES = 16;
// File-navigator rows visible at once. The picker keeps up to 64 entries;
// this caps the per-row click slots the sidebar holds on the Editor.
const sz MAX_BROWSER_ROWS = 64;

struct Editor {
	boba::MenuBar menu;
	Dialog shortcuts;
	Dialog about;
	Dialog quit_confirm;
	CommandBar command_bar;
	FileSearch file_search;
	boba::FilePicker browser;
	editor::View doc;
	Theme theme;

	// Open files. The editor view always shows the active one; loading or
	// creating a new file pushes onto this list. For now we only support a
	// single buffer, but the data structure is here for future expansion.
	OpenFile[MAX_OPEN_FILES] open_files;
	sz open_file_count;
	sz active_file;

	// Per-row click slot for the open-files panel of the sidebar. Each row's
	// ref(&file_slots[i]) carries this address through the node tree to
	// the click handler. -1 in file_hover = no row hovered. The address stays
	// stable across frames even though the node tree is rebuilt each call to
	// view().
	FileSlot[MAX_OPEN_FILES] file_slots;
	sz file_hover;
	// Same role for the file-navigator rows: a stable pointer per row plus
	// the row under the pointer. The browser owns its own data — names,
	// is_dirs, current_dir — but the click and hover handlers live here so
	// the sidebar can apply one style across both panels.
	BrowserSlot[MAX_BROWSER_ROWS] browser_slots;
	sz browser_hover;

	Focus focus;
	// View ▸ Sidebar (Ctrl+B) puts the sidebar away; the editor takes its
	// room, and focus skips it.
	bool sidebar_hidden;
	// How far the sidebar is shown, 0 to 1; it slides in and out as this
	// runs toward !sidebar_hidden.
	milktea::Tween sidebar_shown;
	// The path named on the command line, set by main() before the program
	// starts. It may not exist yet: then the buffer starts empty under that
	// name and the file appears on the first save.
	String open_arg;
	String current_file;
	Syntax syntax;
	String status_msg;
	bool modified;
	sz win_w;
	sz win_h;
}

fn milktea::Cmd Editor.init(Editor* self) @dynamic {
	self.theme = default_theme();
	Theme* th = &self.theme;

	self.menu = boba::menu_bar({
		boba::menu(" File ", { boba::item("New", 'n'), boba::item("Open", 'o'), boba::item("Save", 's'),
			boba::separator(), boba::item("Quit", 'q') }),
		boba::menu(" Edit ", { boba::item("Undo", 'z'), boba::separator(), boba::item("Cut", 'x'),
			boba::item("Copy", 'c'), boba::item("Paste", 'v') }),
		boba::menu(" View ", { boba::item("Sidebar", 'b'), boba::item("Line Numbers"), boba::item("Word Wrap"),
			boba::item("Fullscreen") }),
		boba::menu(" Help ", { boba::item("Shortcuts"), boba::item("About") }),
	});
	self.menu.min_panel_width = 24;

	self.shortcuts = new_dialog("Keyboard Shortcuts",
		"Ctrl+P   Search files\n"
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
	self.syntax.reset();
	self.doc.init();
	self.doc.assist = &self.syntax;
	self.status_msg = "Ready";
	self.win_w = 80;
	self.win_h = 24;
	self.open_file_count = 0;
	self.active_file = -1;
	// Register the click handlers every interactive node carries. Milktea
	// parses mouse events in both the terminal and the GUI and dispatches
	// them through the same framework, so the same handlers fire in either
	// build without a feature gate.
	sidebar_init(self);
	self.sidebar_shown = milktea::tween(1, SIDEBAR_SLIDE_MS);

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
		if (d == "command") { self.show_file_search(); }
		if (d == "shortcuts") { self.shortcuts.show(); }
		else if (d == "about") { self.about.show(); }
		else if (d == "quit") { self.quit_confirm.show(); }
		else if (d == "menu") { self.menu.open = true; }
	}
	self.apply_settings();

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
				sz idx = e.open_file_add(path);
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
fn sz Editor.open_file_add(&self, String path) {
	for (sz i = 0; i < self.open_file_count; i++) {
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

// track_file adds `path` to the open-files list and makes it current.
// current_file points at the list's own copy, never at `path` itself: callers
// such as the sidebar pass temp-allocated strings that are freed once the
// frame ends.
fn void Editor.track_file(&self, String path) {
	sz idx = self.open_file_add(path);
	if (idx < 0) {
		self.current_file = path.copy(mem);
		return;
	}
	self.active_file = idx;
	OpenFile* f = &self.open_files[idx];
	self.current_file = (String)f.path_buf[:f.path_len];
}

fn void Editor.load_file(&self, String path) {
	char[]? data = file::load_temp(path);
	if (catch err = data) {
		self.status_msg = string::tformat("Error: could not read %s", path);
		return;
	}

	self.doc.set_text((String)data);
	self.modified = false;
	self.track_file(path);
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
	self.doc.set_text("");
	self.modified = false;
	self.track_file(path);
	self.status_msg = string::tformat("New file: %s", path);
}

fn void Editor.save_file(&self) {
	if (self.current_file.len == 0) {
		self.status_msg = "No file to save";
		return;
	}
	String content = self.doc.text();
	if (catch err = io::file::save(self.current_file, content)) {
		self.status_msg = string::tformat("Error: could not save %s", self.current_file);
		return;
	}
	self.modified = false;
	self.status_msg = string::tformat("Saved: %s", self.current_file);
}

fn void Editor.new_file(&self) {
	self.doc.set_text("");
	self.current_file = "";
	self.modified = false;
	self.status_msg = "New file";
}

// activate_file switches the editor to the open file at `idx`. Called both
// from the sidebar keyboard handler and from the GUI click path — the click
// fires regardless of which panel holds keyboard focus, so the user can jump
// between open files without first focusing the sidebar.
fn void Editor.activate_file(&self, sz idx) {
	if (idx < 0 || idx >= self.open_file_count) return;
	if (idx == self.active_file) return;
	OpenFile* f = &self.open_files[idx];
	String path = (String)f.path_buf[:f.path_len];
	self.active_file = idx;
	self.current_file = path;
	self.doc.set_text("");
	self.modified = false;
	// A file named on the command line but never saved has nothing on disk.
	if (!file::exists(path)) return;
	char[]? data = file::load_temp(path);
	if (catch err = data) {
		self.status_msg = string::tformat("Error: could not read %s", path);
		return;
	}
	self.doc.set_text((String)data);
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
		case FOCUS_MENU_BAR:
			if (self.sidebar_hidden) return;
			self.focus = self.open_file_count > 0 ? FOCUS_SIDEBAR_FILES : FOCUS_SIDEBAR_BROWSER;
		default:             self.focus = FOCUS_MENU_BAR;
	}
}

// toggle_sidebar shows or hides the sidebar. Hiding it while it has the
// keyboard hands the keyboard back to the editor.
fn void Editor.toggle_sidebar(&self) {
	self.sidebar_hidden = !self.sidebar_hidden;
	self.sidebar_shown.update(self.sidebar_hidden ? 0 : 1);
	if (self.sidebar_hidden && self.in_sidebar()) self.focus = FOCUS_EDITOR;
	self.status_msg = self.sidebar_hidden ? "Sidebar hidden" : "Sidebar shown";
}

// open_browser moves to the file browser, bringing the sidebar back first
// if it was put away.
fn void Editor.open_browser(&self) {
	self.sidebar_hidden = false;
	self.sidebar_shown.update(1);
	self.focus = FOCUS_SIDEBAR_BROWSER;
}

// toggle_line_numbers hides the gutter, or brings it back the way the
// settings have it (every line, when they turn it off).
fn void Editor.toggle_line_numbers(&self) {
	if (self.doc.line_numbers != NONE) {
		self.doc.line_numbers = NONE;
		self.status_msg = "Line numbers off";
		return;
	}
	editor::LineNumbers want = settings().line_numbers;
	self.doc.line_numbers = want == NONE ? ALL : want;
	self.status_msg = "Line numbers on";
}

// toggle_wrap turns word wrap on or off. Unwrapped, a long line runs past
// the edge and the view follows the caret across.
fn void Editor.toggle_wrap(&self) {
	self.doc.wrap = !self.doc.wrap;
	self.doc.top_row = 0;
	self.doc.scroll_to_caret();
	self.status_msg = self.doc.wrap ? "Word wrap on" : "Word wrap off";
}

// toggle_fullscreen_mode fills the screen with the window, or puts it back.
// A terminal's window is the terminal's to size.
fn void Editor.toggle_fullscreen_mode(&self) {
	$if $feat(MILKTEA_GUI):
		toggle_fullscreen();
		self.status_msg = "Ready";
	$else
		self.status_msg = "Full screen is the terminal's to set";
	$endif
}

// focus_editor returns to the editor from anywhere.
fn void Editor.focus_editor(&self) {
	self.focus = FOCUS_EDITOR;
}

// ── Update ──────────────────────────────────────────────────────────────────

fn milktea::Cmd Editor.update(Editor* self, milktea::Msg msg) @dynamic {
	if (msg.kind == milktea::MsgKind.TICK && msg.owner == &self.file_search) {
		self.poll_file_search();
		return null;
	}
	if (msg.kind == milktea::MsgKind.WINDOW_SIZE) {
		self.win_w = msg.window_size.width;
		self.win_h = msg.window_size.height;
		return null;
	}

	if (msg.kind == milktea::MsgKind.MENU || msg.kind == milktea::MsgKind.MOUSE) {
		boba::MenuEvent ev = self.menu.update(msg);
		if (ev.kind != NONE) return self.menu_event(ev, msg.kind == milktea::MsgKind.MENU);
	}
	if (msg.kind == milktea::MsgKind.MOUSE) {
		if (self.wheel_scroll(msg.mouse)) return null;
		return self.handle_mouse_result();
	}
	// A terminal hands over pasted text (Cmd+V on a Mac) as one message.
	if (msg.kind == milktea::MsgKind.PASTE) {
		if (self.command_bar.open) { self.command_bar.paste(msg.paste); return null; }
		if (self.focus == FOCUS_EDITOR && msg.paste.len > 0) {
			self.doc.insert_text(msg.paste);
			self.modified = true;
		}
		return null;
	}
	if (msg.kind != milktea::MsgKind.KEY) return null;
	milktea::KeyMsg k = msg.key;

	if (self.command_bar.open) { self.command_bar.handle_key(k); return null; }

	// Modal dialogs take precedence over the focus model.
	if (self.shortcuts.open) return self.handle_shortcuts_key(k);
	if (self.about.open) return self.handle_about_key(k);
	if (self.quit_confirm.open) return self.handle_quit_confirm_key(k);

	// While a dropdown is open, or the focus is on the bar, the bar takes the
	// keys it knows (the arrows, Enter, Esc); an open dropdown takes all.
	self.menu.active = self.focus == FOCUS_MENU_BAR;
	if (self.menu.open || self.menu.active) {
		boba::MenuEvent ev = self.menu.update(msg);
		if (ev.kind != NONE || self.menu.open) return self.menu_event(ev, false);
	}

	// '?' opens shortcuts from anywhere.
	if (k.code == milktea::KeyCode.RUNE && k.rune == '?' && !k.ctrl && !k.super) {
		self.shortcuts.show();
		return null;
	}

	// Global Ctrl shortcuts work in any focus.
	// Ctrl or, in the GUI, Cmd: ted's shortcuts answer to either.
	if (k.ctrl || k.super) return self.handle_ctrl_key(k);

	// From the editor, TAB is indentation like any other key: the editor
	// handles it and focus does not move. Only ESC leaves the editor, into
	// the menu bar; once outside, TAB goes between the menu and the sidebar
	// and ESC returns to the editor.
	if (k.code == milktea::KeyCode.TAB && self.focus != FOCUS_EDITOR) {
		self.cycle_focus();
		return null;
	}
	// An open completion list takes Esc before anything else does.
	if (k.code == milktea::KeyCode.ESC && self.focus == FOCUS_EDITOR && self.doc.completing()) {
		self.doc.completion.close();
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
		case FOCUS_SIDEBAR_FILES: return self.handle_sidebar_files_key(k);
		case FOCUS_SIDEBAR_BROWSER: return self.handle_sidebar_browser_key(k);
		case FOCUS_EDITOR:
		default: return self.handle_editor_key(k);
	}
}

// set_zoom steps the GUI font size, or returns it to the default when steps
// is zero. The terminal build has no font of its own — the terminal owns it —
// so there it says so rather than pretending to have changed something.
fn void Editor.set_zoom(&self, sz steps) {
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
				case 'p': self.show_file_search();
				case 'q': return self.quit();
				case 's': self.save_file();
				case 'n': self.new_file();
				case 'o': self.open_browser();
				case 'b': self.toggle_sidebar();
				case '=': self.set_zoom(1);
				case '-': self.set_zoom(-1);
				case '0': self.set_zoom(0);
				default:
					if (self.focus == FOCUS_EDITOR) return self.handle_editor_key(k);
			}
			return null;
		default:
			// Ctrl with a navigation key moves by words or to the ends of the
			// document; those are the editor's.
			if (self.focus == FOCUS_EDITOR) return self.handle_editor_key(k);
	}
	return null;
}

fn milktea::Cmd Editor.handle_editor_key(&self, milktea::KeyMsg k) {
	// What a key does can depend on the language (pairs, strings, tags), so
	// the view's idea of it must be current even before the first frame.
	self.syntax.highlight(&self.doc, self.current_file);
	sz before = self.doc.buf.version;
	self.doc.handle_key(k);
	if (self.doc.buf.version != before) self.modified = true;
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

// menu_event acts on what the menu bar reports. A pick from the platform's
// menu bar of an item with a shortcut runs that shortcut: the platform took
// the key (⌘Z, ⌘C, ...) before the window saw it, and the shortcut is what
// the editor knows how to do.
fn milktea::Cmd Editor.menu_event(&self, boba::MenuEvent ev, bool native) {
	switch (ev.kind) {
		case PICKED:
			if (native && ev.item.key != 0) {
				return self.handle_ctrl_key({ .code = milktea::KeyCode.RUNE, .rune = ev.item.key, .ctrl = true });
			}
			self.focus = FOCUS_EDITOR;
			return self.run_menu_item(ev.item.label);
		case DISMISSED:
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
			self.open_browser();
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
			self.toggle_sidebar();
		case "Line Numbers":
			self.toggle_line_numbers();
		case "Word Wrap":
			self.toggle_wrap();
		case "Fullscreen":
			self.toggle_fullscreen_mode();
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
	if ((k.ctrl || k.super) && k.code == milktea::KeyCode.RUNE && k.rune == 'q') return milktea::quit();
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

// Rows one notch of the wheel moves the editor, the usual terminal amount.
const sz WHEEL_ROWS = 3;
// Columns one notch of Shift+wheel moves an unwrapped view across.
const sz WHEEL_COLS = 6;

// wheel_scroll scrolls the document when the wheel turns over it, without
// moving the caret, and reports whether it took the event. An open menu or
// dialog sits over the editor, so the wheel is left alone while one is up.
fn bool Editor.wheel_scroll(&self, milktea::MouseMsg m) {
	bool up = m.button == milktea::MouseButton.MOUSE_WHEEL_UP;
	bool wheel = up || m.button == milktea::MouseButton.MOUSE_WHEEL_DOWN;
	// A trackpad gesture can end (fingers lifted) without moving, which is
	// when a view pulled past an end springs back.
	bool phase = m.action == milktea::MouseAction.MOUSE_SCROLL_PHASE;
	if (!wheel && !phase) return false;
	if (self.command_bar.open || self.menu.open || self.shortcuts.open || self.about.open || self.quit_confirm.open) return false;
	bool over = self.doc.rect.contains(m.col, m.row);
	if (!phase && !over) return false;
	// Sideways, when lines don't wrap: a window's swipe by the pixel, a
	// terminal's Shift+wheel by a few columns.
	bool across = over && self.doc.scroll_msg_x(m);
	if (wheel && m.shift && m.scroll_dx == 0 && m.scroll_dy == 0 && !self.doc.wrap) {
		self.doc.scroll_cols(up ? -WHEEL_COLS : WHEEL_COLS);
		return true;
	}
	// In a window: by the pixel, with momentum and rubber-banding.
	if (self.doc.scroll_msg(m)) return true;
	if (!wheel) return across;
	self.doc.scroll(up ? -WHEEL_ROWS : WHEEL_ROWS);
	return true;
}

fn milktea::Cmd Editor.handle_mouse_result(&self) {
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

fn xray::Node* Editor.view(Editor* self) @dynamic {
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
	sz caret_line;
	sz caret_col;
	self.doc.caret_line_col(&caret_line, &caret_col);
	String cursor_label = string::tformat("  Ln %d, Col %d  ", caret_line + 1, caret_col + 1);

	String mode_hint;
	switch (self.focus) {
		case FOCUS_MENU_BAR:        mode_hint = "[MENU] ";
		case FOCUS_SIDEBAR_FILES:   mode_hint = "[FILES] ";
		case FOCUS_SIDEBAR_BROWSER: mode_hint = "[BROWSE] ";
		case FOCUS_EDITOR:
		default:                    mode_hint = "";
	}
	// The GUI has menus for all of this, so it shows only the mode.
	String hint_label = pixel_ui() ? string::tformat("  %s", mode_hint) : string::tformat(
		"  %s  %s focus  %s cycle  %s sidebar  %s shortcuts  %s quit ",
		mode_hint,
		key_style.render("Esc"),
		key_style.render("Tab"),
		key_style.render("Ctrl+B"),
		key_style.render("?"),
		key_style.render("Ctrl+Q"));

	String right_info = string::tformat("%s%s │ %s",
		file_label, cursor_label, self.status_msg);

	xray::LayoutMetrics metrics = milktea::layout_metrics();
	sz bar_extra = metrics.pixels
		? top_bar_pixel_height() - BAR_ROWS * metrics.unit_h() + BAR_PADDING_Y * 2 : 0;
	sz editor_h = (milktea::layout_area().h - bar_extra) / metrics.unit_h()
		- BAR_ROWS - STATUS_ROWS;
	if (editor_h < 1) editor_h = 1;

	// Every style the view draws with carries the editor background, so the
	// text area is one even colour out to its edges.
	self.doc.focused = self.focus == FOCUS_EDITOR;
	self.doc.text_style = glaze::style()
		.foreground(self.doc.focused ? th.editor_fg : th.dim).background(th.editor_bg);
	self.doc.gutter_style = glaze::style().foreground(th.line_num).background(th.editor_bg);
	self.doc.gutter_current_style = glaze::style().foreground(th.dim).background(th.editor_bg);
	self.doc.gutter_faded_style = glaze::style().foreground(th.line_faded).background(th.editor_bg);
	self.doc.selection_style = glaze::style().background(th.selection);
	self.doc.caret_style = glaze::style().foreground(th.ink).background(th.cursor);
	self.doc.current_line_style = glaze::style().foreground(th.editor_fg).background(th.current_line);
	self.doc.guide_style = glaze::style().foreground(th.guide);
	self.doc.guide_active_style = glaze::style().foreground(th.guide_active);
	// Scrollbar: a thin track (│) with a thicker thumb (┃) on the row
	// matching the view's place in the document. Both share the editor
	// background so the column reads as part of the page.
	self.doc.scrollbar_track_style = glaze::style()
		.foreground(th.line_num).background(th.editor_bg);
	glaze::Style thumb = glaze::style()
		.foreground(th.dim).background(th.editor_bg);
	self.doc.scrollbar_thumb_style = thumb.with_bold(true);
	self.syntax.highlight(&self.doc, self.current_file);

	self.browser.width = sidebar_content_width(self);
	self.browser.height = editor_h;

	// Editor area with 1-cell padding on every side, so the text and
	// line-number gutter sit inside a margin rather than flush against the
	// sidebar and the status bar.
	xray::Node* editor_col = xray::vstack().style(glaze::style().background(th.editor_bg).pad(1))
		.fill(1)
		.add(self.doc.node().fill(1));
	xray::Node* editor_row = sidebar_row(self, editor_col);

	xray::Node* status_row = milktea::hstack()
		.height(milktea::cells(1))
		.add(milktea::text(hint_label, status_style).fill(1))
		.add(milktea::text(right_info, status_style).fit_width());

	// The padding is the bar's own, so the whole strip reads as one bar out
	// to the ends the row of hints does not reach.
	xray::Node* statusbar = xray::vstack().style(status_style.pad_x(STATUS_PAD))
		.id("statusbar").role(STATUS)
		.height(milktea::cells(STATUS_ROWS))
		.add(status_row);

	statusbar.decorate(xray::linear(
		th.status_bg,
		th.bar, 90.0f).padding(BAR_PADDING_Y, BAR_PADDING_X, BAR_PADDING_Y, BAR_PADDING_X));

	sz sidebar_w = sidebar_panel_width(self);
	xray::Rect editor_area = {
		.x = sidebar_w,
		.y = BAR_ROWS,
		.w = self.win_w - sidebar_w,
		.h = editor_h,
	};

	// A terminal reports the pointer only in all-motion mode, which hover
	// needs. A window tracks hover itself, so the model only asks for moves
	// with the button held, and the rest redraw nothing.
	$if $feat(MILKTEA_GUI):
		milktea::set_mouse_mode(milktea::MouseMode.MOUSE_MODE_CELL_MOTION);
	$else
		milktea::set_mouse_mode(milktea::MouseMode.MOUSE_MODE_ALL_MOTION);
	$endif
	return milktea::root()
		.add(milktea::vstack()
			.add(self.menu_bar_node(th))
			.add(editor_row)
			.add(statusbar))
		.add(self.doc.completion_node(
			glaze::style().foreground(th.bar_text).background(th.bar),
			glaze::style().foreground(th.ink).background(th.accent)))
		.add(self.menu.dropdown())
		.add(self.shortcuts.node(th, editor_area))
		.add(self.about.node(th, editor_area))
		.add(self.quit_confirm.node(th, editor_area))
		.add(self.command_bar.node(th));
}

// menu_bar_node styles the menu bar from the theme: blocks of colour in a
// terminal; in the GUI a padded bar with rounded highlights and a floating,
// rounded dropdown. The bar keeps clear of the window buttons itself.
fn xray::Node* Editor.menu_bar_node(&self, Theme* th) {
	glaze::Style bar = { .bg = th.bar, .fg = th.bar_text };
	glaze::Style item = { .bg = th.bar, .fg = th.bar_text };
	self.menu.active = self.focus == FOCUS_MENU_BAR;
	self.menu = self.menu
		.with_styles(bar, bar, { .bg = th.selection, .fg = th.bar_text }, { .bg = th.accent, .fg = th.ink, .bold = true })
		.with_panel_styles({ .bg = th.bar, .fg = th.bar_text, .border = glaze::NORMAL, .border_color = th.text },
			item, { .bg = th.ink, .fg = th.accent, .bold = true }, { .fg = th.dim })
		.with_shapes(
			xray::solid().padding(BAR_PADDING_Y, BAR_PADDING_X, BAR_PADDING_Y, BAR_PADDING_X),
			xray::solid().round(HIGHLIGHT_RADIUS),
			xray::solid().round(HIGHLIGHT_RADIUS),
			xray::solid().round(PANEL_RADIUS)
				.with_border(1.0f, th.border)
				.with_shadow(0.0f, 10.0f, 30.0f, dye::color_rgba(0, 0, 0, 140))
				.with_inner_shadow(0.0f, 1.0f, 0.0f, dye::color_rgba(255, 255, 255, 22))
				.padding(PANEL_PAD_Y, 0, PANEL_PAD_Y, 0))
		.with_panel_shadow(milktea::shadow(2, 1).with_color(th.shadow));
	return self.menu.node();
}

// The GUI build (ted-gui) supplies its own main() in gui_main.c3.
fn int main(String[] args) @feat(!MILKTEA_GUI) {
	if (args.len > 1 && args[1] == "--render") return dump_render();
	// ted ctl SOCKET ...: drive a ted started with MILKTEA_CONTROL=SOCKET.
	if (args.len > 1 && args[1] == "ctl") return milktea::control_client(args[2..]);
	Editor e = { };
	if (args.len > 1) e.open_arg = args[1];
	return milktea::@run(&e, { .alt_screen = true });
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
	// Find and print every literal ` character (not in escape)
	for (usz i = 0; i < captured.len; i++) {
		if (captured[i] == 0x60) io::printfn("BACKTICK at %d", i);
	}
	return 0;
}
