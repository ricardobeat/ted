module ted;

import milktea;
import glaze;
import xray;

struct MenuItem {
	String label;
	String key;
}

const int ITEM_PAD = 1;
const int ITEM_GAP = 2;

const int MENU_COLS  = 4;
const int MENU_ITEMS = 4;

struct TitleSlot {
	Menu* menu;
	int index;
}

struct ItemSlot {
	Menu* menu;
	int index;
}

struct Menu {
	String[MENU_COLS] titles;
	// Cells to leave clear at the left of the bar, where a GUI window draws
	// its own buttons. Both the bar and the dropdowns are placed after them.
	int x_inset;
	int[MENU_COLS] title_x;
	MenuItem[MENU_COLS][MENU_ITEMS] items;
	int selected;
	int item;
	bool open;
	int item_width;
	TitleSlot[MENU_COLS] title_slots;
	ItemSlot[MENU_ITEMS] item_slots;
	Chosen pending;
	// Set when a press landed on a title, and read by the open dropdown's
	// outside-click handler in the same dispatch. A press on another title is
	// outside the open panel, so without this the dropdown would dismiss
	// itself right after the title opened the next one, and a click would
	// never move between menus. bar() clears it each frame, so it never
	// outlives the dispatch that set it.
	bool title_press;
}

enum Chosen {
	NOTHING,
	DISMISSED,
	PICKED,
}

// item_width is the narrowest a dropdown gets, border included; one with
// longer items grows to fit them.
fn Menu new_menu(String[MENU_COLS] titles, int item_width = 24) {
	Menu m = { .titles = titles, .item_width = item_width };
	int x = 0;
	for (int i = 0; i < MENU_COLS; i++) {
		m.title_x[i] = x;
		x += glaze::string_width(titles[i]);
	}
	return m;
}

fn void Menu.set_items(&self, int col, MenuItem[MENU_ITEMS] items) {
	if (col >= 0 && col < MENU_COLS) self.items[col] = items;
}

fn MenuItem Menu.current_item(&self) => self.items[self.selected][self.item];

fn Chosen Menu.handle_key(&self, milktea::KeyMsg k) {
	if (!self.open) return self.handle_bar_key(k);

	switch (k.code) {
		case milktea::KeyCode.ESC:
			self.open = false;
			return Chosen.DISMISSED;
		case milktea::KeyCode.UP:
			if (self.item > 0) self.item--;
		case milktea::KeyCode.DOWN:
			if (self.item < MENU_ITEMS - 1) self.item++;
		case milktea::KeyCode.LEFT:
			if (self.selected > 0) self.selected--;
			self.item = 0;
		case milktea::KeyCode.RIGHT:
			if (self.selected < MENU_COLS - 1) self.selected++;
			self.item = 0;
		case milktea::KeyCode.ENTER:
			self.open = false;
			return Chosen.PICKED;
		default:
	}
	return Chosen.NOTHING;
}

fn Chosen Menu.handle_bar_key(&self, milktea::KeyMsg k) {
	switch (k.code) {
		case milktea::KeyCode.LEFT:
			if (self.selected > 0) self.selected--;
		case milktea::KeyCode.RIGHT:
			if (self.selected < MENU_COLS - 1) self.selected++;
		case milktea::KeyCode.DOWN:
		case milktea::KeyCode.ENTER:
			self.open = true;
			self.item = 0;
		default:
	}
	return Chosen.NOTHING;
}

fn void Menu.dismiss(&self) {
	self.open = false;
}

fn Chosen Menu.take_pending(&self) {
	Chosen p = self.pending;
	self.pending = Chosen.NOTHING;
	return p;
}

fn void title_clicked(void* id, String id_str, int col, int row) @local {
	TitleSlot* slot = (TitleSlot*)id;
	Menu* m = slot.menu;
	m.title_press = true;
	// Clicking the title of the open menu closes it, the way a platform menu
	// bar does; clicking any other title moves to it and stays open.
	if (m.open && m.selected == slot.index) {
		m.open = false;
		m.pending = Chosen.DISMISSED;
		return;
	}
	m.selected = slot.index;
	m.open = true;
	m.item = 0;
}

