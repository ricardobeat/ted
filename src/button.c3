module ted;

import milktea;
import glaze;
import xray;

const glaze::Border BUTTON_SHADOW = {
	.right = "▌",
	.bottom = "▀",
	.bottom_right = "▘",
};

const int BUTTON_PAD = 2;

struct Button (xray::Content) {
	String label;
	bool focused;
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

fn glaze::Style Button.style(&self) {
	return {
		.fg = self.text,
		.bg = self.focused ? self.focused_face : self.face,
		.border = BUTTON_SHADOW,
		.border_color = self.shadow,
		.border_bg = self.surface,
		.pad_left = BUTTON_PAD,
		.pad_right = BUTTON_PAD,
	};
}

fn String Button.view(&self) => self.style().render(self.label);

fn int Button.measure(&self, int width) @dynamic => 2;

fn int Button.measure_width(&self, int height) @dynamic {
	return glaze::string_width(self.label) + BUTTON_PAD * 2 + 1;
}

fn String Button.render(&self, xray::Rect r) @dynamic => self.view();

fn xray::Node* Button.node(&self) => xray::content_node(self);
