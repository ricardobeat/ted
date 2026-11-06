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

fn xray::Node* CommandBar.node(&self, Theme* th) {
	if (!self.open) return null;
	glaze::Style plain = { .fg = th.text, .bg = th.panel };
	self.input.focused_style = plain;
	self.input.placeholder_style = { .fg = th.border };
	xray::Node* panel = floating(xray::vstack().style(panel_style({
		.fg = th.text, .bg = th.panel, .border = glaze::ROUNDED,
		.border_color = th.accent, .pad_left = 2, .pad_right = 2,
		.pad_top = 1, .pad_bottom = 1, .max_width = 72,
	})).width(milktea::cells(72)).center(), th, th.panel, th.border);
	panel.id_with(self).on_click_outside(&command_outside);
	panel.add(milktea::text(self.title, { .fg = th.accent, .bg = th.panel, .bold = true }).fit_height());
	panel.add(self.input.node().height(milktea::cells(1)));
	for (sz row = 0; row < COMMAND_ROWS && self.scroll + row < self.results.len; row++) {
		sz i = self.scroll + row;
		self.slots[row] = { self, i };
		CommandResult result = self.results[i];
		glaze::Style style = plain;
		if (i == self.selected) style = { .fg = th.ink, .bg = th.accent };
		panel.add(milktea::text(result.detail.len ? string::tformat("%s  %s", result.label, result.detail) : result.label, style)
			.height(milktea::cells(1)).id_with(&self.slots[row]).on_click(&command_clicked));
	}
	if (!self.results.len) panel.add(milktea::text("No results", plain).fit_height());
	panel.add(milktea::text(self.hint.len ? self.hint : "↑↓ select · Enter open · Esc cancel", plain).fit_height());
	return milktea::root().block_pointer().add(panel);
}
