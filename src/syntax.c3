module ted;

import boba;
import glaze;
import ink::token;
import ink::style;
import ink::colour;
import ink::themes;
import ink::lexer;
import ink::lang_registry;
import ink::ts_bind;
import std::os::env;

// Syntax highlighting, by ink: a tree-sitter grammar parses the buffer, the
// grammar's highlight query names the parts, and a theme colors them. The
// result goes to the textarea as highlight spans, which it draws over the
// editor's own style.
//
// Grammars are shared libraries in vendor/ink.c3l/grammars, loaded when the
// first file is highlighted; the queries are compiled in. A file whose
// extension no grammar claims, or a build run from somewhere the grammars
// can't be found, is shown plain.

extern fn void* dlopen(char* filename, int flag);
extern fn void* dlsym(void* handle, char* symbol);
const int RTLD_NOW = 2;

alias TsLanguageFn = fn ts_bind::TSLanguage*();

const char[] QUERY_C = $embed("../vendor/ink.c3l/data/queries/c/highlights.scm");
const char[] QUERY_C3 = $embed("../vendor/ink.c3l/data/queries/c3/highlights.scm");
const char[] QUERY_GO = $embed("../vendor/ink.c3l/data/queries/go/highlights.scm");
const char[] QUERY_PYTHON = $embed("../vendor/ink.c3l/data/queries/python/highlights.scm");
const char[] QUERY_RUST = $embed("../vendor/ink.c3l/data/queries/rust/highlights.scm");

const String SYNTAX_THEME = "monokai";
const int MAX_SPANS = 4096;
const int MAX_PATH = 256;

struct Syntax {
	bool loaded;
	style::Style* theme;
	// The lexer for the file in path, or null to show it plain.
	lexer::Lexer* lexer;
	char[MAX_PATH] path_buf;
	sz path_len;
	// The text the spans were made from, to tell when they're stale.
	char[4096] text_buf;
	sz text_len;
	// Heap-allocated on load: a span carries a whole glaze style, so a full
	// set is too big to live in the Editor, which sits on the stack.
	boba::HighlightSpan[] spans;
	int span_count;
}

// grammar_dirs are where the grammars may be: beside the working directory
// (running from the repo) or beside the executable (out/ted).
fn String[] grammar_dirs() @local {
	String dir = "";
	if (try exe = env::executable_path()) {
		for (sz i = exe.len; i > 0; i--) {
			if (exe[i - 1] == '/') { dir = exe[:i - 1]; break; }
		}
	}
	String[] dirs = mem::talloc_array(String, 3);
	dirs[0] = "vendor/ink.c3l/grammars";
	dirs[1] = string::tformat("%s/../vendor/ink.c3l/grammars", dir);
	dirs[2] = string::tformat("%s/vendor/ink.c3l/grammars", dir);
	return dirs;
}

fn void load_grammar(String name, String[] aliases, String[] extensions, String query) @local {
	ZString sym = string::tformat("tree_sitter_%s", name).zstr_tcopy();
	foreach (dir : grammar_dirs()) {
		ZString lib = string::tformat("%s/libtree-sitter-%s.dylib", dir, name).zstr_tcopy();
		void* h = dlopen(lib, RTLD_NOW);
		if (h == null) continue;
		TsLanguageFn make = (TsLanguageFn)dlsym(h, sym);
		if (make == null) continue;
		ts_bind::TSLanguage* lang = make();
		if (lang == null) continue;
		lang_registry::register_language(name, aliases, extensions, lang, query);
		return;
	}
}

fn void Syntax.load(&self) {
	self.loaded = true;
	self.spans = mem::new_array(boba::HighlightSpan, MAX_SPANS);
	themes::register_all_themes();
	self.theme = style::styles_get(SYNTAX_THEME);
	load_grammar("c", { "c" }, { ".c", ".h" }, (String)QUERY_C);
	load_grammar("c3", { "c3" }, { ".c3", ".c3i" }, (String)QUERY_C3);
	load_grammar("go", { "go", "golang" }, { ".go" }, (String)QUERY_GO);
	load_grammar("python", { "python", "py" }, { ".py" }, (String)QUERY_PYTHON);
	load_grammar("rust", { "rust", "rs" }, { ".rs" }, (String)QUERY_RUST);
}

// span_style turns a theme entry into what the textarea draws a span with.
// Only the foreground and the attributes: the editor keeps its background.
fn glaze::Style span_style(style::StyleEntry e) @local {
	glaze::Style s = { .bold = e.bold, .italic = e.italic, .underline = e.underline };
	if (colour::colour_is_set(e.fg)) {
		s.fg = {
			.kind = glaze::ColorKind.TRUECOLOR,
			.r = colour::colour_red(e.fg),
			.g = colour::colour_green(e.fg),
			.b = colour::colour_blue(e.fg),
		};
	}
	return s;
}

// highlight brings the textarea's spans up to date with its text and the
// file it holds. It re-parses only when one of them has changed since last
// time, so calling it every frame costs a comparison.
fn void Syntax.highlight(&self, boba::Textarea* ta, String path) {
	if (!self.loaded) self.load();

	bool stale = false;
	if (path != (String)self.path_buf[:self.path_len]) {
		sz n = path.len < MAX_PATH ? path.len : MAX_PATH;
		self.path_buf[:n] = path[:n];
		self.path_len = n;
		self.lexer = null;
		if (path.len > 0 && self.theme != null) {
			if (try l = lang_registry::find_lexer_by_filename(path)) self.lexer = l;
		}
		stale = true;
	}
	if (self.lexer == null) {
		ta.highlights = {};
		return;
	}

	String text = ta.text();
	if (stale || text != (String)self.text_buf[:self.text_len]) {
		self.text_buf[:text.len] = text[..];
		self.text_len = text.len;
		self.span_count = 0;
		@pool() {
			if (try it = self.lexer.tokenise(text)) {
				sz at = 0;
				while (try tok = token::token_iterator_next(it)) {
					style::StyleEntry e = style::style_get(self.theme, tok.type);
					bool styled = colour::colour_is_set(e.fg) || e.bold || e.italic || e.underline;
					if (styled && tok.value.len > 0 && self.span_count < MAX_SPANS) {
						self.spans[self.span_count++] = { .start = at, .len = tok.value.len, .style = span_style(e) };
					}
					at += tok.value.len;
				}
			}
		};
	}
	ta.highlights = self.spans[:self.span_count];
}
