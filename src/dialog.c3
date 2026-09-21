module ted;

import milktea;
import glaze;
import xray;

const int DIALOG_BUTTONS = 2;

struct Dialog {
	String title;
	String body;
	Button[DIALOG_BUTTONS] buttons;
	int focused;
	bool open;
	int min_cols;
	Pressed pending;
	ButtonSlot[DIALOG_BUTTONS] button_slots;
}

enum Pressed {
	NOTHING,
	DISMISSED,
	CONFIRMED,
}

struct ButtonSlot {
	Dialog* dialog;
	int index;
}

fn Dialog new_dialog(String title, String body, String ok, String cancel) {
	return {
		.title = title,
		.body = body,
		.buttons = { new_button(ok), new_button(cancel) },
		.min_cols = 36,
	};
}

fn void Dialog.show(&self) {
	self.open = true;
	self.focused = 0;
}

fn Pressed Dialog.handle_key(&self, milktea::KeyMsg k) {
	if (!self.open) return Pressed.NOTHING;

	switch (k.code) {
		case milktea::KeyCode.ESC:
			self.open = false;
			return Pressed.DISMISSED;
		case milktea::KeyCode.LEFT:
		case milktea::KeyCode.RIGHT:
		case milktea::KeyCode.TAB:
			self.focused = (self.focused + 1) % DIALOG_BUTTONS;
		case milktea::KeyCode.ENTER:
			self.open = false;
			return Pressed.CONFIRMED;
		default:
	}
	return Pressed.NOTHING;
}

fn Pressed Dialog.take_pending(&self) {
	Pressed p = self.pending;
	self.pending = Pressed.NOTHING;
	return p;
}

fn void button_clicked(void* id, String id_str, int col, int row) @local {
	ButtonSlot* slot = (ButtonSlot*)id;
	slot.dialog.focused = slot.index;
	slot.dialog.open = false;
	slot.dialog.pending = slot.index == 0 ? Pressed.CONFIRMED : Pressed.DISMISSED;
}

fn void backdrop_dismissed(void* id, String id_str, int col, int row) @local {
	Dialog* d = (Dialog*)id;
	d.open = false;
	d.pending = Pressed.DISMISSED;
}

// node returns the dialog, centered within the editor area (not the full
// screen, so it doesn't overlap the sidebar). Glaze sizes the panel from
// its children — no manual width/height math.
fn xray::Node* Dialog.node(&self, Theme* th, xray::Rect area) {
	if (!self.open) return null;

	glaze::Style panel = {
		.bg = th.panel, .fg = th.text,
		.border = glaze::ROUNDED, .border_color = th.accent,
		.pad_top = 1, .pad_right = 2, .pad_bottom = 1, .pad_left = 2,
	};
	glaze::Style title_s = {
		.fg = th.accent, .bg = th.panel, .bold = true,
		.align_h = glaze::Position.LEFT,
	};
	glaze::Style body_s = {
		.fg = th.text, .bg = th.panel,
		.align_h = glaze::Position.LEFT,
	};

	int widest = (int)glaze::string_width(self.title);
	if (widest < self.min_cols) widest = self.min_cols;

	xray::Node* panel_node = milktea::text(panel, "")
		.width(milktea::cells(widest))
		.with_padding(1, 2, 1, 2)
		.with_gap(1)
		.center()
		.shadow(milktea::shadow(2, 1).with_color(milktea::to_cell_color(th.shadow)));
	panel_node.id_with(self).on_click_outside(&backdrop_dismissed);

	String header = glaze::join_vertical_arr(glaze::Position.LEFT, {
		title_s.render(self.title), "", body_s.render(self.body),
	});
	panel_node.add(milktea::text(body_s, header));

	xray::Node* buttons_row = xray::hstack()
		.with_gap(2)
		.with_justify(xray::JustifyContent.JUSTIFY_CENTER)
		.height(milktea::cells(2));
	for (int i = 0; i < DIALOG_BUTTONS; i++) {
		self.button_slots[i] = { .dialog = self, .index = i };
		String label = self.buttons[i].themed(th).with_focus(i == self.focused).view();
		xray::Node* btn = milktea::text({ .bg = th.panel }, label)
			.width(milktea::cells(self.buttons[i].measure_width(2)));
		btn.id_with(&self.button_slots[i]).on_click(&button_clicked);
		buttons_row.add(btn);
	}
	panel_node.add(buttons_row);

	return panel_node;
}
