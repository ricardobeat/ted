module ted;

import boba;
import glaze;
import ink::token;
import ink::style;
import ink::colour;
import ink::themes;
import ink::lexer;
import ink::grammars;
import std::os::env;
import std::collections::list;

// Syntax highlighting, by ink: a tree-sitter grammar parses the buffer, the
// grammar's highlight query names the parts, and a theme colors them. The
// result goes to the textarea as highlight spans, which it draws over the
// editor's own style.
//
// ink picks the language from the file name and loads its grammar and query
// from vendor/ink.c3l the first time a file needs them. A file no grammar
// claims, or a build run from somewhere ink.c3l can't be found, is shown
// plain.

const String SYNTAX_THEME = "monokai";
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
	list::List{boba::HighlightSpan} spans;
}

// ink_roots are where ink.c3l may be: under the working directory (running
// from the repo) or beside the executable (out/ted).
fn String[] ink_roots() @local {
	String dir = "";
	if (try exe = env::executable_path()) {
		for (sz i = exe.len; i > 0; i--) {
			if (exe[i - 1] == '/') { dir = exe[:i - 1]; break; }
		}
	}
	String[] roots = mem::talloc_array(String, 3);
	roots[0] = "vendor/ink.c3l";
	roots[1] = string::tformat("%s/../vendor/ink.c3l", dir);
	roots[2] = string::tformat("%s/vendor/ink.c3l", dir);
	return roots;
}

fn void Syntax.load(&self) {
	self.loaded = true;
	// The spans are rebuilt inside a temp pool; set the heap allocator up
	// front, or the list would take the pool's and lose its storage with it.
	self.spans.init(mem);
	themes::register_all_themes();
	self.theme = style::styles_get(SYNTAX_THEME);
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
			if (try l = grammars::lexer_for_file(path, ink_roots())) self.lexer = l;
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
		self.spans.clear();
		@pool() {
			if (try it = self.lexer.tokenise(text)) {
				sz at = 0;
				while (try tok = token::token_iterator_next(it)) {
					style::StyleEntry e = style::style_get(self.theme, tok.type);
					bool styled = colour::colour_is_set(e.fg) || e.bold || e.italic || e.underline;
					if (styled && tok.value.len > 0) {
						self.spans.push({ .start = at, .len = tok.value.len, .style = span_style(e) });
					}
					at += tok.value.len;
				}
			}
		};
	}
	ta.highlights = self.spans.array_view();
}
