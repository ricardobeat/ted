module ted;

import ted::editor;
import glaze;
import ink::token;
import ink::style;
import ink::colour;
import ink::themes;
import ink::lexer;
import ink::grammars;
import ink::helix;
import ink::tree;
import std::collections::list;
import std::os::env;

// Syntax highlighting, by ink: a tree-sitter grammar parses the buffer, the
// grammar's highlight query names the parts, and a theme colors them. The
// result is the editor view's "syntax" decoration layer, which it draws
// under any other.
//
// ink picks the language from the file name and loads its grammar and query
// from vendor/ink.c3l the first time a file needs them. A file no grammar
// claims, or a build run from somewhere ink.c3l can't be found, is shown
// plain.

const String SYNTAX_THEME = "monokai";
const int MAX_PATH = 256;

struct Syntax (editor::Assist) {
	bool loaded;
	style::Style* theme;
	// The lexer for the file in path, or null to show it plain.
	lexer::Lexer* lexer;
	char[MAX_PATH] path_buf;
	sz path_len;
	// The buffer version the layer was made from, to tell when it is stale.
	int version;
	// The file's language in Helix's registry, for its auto-pairs.
	helix::Language* language;
	// The view being highlighted, and its syntax tree, parsed when asked
	// for and kept until the text changes.
	editor::View* view;
	tree::Tree tree;
	int tree_version;
	bool has_tree;
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

// reset forgets the file, the tree and what they were made from, for a view
// that is starting over.
fn void Syntax.reset(&self) {
	self.drop_tree();
	*self = {};
}

fn void Syntax.load(&self) {
	self.loaded = true;
	themes::register_all_themes();
	self.theme = style::styles_get(SYNTAX_THEME);
}

// span_style turns a theme entry into what the view draws a span with. Only
// the foreground and the attributes: the editor keeps its background.
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

// highlight brings the view's syntax layer up to date with its text and the
// file it holds. It re-parses only when one of them has changed since last
// time, so calling it every frame costs a comparison.
fn void Syntax.highlight(&self, editor::View* view, String path) {
	if (!self.loaded) self.load();
	self.view = view;
	editor::Layer* layer = view.layer("syntax", -1);

	bool stale = view.buf.version != self.version;
	if (path != (String)self.path_buf[:self.path_len]) {
		sz n = path.len < MAX_PATH ? path.len : MAX_PATH;
		self.path_buf[:n] = path[:n];
		self.path_len = n;
		self.lexer = null;
		self.language = null;
		self.drop_tree();
		if (path.len > 0 && self.theme != null) {
			if (try l = grammars::lexer_for_file(path, ink_roots())) self.lexer = l;
			if (try hl = helix::language_for_file(path)) self.language = hl;
		}
		// The language's own pairs, if it lists them; none if it turns
		// pairing off; the editor's defaults otherwise.
		if (self.language && self.language.no_auto_pairs) {
			view.set_pairs({});
		} else if (self.language && self.language.auto_pairs.len() > 0) {
			view.set_pairs(self.language.auto_pairs.array_view());
		} else {
			view.set_pairs(&editor::DEFAULT_PAIRS);
		}
		stale = true;
	}
	if (!stale) return;
	self.version = view.buf.version;
	layer.clear();
	if (self.lexer == null) return;

	@pool() {
		if (try it = self.lexer.tokenise(view.text())) {
			sz at = 0;
			while (try tok = token::token_iterator_next(it)) {
				style::StyleEntry e = style::style_get(self.theme, tok.type);
				bool styled = colour::colour_is_set(e.fg) || e.bold || e.italic || e.underline;
				if (styled) layer.style(at, at + tok.value.len, span_style(e));
				at += tok.value.len;
			}
		}
	};
}

// ── what the editor asks of the language (editor::Assist) ────────────────

fn tree::Tree*? Syntax.parsed(&self) {
	if (self.lexer == null || self.view == null) return tree::NO_GRAMMAR~;
	if (self.has_tree && self.tree_version == self.view.buf.version) return &self.tree;
	self.drop_tree();
	self.tree = tree::parse(self.lexer, self.view.text())!;
	self.has_tree = true;
	self.tree_version = self.view.buf.version;
	return &self.tree;
}

fn void Syntax.drop_tree(&self) {
	if (self.has_tree) self.tree.free();
	self.has_tree = false;
}

// context_at says whether pos is inside a string or a comment, by the kind
// of the nodes around it. A string's end is outside it — just past the
// closing quote is code again — but a line comment runs to the end of the
// line, so its end and anything after it on the line are still in it; only
// a comment closed with */ ends where its node does.
fn editor::Context Syntax.context_at(&self, sz pos) @dynamic {
	tree::Tree*? t = self.parsed();
	if (catch t) return CODE;
	// A line comment runs to the end of its line, past where its node stops
	// (grammars leave trailing spaces out): if the last thing before pos on
	// the line is in one, so is pos.
	String text = self.view.text();
	sz q = pos;
	while (q > 0 && (text[q - 1] == ' ' || text[q - 1] == '\t')) q--;
	if (q > 0 && q < pos && text[q - 1] != '\n') {
		for (tree::Node n = t.node_at(q - 1, q - 1); !n.is_null(); n = n.parent()) {
			if (n.kind().contains("comment") && !n.text().ends_with("*/")) return COMMENT;
		}
	}
	for (tree::Node n = t.node_at(pos, pos); !n.is_null(); n = n.parent()) {
		if (pos <= n.start() || pos > n.end()) continue;
		String k = n.kind();
		if (k.contains("comment")) {
			if (pos < n.end() || !n.text().ends_with("*/")) return COMMENT;
			continue;
		}
		if (pos == n.end()) continue;
		if (k.contains("string") || k.contains("char_literal")) return STRING;
	}
	return CODE;
}

fn String? Syntax.tag_to_close(&self, sz pos) @dynamic {
	tree::Tree* t = self.parsed()!;
	return t.tag_to_close(pos);
}

// completions offers the file's identifiers and the keywords it uses: the
// leaves of its syntax tree that name something (identifiers, types, fields,
// properties, tags) or that are words of the language itself.
fn void Syntax.completions(&self, sz pos, String prefix, List{String}* out) @dynamic {
	tree::Tree*? t = self.parsed();
	if (catch t) {
		self.view.buffer_words(pos - prefix.len, out);
		return;
	}
	List{tree::Node} stack;
	stack.init(tmem);
	stack.push(t.root());
	while (stack.len() > 0) {
		tree::Node n = stack.pop()!!;
		uint count = n.child_count();
		if (count > 0) {
			for (uint i = 0; i < count; i++) stack.push(n.child(i));
			continue;
		}
		// The word being typed is not its own completion.
		if (n.start() == pos - prefix.len) continue;
		if (n.is_named() ? names_something(n.kind()) : is_keyword(n.kind())) out.push(n.text());
	}
}

fn bool names_something(String kind) @local {
	return kind.contains("identifier") || kind.contains("name") || kind == "ident"
		|| kind.ends_with("_ident") || kind == "type" || kind == "property";
}

fn bool is_keyword(String kind) @local {
	if (kind.len < 2) return false;
	foreach (c : kind) if (!c.is_alpha() && c != '_') return false;
	return true;
}
