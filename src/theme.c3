module ted;

import glaze;
import milktea;
import xray;
import dye;

struct Theme {
	String name;
	glaze::Color bg;
	glaze::Color bar;
	glaze::Color bar_text;
	glaze::Color panel;
	glaze::Color text;
	glaze::Color dim;
	glaze::Color accent;
	glaze::Color ink;
	glaze::Color shadow;
	glaze::Color border;
	glaze::Color cursor;
	glaze::Color selection;
	glaze::Color status_bg;
	glaze::Color status_fg;
	glaze::Color browser_bg;
	glaze::Color browser_fg;
	glaze::Color browser_cursor;
	glaze::Color browser_dir;
	glaze::Color editor_fg;
	glaze::Color editor_bg;
	glaze::Color line_num;
}

fn Theme default_theme() {
	return {
		.name = "Default",
		.bg = glaze::color_hex("#1e1e2e"),
		.bar = glaze::color_hex("#313244"),
		.bar_text = glaze::color_hex("#cdd6f4"),
		.panel = glaze::color_hex("#1e1e2e"),
		.text = glaze::color_hex("#cdd6f4"),
		.dim = glaze::color_hex("#6c7086"),
		.accent = glaze::color_hex("#89b4fa"),
		.ink = glaze::color_hex("#1e1e2e"),
		.shadow = glaze::color_hex("#11111b"),
		.border = glaze::color_hex("#45475a"),
		.cursor = glaze::color_hex("#f5e0dc"),
		.selection = glaze::color_hex("#45475a"),
		.status_bg = glaze::color_hex("#313244"),
		.status_fg = glaze::color_hex("#a6adc8"),
		.browser_bg = glaze::color_hex("#181825"),
		.browser_fg = glaze::color_hex("#cdd6f4"),
		.browser_cursor = glaze::color_hex("#f38ba8"),
		.browser_dir = glaze::color_hex("#89b4fa"),
		.editor_fg = glaze::color_hex("#cdd6f4"),
		.editor_bg = glaze::color_hex("#1e1e2e"),
		.line_num = glaze::color_hex("#585b70"),
	};
}

// ── Floating panels ─────────────────────────────────────────────────────────
//
// Menus and dialogs float over the editor. In a terminal they are a box of
// border glyphs with a cell shadow; in the GUI they are drawn the way macOS
// draws its own: a rounded fill with a hairline border, a soft drop shadow,
// and a faint highlight along the inside of the top edge.

const float PANEL_RADIUS = 8.0f;

// pixel_ui reports whether the view is laid out in pixels, which is to say
// running in the GUI, where decorations are drawn.
fn bool pixel_ui() => milktea::layout_metrics().pixels;

// panel_style takes a floating panel's style as the terminal wants it and
// returns the one to build the node with. The GUI draws the border itself,
// so the glyph border goes and its cell is kept as padding: the content sits
// where it would have, and the panel keeps its size.
fn glaze::Style panel_style(glaze::Style s) {
	if (!pixel_ui()) return s;
	if (s.border.top.len > 0) s.pad_top++;
	if (s.border.right.len > 0) s.pad_right++;
	if (s.border.bottom.len > 0) s.pad_bottom++;
	if (s.border.left.len > 0) s.pad_left++;
	s.border = {};
	return s;
}

// floating decorates a panel node built from panel_style: the vector panel
// in the GUI, the cell shadow in a terminal.
fn xray::Node* floating(xray::Node* n, Theme* th, glaze::Color fill, glaze::Color border) {
	if (!pixel_ui()) {
		return n.shadow(milktea::shadow(2, 1).with_color(th.shadow));
	}
	return n.decorate(xray::solid(fill)
		.round(PANEL_RADIUS)
		.with_border(1.0f, border)
		.with_shadow(0.0f, 10.0f, 30.0f, dye::color_rgba(0, 0, 0, 140))
		.with_inner_shadow(0.0f, 1.0f, 0.0f, dye::color_rgba(255, 255, 255, 22)));
}

// ── Highlights ─────────────────────────────────────────────────────────────
//
// The selected menu title and item are a block of colour in a terminal. In
// the GUI they are a rounded fill, smaller in radius than the panel they sit
// in, with the text drawn over it.

const float HIGHLIGHT_RADIUS = 4.0f;

// highlight_style is a highlighted style with its background taken off in the
// GUI, where highlight() draws it instead.
fn glaze::Style highlight_style(glaze::Style s) {
	if (pixel_ui()) s.bg = {};
	return s;
}

// highlight puts the rounded fill under a node built from highlight_style.
fn xray::Node* highlight(xray::Node* n, glaze::Color bg) {
	if (!pixel_ui()) return n;
	return n.decorate(xray::solid(bg).round(HIGHLIGHT_RADIUS));
}

// clear_bg lets a node's text show what is under it in the GUI. The content
// of a decorated node is painted with a clear background, and an invisible
// decoration is enough for that; the GUI skips drawing it.
fn xray::Node* clear_bg(xray::Node* n) {
	if (!pixel_ui()) return n;
	return n.decorate(xray::solid(xray::color_transparent()));
}
