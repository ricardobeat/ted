module ted;

import milktea;
import boba;
import glaze;
import xray;
import std::core::string;

const sz COMMAND_ROWS = 10;

struct CommandResult {
	String id;
	String label;
	String detail;
}

alias CommandQuery = fn void(CommandBar*, void*, String);
alias CommandAccept = fn void(void*, String);
alias CommandDismiss = fn void(void*);

// Results are borrowed until the next query callback or dismissal.
struct CommandBar {
	String title;
	boba::TextInput input;
	CommandResult[] results;
	CommandQuery on_query;
	CommandAccept on_accept;
	CommandDismiss on_dismiss;
	void* context;
	bool open;
	sz selected;
	sz scroll;
	String hint;
	CommandRow[COMMAND_ROWS] slots;
}

struct CommandRow {
	CommandBar* bar;
	sz index;
}

fn CommandBar new_command_bar(String title, String placeholder) {
	return { .title = title, .input = boba::new_text_input().with_placeholder(placeholder) };
}

fn void CommandBar.set_results(&self, CommandResult[] results) {
	self.results = results;
	self.selected = 0;
	self.scroll = 0;
}

fn void CommandBar.show(&self) {
	self.open = true;
	self.input.clear();
	self.input.focused = true;
	self.set_results({});
	if (self.on_query) self.on_query(self, self.context, self.input.text());
}

fn void CommandBar.dismiss(&self) {
	self.open = false;
	if (self.on_dismiss) self.on_dismiss(self.context);
}

fn void CommandBar.accept(&self) {
	if (self.selected >= self.results.len) return;
	String id = self.results[self.selected].id;
	self.open = false;
	if (self.on_accept) self.on_accept(self.context, id);
}

fn void CommandBar.paste(&self, String text) {
	foreach (c : text) if (c >= 32 && c != 127) self.input.insert(c);
	if (self.on_query) self.on_query(self, self.context, self.input.text());
}

fn void CommandBar.handle_key(&self, milktea::KeyMsg k) {
	switch (k.code) {
		case milktea::KeyCode.ESC: self.dismiss();
		case milktea::KeyCode.ENTER: self.accept();
		case milktea::KeyCode.UP: if (self.selected > 0) self.selected--;
		case milktea::KeyCode.DOWN: if (self.selected + 1 < self.results.len) self.selected++;
		default:
			if (k.ctrl || k.super || k.alt) return;
			char[512] before = self.input.buf;
			sz len = self.input.len;
			self.input.handle_key(k);
			if (len != self.input.len || (String)before[:len] != self.input.text()) {
				if (self.on_query) self.on_query(self, self.context, self.input.text());
			}
	}
	if (self.selected < self.scroll) self.scroll = self.selected;
	if (self.selected >= self.scroll + COMMAND_ROWS) self.scroll = self.selected - COMMAND_ROWS + 1;
}

fn void command_clicked(void* id, String name, sz col, sz row) @local {
	CommandRow* slot = (CommandRow*)id;
	slot.bar.selected = slot.index;
	slot.bar.accept();
}

fn void command_outside(void* id, String name, sz col, sz row) @local {
	((CommandBar*)id).dismiss();
}

// COMMAND_WIDTH is the panel's width in cells, border included.
const sz COMMAND_WIDTH = 72;
// COMMAND_TOP is how far below the top of the window the panel sits, in
// rows: under the menu bar, where the eye already is, like a search box.
const sz COMMAND_TOP = 3;

// split_path returns the file name and the directory it is in, so a row can
// lead with the part people search by.
fn String[2] split_path(String path) @local {
	for (sz i = path.len; i > 0; i--) {
		if (path[i - 1] == '/') return { path[i..], path[:i - 1] };
	}
	return { path, "" };
}