fn void item_clicked(void* id, String id_str, int col, int row) @local {
	ItemSlot* slot = (ItemSlot*)id;
	slot.menu.item = slot.index;
	slot.menu.open = false;
	slot.menu.pending = Chosen.PICKED;
}

fn void dropdown_dismissed(void* id, String id_str, int col, int row) @local {
	Menu* m = (Menu*)id;
	// A title already handled this press — it either moved the menu or closed
	// it, and either way the panel must not undo that.
	if (m.title_press) return;
	m.dismiss();
	m.pending = Chosen.DISMISSED;
}

// bar renders the menu titles in one row. Only the title under the keyboard
// gets the active style: bar() is called with focused=true while focus is on
// the menu bar, so on app open (focus is the editor) the first title looks
// like the rest rather than pre-highlighted. An open dropdown keeps its
// title highlighted regardless of focus.
// lead and trail fill the cells this bar keeps clear at its ends for window
// buttons: whichever one the platform's buttons would sit at gets the node
// the app draws in their place, and the other is null. Everything between
// them is bare bar, and that is what drags the window.
fn xray::Node* Menu.bar(&self, Theme* th, bool focused, xray::Node* lead = null, xray::Node* trail = null) {
	glaze::Style bar = { .bg = th.bar, .fg = th.bar_text };
	glaze::Style active = { .bg = th.accent, .fg = th.ink, .bold = true };
	glaze::Style filler = { .bg = th.bar };

	self.title_press = false;

	xray::Node* row = milktea::hstack().height(milktea::cells(1));
	if (lead) {
		row.add(lead);
	} else if (self.x_inset > 0) {
		row.add(milktea::text(filler, "").width(milktea::cells(self.x_inset)));
	}
	for (int i = 0; i < MENU_COLS; i++) {
		self.title_slots[i] = { .menu = self, .index = i };
		bool highlighted = (focused || self.open) && i == self.selected;
		xray::Node* title_node = milktea::text(highlighted ? active : bar, self.titles[i])
			.fit_width();
		title_node.id_with(&self.title_slots[i]).on_click(&title_clicked);
		row.add(title_node);
	}
	row.add(milktea::text(filler, "").fill(1).window_drag(true));
	if (trail) row.add(trail);
	return row;
}

// item_row lays a label against its shortcut key: a padded box that pushes
// the key to the right edge, however wide the panel turns out, and keeps at
// least ITEM_GAP between them when the panel is sized to its widest row.
fn xray::Node* Menu.item_row(&self, MenuItem mi, glaze::Style base) {
	return milktea::hbox(base.pad_x(ITEM_PAD))
		.with_justify(xray::JustifyContent.JUSTIFY_SPACE_BETWEEN)
		.with_gap(ITEM_GAP)
		.fit_height()
		.add(milktea::text(base, mi.label).fit_width())
		.add(milktea::text(base, mi.key).fit_width());
}

// dropdown is a bordered box of item rows, as wide as its widest row but no
// narrower than item_width, placed under the open title.
fn xray::Node* Menu.dropdown(&self, int below, Theme* th) {
	if (!self.open) return null;

	glaze::Style panel = {
		.bg = th.bar, .fg = th.bar_text,
		.border = glaze::NORMAL, .border_color = th.text,
		.min_width = self.item_width,
	};
	glaze::Style selected = { .bg = th.ink, .fg = th.accent, .bold = true };
	glaze::Style item = { .bg = th.bar, .fg = th.bar_text };

	xray::Node* panel_node = milktea::vbox(panel)
		.at(self.title_x[self.selected] + self.x_inset, below)
		.shadow(milktea::shadow(2, 1).with_color(milktea::to_cell_color(th.shadow)));
	panel_node.id_with(self).on_click_outside(&dropdown_dismissed);

	for (int i = 0; i < MENU_ITEMS; i++) {
		self.item_slots[i] = { .menu = self, .index = i };
		glaze::Style s = i == self.item ? selected : item;
		xray::Node* row_node = self.item_row(self.items[self.selected][i], s);
		row_node.id_with(&self.item_slots[i]).on_click(&item_clicked);
		panel_node.add(row_node);
	}
	return panel_node;
}
