module ted;

import milktea;
import milktea_gui;
import std::core::string;
import std::io::file;
import std::io::path;
import std::os::env;

// GUI_TEXT_DEFAULT is the only size to set by hand; everything else follows.
//
// raylib's font_size is the height of the whole line box, not the em: a glyph
// is rasterised so the font's ascent-to-descent span comes out that many
// points tall. So a cell that holds exactly one line is font_size tall, and
// as wide as one advance scaled the same way — advance over line box, both
// read off the font below.
//
// Sizing the row to the line box rather than to the em is what puts the text
// where a terminal puts it. A row taller than the line box is fine, because
// milktea splits the difference above and below (see cell_fit there); a row
// shorter than it clips, which is why cell_step_for only ever rounds up.
//
// tools/make_font.py holds every glyph to one advance, so these two numbers
// describe the merged symbols as well as the letters.
const int FONT_ADVANCE_EM = 600;  // JetBrains Mono hmtx, per 1000-unit em
const int FONT_LINE_EM = 1320;    // its hhea ascent 1020 over descent -300

// The cell sizes. A point size divides into whole cells only when it is a
// multiple of 11 — 600/1320 is 5/11 — so 11, 22 and 33 are exact; the rest
// are within 0.2 pt of a whole cell, which milktea splits either side of the
// glyph rather than letting it accumulate.
//
// This is the ladder of *cells*, not of text sizes. Any point size between
// the ends can be drawn (set_text_size); what the ladder decides is the cell
// it goes in, and so the size the box rules are drawn at. The rungs are named
// for their point size because that is all they are — a ladder of nine cells
// is past the point where TINY and HUGE mean anything.
//
// The gaps matter: a size sits in the first rung at least as tall as itself,
// so a sparse ladder puts small text in a tall cell. These are close enough
// together that no size is ever more than 2 pt short of its row.
enum FontSize : int (int pt)
{
	PT11 { 11 },
	PT13 { 13 },
	PT15 { 15 },
	PT18 { 18 },
	PT20 { 20 },
	PT22 { 22 },
	PT24 { 24 },
	PT31 { 31 },
	PT33 { 33 },
}

// 16 pt sits between rungs: the text draws at 16, centred in a 20 pt cell,
// with its rules at 20.
const int GUI_TEXT_DEFAULT = 16;

// Bounds for a size asked for by point rather than by rung. Below the first
// rung there is no cell to round up to, and above the last the ladder ends.
const int TEXT_PT_MIN = FontSize.PT11.pt;
const int TEXT_PT_MAX = FontSize.PT33.pt;

// cell_w_for is the same arithmetic for a size picked at run time.
fn int cell_w_for(int pt) =>
	(pt * FONT_ADVANCE_EM + FONT_LINE_EM / 2) / FONT_LINE_EM;

// cell_step_for picks the cell a point size is drawn into: the first rung of
// the ladder at least that tall. Rounding up rather than to the nearest is
// the only choice that works — a cell shorter than the text would clip it —
// so a 16 pt face gets the 20 pt cell, with the leftover 4 points split above
// and below the line by milktea, and its box rules drawn at 20 so they still
// meet across rows.
fn FontSize cell_step_for(int pt) {
	for (int i = 0; i <= (int)FontSize.PT33.ordinal; i++) {
		FontSize f = FontSize::from_ordinal(i);
		if (f.pt >= pt) return f;
	}
	return FontSize.PT33;
}

// The point size the text is drawing at now, and the rung its cell came from.
// They are equal at every rung of the ladder and differ only in between.
int g_text_pt @local = GUI_TEXT_DEFAULT;
FontSize g_font_size @local = FontSize.PT20;

fn FontSize font_size() => g_font_size;
fn int text_size() => g_text_pt;

// start_font_size reads TED_FONT_SIZE, so the window can be opened at a size
// other than the default — the same hook TED_FOCUS and TED_OPEN give the rest
// of the view, and the only way a screenshot can be taken at another size.
// A value that is not one of the ladder's point sizes is ignored.
fn int start_text_size() @local {
	if (try want = env::tget_var("TED_FONT_SIZE")) {
		if (try pt = want.to_int()) {
			if (pt >= TEXT_PT_MIN && pt <= TEXT_PT_MAX) return pt;
		}
	}
	return GUI_TEXT_DEFAULT;
}

fn bool set_font_size(FontSize size) => set_text_size(size.pt);

