module ted;

import glaze;

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
