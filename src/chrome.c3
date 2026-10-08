module ted;

import milktea;
import glaze;
import xray;
import raylib6::rl;

// Custom window controls use the macOS helper's 14-point fallback diameter.
const sz LIGHT_PITCH = 20;
const sz CHROME_CELLS = 7;

fn void close_clicked(void* id, String id_str, sz col, sz row) @local {
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

fn void minimise_clicked(void* id, String id_str, sz col, sz row) @local {
	rl::minimize_window();
}

fn void zoom_clicked(void* id, String id_str, sz col, sz row) @local {
	if (rl::is_window_maximized()) {
		rl::restore_window();
	} else {
		rl::maximize_window();
	}
}

// AppKit's own geometry: the first button sits 12pt in from the window's
// left edge, and each one is LIGHT_PITCH from the last.
const sz LIGHT_FIRST_X = 12;

// Light is one of the three buttons: its colour, the glyph macOS shows on it
// while the pointer is over the group, and that glyph's colour, a dark shade
// of the button's own rather than a flat grey.
struct Light {
	String fill;
	String glyph;
	String glyph_fill;
	xray::ClickFn on;
}

const Light[3] LIGHTS = {
	{ "#ff5f57", "×", "#8c1a10", &close_clicked },
	{ "#febc2e", "–", "#985712", &minimise_clicked },
	{ "#28c840", "+", "#0b650d", &zoom_clicked },
};

// macOS shows the glyphs on all three buttons at once, whenever the pointer
// is anywhere over the group, so hover is tracked on the strip, not per light.
fn void lights_hover_in(void* id, String id_str, sz col, sz row) @local {
	((Editor*)id).lights_hover = true;
}

fn void lights_hover_out(void* id, String id_str, sz col, sz row) @local {
	((Editor*)id).lights_hover = false;
}

fn xray::Node* light(Light l, bool hovered) @local {
	xray::Node* circle = milktea::vstack()
		.width(xray::pixels(WINDOW_LIGHT_DIAMETER))
		.height(xray::pixels(WINDOW_LIGHT_DIAMETER))
		.center()
		.decorate(xray::solid(glaze::color_hex(l.fill)).round((float)WINDOW_LIGHT_DIAMETER / 2.0f));
	// The slot is the pitch wide with the circle centred in it. The glyph is
	// a sibling rather than a child: text takes whole rows, and a row does
	// not fit inside the circle, so it is centred over the slot instead.
	xray::Node* slot = milktea::zstack().width(xray::pixels(LIGHT_PITCH))
		.on_click(l.on).add(circle);
	if (hovered) {
		// Content of a decorated node is painted over the decoration with a
		// clear background; an invisible one is enough to get that, so the
		// circle shows around the glyph instead of a black cell.
		glaze::Style g = { .fg = glaze::color_hex(l.glyph_fill), .bold = true };
		slot.add(milktea::text(g, l.glyph).width(milktea::cells(1)).height(milktea::cells(1)).center()
			.decorate(xray::solid(xray::color_transparent())));
	}
	return slot;
}

// window_lights builds the button strip. It reserves whole text cells so the
// menu titles and their dropdowns share an origin after it.
fn xray::Node* window_lights(Theme* th, Editor* e) {
	sz cell_w = milktea::layout_metrics().unit_w();
	// The bar's own padding already moves the strip BAR_PADDING_X in, and
	// each circle sits centred in its slot.
	sz lead = LIGHT_FIRST_X - BAR_PADDING_X - (LIGHT_PITCH - WINDOW_LIGHT_DIAMETER) / 2;
	sz strip_cells = 1 + (lead + LIGHT_PITCH * 3 + cell_w - 1) / cell_w;
	e.chrome_cells = chrome_on_left() ? strip_cells : 0;
	e.menu.x_inset = e.chrome_cells;

	xray::Node* group = milktea::hstack().width(xray::pixels(LIGHT_PITCH * 3))
		.id_with(e).on_hover_in(&lights_hover_in).on_hover_out(&lights_hover_out);
	foreach (i, l : LIGHTS) {
		xray::Node* n = light(l, e.lights_hover);
		if (i == 0) n.id_with(e);
		group.add(n);
	}
	return milktea::hstack()
		.width(milktea::cells(strip_cells))
		.add(milktea::hstack().width(xray::pixels(lead)))
		.add(group);
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
