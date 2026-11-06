module ted;

import ted::editor;
import std::encoding::json;
import std::collections::object;
import std::io;
import std::io::file;
import std::os::env;

// Settings come from an optional JSON file; there is no UI for them. The
// file is read once, at startup, from the first of:
//
//   $TED_SETTINGS
//   $XDG_CONFIG_HOME/ted/settings.json
//   ~/.config/ted/settings.json
//
// Every key is optional, and comments are allowed:
//
//   {
//     "caret": "block",           // "block", "bar" or "underline"
//     "font_size": 16,            // points, 11 to 33 (window only)
//     "font_family": "Menlo",     // a font name or a file (window only)
//     "word_wrap": false,
//     "line_numbers": true,
//     "indent_guides": "current"  // "current", "all" or "none"
//   }
//
// A missing file is the defaults. A file that cannot be read, or a value
// that makes no sense, is reported in the status bar and otherwise ignored.
struct Settings {
	editor::CaretKind caret;
	// 0 leaves the window at its default size.
	sz font_size;
	// Empty uses the bundled font.
	String font_family;
	bool word_wrap;
	bool line_numbers;
	editor::GuideMode indent_guides;
	// The path read, and what was wrong with it, if anything.
	String path;
	String problem;
}

Settings g_settings @local;
bool g_settings_loaded @local;

// settings reads the settings file the first time it is asked for.
fn Settings* settings() {
	if (!g_settings_loaded) {
		g_settings_loaded = true;
		g_settings = load_settings();
	}
	return &g_settings;
}

fn Settings default_settings() @local {
	return {
		.caret = BLOCK,
		.word_wrap = false,
		.line_numbers = true,
		.indent_guides = CURRENT,
	};
}

fn String settings_path() @local {
	if (try p = env::tget_var("TED_SETTINGS")) {
		if (p.len > 0) return p;
	}
	if (try x = env::tget_var("XDG_CONFIG_HOME")) {
		if (x.len > 0) return string::tformat("%s/ted/settings.json", x);
	}
	if (try h = env::tget_var("HOME")) return string::tformat("%s/.config/ted/settings.json", h);
	return "";
}

fn Settings load_settings() @local {
	Settings s = default_settings();
	String path = settings_path();
	if (path.len == 0 || !file::exists(path)) return s;
	s.path = path.copy(mem);
	@pool() {
		s.read_file(path);
	};
	if (s.problem.len) io::eprintn(s.problem);
	return s;
}

fn void Settings.read_file(&self, String path) {
	char[]? data = file::load_temp(path);
	if (catch data) {
		self.problem = string::format(mem, "Settings: could not read %s", path);
		return;
	}
	Object*? root = ((String)data).tparse_json();
	if (catch root) {
		self.problem = string::format(mem, "Settings: %s is not valid JSON", path);
		return;
	}
	if (!root.is_map()) {
		self.problem = string::format(mem, "Settings: %s should hold an object", path);
		return;
	}
	self.read(root);
}

// read takes the values the file sets, each checked; the first bad one is
// the problem reported, and keeps its default.
fn void Settings.read(&self, Object* root) {
	if (root.has_key("caret")) {
		String? v = root.get_string("caret");
		if (try v) {
			switch (v) {
				case "block": self.caret = BLOCK;
				case "bar": self.caret = BAR;
				case "underline": self.caret = UNDERLINE;
				default: self.bad("caret", "\"block\", \"bar\" or \"underline\"");
			}
		} else {
			self.bad("caret", "\"block\", \"bar\" or \"underline\"");
		}
	}
	if (root.has_key("font_size")) {
		double? v = root.get_float("font_size");
		if (try v) {
			self.font_size = (sz)(v + 0.5);
		} else {
			self.bad("font_size", "a number");
		}
	}
	if (root.has_key("font_family")) {
		String? v = root.get_string("font_family");
		if (try v) {
			self.font_family = v.copy(mem);
		} else {
			self.bad("font_family", "a font name or path");
		}
	}
	if (root.has_key("word_wrap")) {
		bool? v = root.get_bool("word_wrap");
		if (try v) { self.word_wrap = v; } else { self.bad("word_wrap", "true or false"); }
	}
	if (root.has_key("line_numbers")) {
		bool? v = root.get_bool("line_numbers");
		if (try v) { self.line_numbers = v; } else { self.bad("line_numbers", "true or false"); }
	}
	if (root.has_key("indent_guides")) {
		String? v = root.get_string("indent_guides");
		if (try v) {
			switch (v) {
				case "current": self.indent_guides = CURRENT;
				case "all": self.indent_guides = ALL;
				case "none": self.indent_guides = NONE;
				default: self.bad("indent_guides", "\"current\", \"all\" or \"none\"");
			}
		} else {
			self.bad("indent_guides", "\"current\", \"all\" or \"none\"");
		}
	}
}

fn void Settings.bad(&self, String key, String want) {
	if (self.problem.len) return;
	self.problem = string::format(mem, "Settings: %s should be %s", key, want);
}

// apply_settings gives the editor view what the settings say about it.
fn void Editor.apply_settings(&self) {
	Settings* s = settings();
	self.doc.set_caret_kind(s.caret);
	self.doc.wrap = s.word_wrap;
	self.doc.line_numbers = s.line_numbers;
	self.doc.guides = s.indent_guides;
	if (s.problem.len) self.status_msg = s.problem;
}