// The panel is a fixed size: the search field, COMMAND_ROWS result rows
// (blank when there are fewer) and a footer, so it does not jump about as
// results arrive. It hangs from near the top of the window rather than
// being centred.
fn xray::Node* CommandBar.node(&self, Theme* th) {
	if (!self.open) return null;
	glaze::Style plain = { .fg = th.text, .bg = th.bar };
	glaze::Style dim = { .fg = th.dim, .bg = th.bar };
	self.input.focused_style = { .fg = th.text, .bg = th.panel };
	self.input.placeholder_style = { .fg = th.dim, .bg = th.panel };
	xray::Constraint full = xray::fill(1);

	// place() sets the panel's own justify and align, which also lay out its
	// rows; so each row is given the full width rather than being centred.
	xray::Node* panel = floating(xray::vstack().style(panel_style({
		.fg = th.text, .bg = th.bar, .border = glaze::ROUNDED,
		.border_color = th.border, .pad_left = 1, .pad_right = 1,
		.max_width = COMMAND_WIDTH,
	})).width(milktea::cells(COMMAND_WIDTH))
		.place(xray::JustifyContent.JUSTIFY_CENTER, xray::AlignItems.ALIGN_START)
		.offset(0, COMMAND_TOP), th, th.bar, th.border);
	panel.id("command-bar").role(DIALOG).ref(self).on_click_outside(&command_outside);

	// The search field: a prompt and the input, on the editor's colour so it
	// reads as a box to type in.
	glaze::Style field_s = { .fg = th.accent, .bg = th.panel, .bold = true };
	xray::Node* field = xray::hstack().width(full).height(milktea::cells(1));
	field.add(milktea::text(" › ", field_s).width(milktea::cells(3)));
	field.add(self.input.node().width(full).height(milktea::cells(1)));
	if (pixel_ui()) field = field.decorate(xray::solid(th.panel).round(HIGHLIGHT_RADIUS));
	panel.add(field);
	panel.add(milktea::text("", plain).width(full).height(milktea::cells(1)));

	for (sz row = 0; row < COMMAND_ROWS; row++) {
		sz i = self.scroll + row;
		if (i >= self.results.len) {
			String empty = row == 0 && !self.hint.len ? "  No matching files" : "";
			panel.add(clear_bg(milktea::text(empty, dim).width(full).height(milktea::cells(1))));
			continue;
		}
		self.slots[row] = { self, i };
		CommandResult result = self.results[i];
		bool lit = i == self.selected;
		glaze::Style name_s = lit ? (glaze::Style){ .fg = th.ink, .bg = th.accent, .bold = true } : plain;
		glaze::Style dir_s = lit ? (glaze::Style){ .fg = th.ink, .bg = th.accent } : dim;
		String[2] parts = split_path(result.label);
		String name = string::tformat("  %s  ", parts[0]);
		xray::Node* line = xray::hstack().width(full).height(milktea::cells(1));
		line.add(milktea::text(name, highlight_style(name_s)).width(milktea::cells(name.len)));
		line.add(milktea::text(parts[1], highlight_style(dir_s)).width(full));
		line = pixel_ui() ? (lit ? highlight(line, th.accent) : clear_bg(line)) : line;
		line.id("result").key(result.label).role(LIST_ITEM);
		panel.add(line.ref(&self.slots[row]).on_click(&command_clicked));
	}

	panel.add(milktea::text("", plain).width(full).height(milktea::cells(1)));
	xray::Node* footer = xray::hstack().width(full).height(milktea::cells(1));
	String left = self.hint.len || pixel_ui() ? self.hint : "↑↓ select · Enter open · Esc close";
	footer.add(milktea::text(string::tformat("  %s", left), dim).width(full));
	if (self.results.len) {
		String count = string::tformat("%d %s  ", self.results.len, self.results.len == 1 ? "match" : "matches");
		footer.add(milktea::text(count, dim).width(milktea::cells(count.len)));
	}
	panel.add(clear_bg(footer));
	return milktea::root().block_pointer().add(panel);
}
