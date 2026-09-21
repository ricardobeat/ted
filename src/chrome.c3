module ted;

import milktea;
import glaze;
import xray;
import raylib6::rl;

// The GUI window has no title bar of its own (see gui_main.c3), and it asks
// the platform to take its close/minimise/zoom buttons away with it. What
// stands in for them lives here: three round glyphs drawn in the top row of
// the view, on the left where macOS puts them and on the right everywhere
// else. They are ordinary cells with ordinary click handlers, so they follow
// the app's font and theme rather than the platform's.
const int LIGHT_CELLS = 2; // one glyph plus the gap after it
const int CHROME_CELLS = 1 + LIGHT_CELLS * 3; // a cell of margin, then three

const String LIGHT_GLYPH = "●";

fn void close_clicked(void* id, String id_str, int col, int row) @local {
	// milktea::quit() asks the framework to stop its main loop, which tears
	// raylib/GLFW down in the right order. Calling rl::close_window() here
	// would yank GLFW out from under milktea mid-frame and leave it logging
	// "GLFW library is not initialized" on every later raylib call.
	milktea::quit();
}

fn void minimise_clicked(void* id, String id_str, int col, int row) @local {
	rl::minimize_window();
}

fn void zoom_clicked(void* id, String id_str, int col, int row) @local {
	if (rl::is_window_maximized()) {
		rl::restore_window();
	} else {
		rl::maximize_window();
	}
}

fn xray::Node* light(glaze::Color bg, glaze::Color fg, xray::ClickFn on) @local {
	glaze::Style s = { .bg = bg, .fg = fg };
	xray::Node* n = milktea::text(s, s.render(LIGHT_GLYPH))
		.width(milktea::cells(LIGHT_CELLS));
	n.on_click(on);
	return n;
}

// window_lights builds the button strip. It is CHROME_CELLS wide, which is
// what Editor.chrome_cells reserves at whichever end of the bar the platform
// would have used, so the menu titles and their dropdowns start clear of it.
fn xray::Node* window_lights(Theme* th) {
	glaze::Style filler = { .bg = th.bar };
	return milktea::hstack()
		.height(milktea::cells(1))
		.width(milktea::cells(CHROME_CELLS))
		.add(milktea::text(filler, "").width(milktea::cells(1)))
		.add(light(th.bar, glaze::color_hex("#ff5f57"), &close_clicked))
		.add(light(th.bar, glaze::color_hex("#febc2e"), &minimise_clicked))
		.add(light(th.bar, glaze::color_hex("#28c840"), &zoom_clicked));
}

// chrome_on_left reports which end of the bar the buttons take. macOS puts
// its own at the left, and everyone else at the right; the app follows suit
// so a window still looks like one of the platform's.
fn bool chrome_on_left() {
	$if env::DARWIN:
		return true;
	$else
		return false;
	$endif
}
