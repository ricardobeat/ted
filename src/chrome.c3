module ted;

import milktea;
import glaze;
import xray;
import raylib6::rl;

// Custom window controls use the macOS helper's 14-point fallback diameter.
const int LIGHT_PITCH = 20;
const int CHROME_CELLS = 7;

fn void close_clicked(void* id, String id_str, int col, int row) @local {
	// request_quit() asks the loop to stop, which tears raylib/GLFW down in
	// the right order. A click handler returns void, so the Cmd quit()
	// builds has nowhere to go — request_quit() is the same request through
	// the message queue, which every backend drains each frame. Calling
	// rl::close_window() here would yank GLFW out from under milktea
	// mid-frame and leave it logging "GLFW library is not initialized" on
	// every later raylib call.
	// With unsaved changes the editor asks first, the same as Ctrl+Q.
	Editor* e = (Editor*)id;
	if (e && e.modified) {
		e.quit_confirm.show();
		e.quit_confirm.focused = 1;
		return;
	}
	milktea::request_quit();
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

fn xray::Node* light(glaze::Color fg, xray::ClickFn on) @local {
	xray::Node* circle = milktea::vstack()
		.width(xray::pixels(WINDOW_LIGHT_DIAMETER))
		.height(xray::pixels(WINDOW_LIGHT_DIAMETER))
		.center()
		.decorate(xray::solid(milktea::to_cell_color(fg)).round((float)WINDOW_LIGHT_DIAMETER / 2.0f));
	return milktea::zstack().width(xray::pixels(LIGHT_PITCH))
		.on_click(on).add(circle);
}

// Reserve whole text cells so menu titles and their dropdowns share an origin.
// Each slot remains wide enough for a system-sized circle at small font sizes.
fn xray::Node* window_lights(Theme* th, Editor* e) {
	glaze::Style filler = { .bg = th.bar };
	int cell_w = milktea::layout_metrics().unit_w();
	int strip_cells = 1 + (LIGHT_PITCH * 3 + cell_w - 1) / cell_w;
	e.chrome_cells = chrome_on_left() ? strip_cells : 0;
	e.menu.x_inset = e.chrome_cells;
	return milktea::hstack()
		.width(milktea::cells(strip_cells))
		.add(milktea::text(filler, "").width(milktea::cells(1)))
		.add(light(glaze::color_hex("#ff5f57"), &close_clicked).id_with(e))
		.add(light(glaze::color_hex("#febc2e"), &minimise_clicked))
		.add(light(glaze::color_hex("#28c840"), &zoom_clicked));
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
