module ted;

import milktea;

struct CommandProbe {
	sz queries;
	String accepted;
	bool dismissed;
}

fn void probe_query(CommandBar* bar, void* context, String query) @local {
	((CommandProbe*)context).queries++;
}
fn void probe_accept(void* context, String id) @local {
	((CommandProbe*)context).accepted = id;
}
fn void probe_dismiss(void* context) @local {
	((CommandProbe*)context).dismissed = true;
}

fn void test_command_bar_callbacks_and_selection() @test {
	CommandProbe probe;
	CommandBar bar = new_command_bar("Commands", "Type…");
	bar.context = &probe;
	bar.on_query = &probe_query;
	bar.on_accept = &probe_accept;
	bar.on_dismiss = &probe_dismiss;
	bar.show();
	assert(bar.open && probe.queries == 1);
	bar.handle_key({ .code = milktea::KeyCode.RUNE, .rune = 'a' });
	assert(bar.input.text() == "a" && probe.queries == 2);
	bar.handle_key({ .code = milktea::KeyCode.LEFT });
	assert(probe.queries == 2);
	bar.set_results({ { .id = "one", .label = "One" }, { .id = "two", .label = "Two" } });
	bar.handle_key({ .code = milktea::KeyCode.DOWN });
	bar.handle_key({ .code = milktea::KeyCode.ENTER });
	assert(!bar.open && probe.accepted == "two");
	bar.show();
	bar.handle_key({ .code = milktea::KeyCode.ENTER });
	assert(bar.open);
	bar.handle_key({ .code = milktea::KeyCode.ESC });
	assert(!bar.open && probe.dismissed);
}

fn void test_command_bar_utf8_and_paste() @test {
	CommandBar bar = new_command_bar("Test", "");
	bar.show();
	bar.handle_key({ .code = milktea::KeyCode.RUNE, .rune = 0xe9 });
	assert(bar.input.text() == "é");
	bar.handle_key({ .code = milktea::KeyCode.BACKSPACE });
	assert(bar.input.text() == "");
	bar.paste("a\nb\tc");
	assert(bar.input.text() == "abc");
	bar.handle_key({ .code = milktea::KeyCode.RUNE, .ctrl = true, .rune = 'x' });
	assert(bar.input.text() == "abc");
}

fn void test_file_search_fuzzy_ranking() @test {
	assert(file_match_score("src/ted.c3", "TC") != -2147483647);
	assert(file_match_score("src/ted.c3", "xyz") == -2147483647);
	assert(file_match_score("src/ted.c3", "ted") > file_match_score("ted/other.c3", "ted"));
	assert(file_match_score("src/ted.c3", "") == 0);
}
