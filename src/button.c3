module ted;

import milktea;
import glaze;
import xray;
import dye;

const glaze::Border BUTTON_SHADOW = {
	.right = "▌",
	.bottom = "▀",
	.bottom_right = "▘",
};

const sz BUTTON_PAD = 2;

struct Button (xray::Content) {
	String label;
	bool focused;
	// The pointer is over the button.
	bool hovered;
	glaze::Color face;
	glaze::Color focused_face;
	glaze::Color text;
	glaze::Color shadow;
	glaze::Color surface;
}

fn Button new_button(String label) {
	return { .label = label };
}

fn Button Button.themed(self, Theme* th) {
	Button b = self;
	b.face = th.dim;
	b.focused_face = th.accent;
	b.text = th.ink;
	b.shadow = th.shadow;
	b.surface = th.panel;
	return b;
}

fn Button Button.with_focus(self, bool on) {
	Button b = self;
	b.focused = on;
	return b;
}

fn Button Button.with_hover(self, bool on) {
	Button b = self;
	b.hovered = on;
	return b;
}

// face_color is the button's fill: the focused or plain face, lifted a little
// toward white while the pointer is over it.
fn glaze::Color Button.face_color(&self) {
	glaze::Color c = self.focused ? self.focused_face : self.face;
	if (self.hovered) c = dye::color_rgba(255, 255, 255, 36).blend_over(c);
	return c;
}

fn glaze::Style Button.style(&self) {
	// The GUI draws the face and its shadow as a decoration (see node), so
	// the label is all the text there is.
	if (pixel_ui()) return { .fg = self.text, .pad_left = BUTTON_PAD, .pad_right = BUTTON_PAD };
	return {
		.fg = self.text,
		.bg = self.face_color(),
		.border = BUTTON_SHADOW,
		.border_color = self.shadow,
		.border_bg = self.surface,
		.pad_left = BUTTON_PAD,
		.pad_right = BUTTON_PAD,
	};
}

fn String Button.view(&self) => self.style().render(self.label);

// In a terminal the shadow takes a row below and a column to the right.
fn sz Button.measure(&self, sz width) @dynamic => pixel_ui() ? 1 : 2;

fn sz Button.measure_width(&self, sz height) @dynamic {
	return glaze::string_width(self.label) + BUTTON_PAD * 2 + (pixel_ui() ? 0 : 1);
}

fn String Button.render(&self, xray::Rect r) @dynamic => self.view();

// BUTTON_PAD_Y is the extra height a GUI button gets above and below its
// label, in points, so it is not just a coloured row of text.
const sz BUTTON_PAD_Y = 3;

fn xray::Node* Button.node(&self) => self.decorate(xray::content_node(self));

// decorate gives a node showing this button's label its face in the GUI: a
// rounded fill with a small soft shadow and a highlight along the top edge.
// A terminal button carries its face and shadow in its own cells.
fn xray::Node* Button.decorate(&self, xray::Node* n) {
	if (!pixel_ui()) return n;
	return n.decorate(xray::solid(self.face_color())
		.round(5.0f)
		.with_shadow(0.0f, 1.0f, 3.0f, dye::color_rgba(0, 0, 0, 110))
		.with_inner_shadow(0.0f, 1.0f, 0.0f, dye::color_rgba(255, 255, 255, 40))
		.padding(BUTTON_PAD_Y, 0, BUTTON_PAD_Y, 0));
}