// set_text_size takes any point size, not only a rung. The cell follows from
// cell_step_for, so the grid stays whole whatever is asked for.
fn bool set_text_size(int pt) {
	if (pt < TEXT_PT_MIN || pt > TEXT_PT_MAX || pt == g_text_pt) return false;
	g_text_pt = pt;
	g_font_size = cell_step_for(pt);
	milktea_gui::set_cell_size(cell_w_for(g_font_size.pt), g_font_size.pt, pt);
	return true;
}

// zoom moves one point size, not one rung: every size between the ends of
// the ladder is reachable. The cell it lands in comes from cell_step_for, so
// a run of sizes shares a cell and the window keeps its column count until
// the next rung is crossed. At either end it stays put and reports false, so
// a caller can say so rather than silently doing nothing.
fn bool zoom(int steps) => set_text_size(g_text_pt + steps);

// The GUI uses JetBrains Mono, which ships with the app rather than the
// system. It has no braille, few geometric shapes and only some of the arrows
// the view draws — a sidebar full of holes without them — so
// tools/make_font.py merges those in from SF Mono and writes assets/fonts.
// The merged glyphs take the same 0.6 em advance as the rest, so the grid
// holds across the join.
//
// milktea reads MILKTEA_FONT ahead of every built-in candidate, so setting it
// here is all it takes to use the bundled font: nothing is installed, and the
// library is left unaware of this app's layout.
const String[*] GUI_FONT_FILES = {
	"TedMono-Regular.ttf",
};

// font_dirs lists the places the bundled font may sit, nearest first. c3c
// writes binaries to out/, so <binary>/../assets/fonts is the build tree;
// <binary>/assets/fonts covers a binary and its fonts shipped side by side,
// and the working directory covers a binary run from elsewhere in the tree.
fn String[] font_dirs() @local {
	String[] dirs = mem::new_array(String, 3);
	int n = 0;
	if (try exe = env::executable_path()) {
		dirs[n++] = string::tformat("%s/../assets/fonts", exe);
		dirs[n++] = string::tformat("%s/assets/fonts", exe);
	}
	if (try cwd = path::tcwd()) {
		dirs[n++] = string::tformat("%s/assets/fonts", cwd);
	}
	return dirs[:n];
}

// use_app_font points MILKTEA_FONT at the bundled font. When neither file
// turns up — or when the caller already named a font — the environment is
// left alone, so a missing font costs the app its preferred face rather than
// its text.
fn void use_app_font() @local {
	if (try current = env::tget_var("MILKTEA_FONT")) {
		if (current.len > 0) return;
	}
	foreach (dir : font_dirs()) {
		foreach (name : GUI_FONT_FILES) {
			String p = string::tformat("%s/%s", dir, name);
			if (file::exists(p)) {
				env::set_var("MILKTEA_FONT", p, true);
				return;
			}
		}
	}
}

// GUI entrypoint, built only by the ted-gui target (see project.json). The
// terminal build uses ted.c3's main() instead and never links raylib. Same
// model and same view tree either way; only the display changes.
//
// With TED_SHOT=<path.png> the window renders a single frame, writes it out,
// and exits. That is how the layout is inspected without a human watching.
// Raylib only writes screenshots inside its working directory, so put a
// relative path there (for example TED_SHOT=out/ted.png).
fn int main() {
	Editor e = { };
	// The window has no title bar of its own and no buttons from the
	// platform either: the top row of the view stands in for both, drawing
	// its own close/minimise/zoom glyphs (see chrome.c3) and letting a drag
	// anywhere between them and the menu titles move the window. The cells
	// reserved for those glyphs are the app's own count, not the platform's:
	// with the buttons hidden there is nothing left to measure.
	g_text_pt = start_text_size();
	g_font_size = cell_step_for(g_text_pt);
	int cell_w = cell_w_for(g_font_size.pt);
	e.chrome_cells = chrome_on_left() ? CHROME_CELLS : 0;
	use_app_font();
	String? shot = env::tget_var("TED_SHOT");
	milktea_gui::run((milktea::Model)&e, {
		.title = "ted",
		.cols = 100, .rows = 30,
		.cell_w = cell_w, .cell_h = g_font_size.pt,
		.font_size = g_text_pt,
		.chrome_rows = 1,
		.hide_window_buttons = true,
		.screenshot_path = shot ?? "",
	});
	return 0;
}
