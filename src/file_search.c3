module ted;

import milktea;
import std::os::process;
import std::net::os;
import libc;
import std::collections::list;
import std::core::string;

alias SearchPaths = List{String};

struct FileSearch {
	Process worker;
	bool scanning;
	SearchPaths paths;
	char[4096] partial;
	sz partial_len;
	bool overflow;
	CommandResult[100] matches;
	int[100] scores;
	sz count;
}

fn char search_lower(char c) @local => c >= 'A' && c <= 'Z' ? c + ('a' - 'A') : c;

fn int file_match_score(String path, String query) {
	if (!query.len) return 0;
	sz q = 0;
	int score = 0;
	sz basename = 0;
	foreach (i, c : path) if (c == '/') basename = i + 1;
	foreach (i, c : path) {
		if (search_lower(c) != search_lower(query[q])) continue;
		score += 10;
		if (i >= basename) score += 10;
		if (i == 0 || path[i - 1] == '/' || path[i - 1] == '_' || path[i - 1] == '-') score += 5;
		q++;
		if (q == query.len) return score - (int)(path.len - query.len);
	}
	return -2147483647;
}

fn void file_query(CommandBar* bar, void* context, String query) {
	Editor* ed = (Editor*)context;
	FileSearch* search = &ed.file_search;
	search.count = 0;
	foreach (path : search.paths) {
		int score = file_match_score(path, query);
		if (score == -2147483647) continue;
		sz at = 0;
		while (at < search.count && (search.scores[at] > score ||
			(search.scores[at] == score && search.matches[at].id.compare_to(path) < 0))) at++;
		if (at >= search.matches.len) continue;
		if (search.count < search.matches.len) search.count++;
		for (sz i = search.count - 1; i > at; i--) {
			search.matches[i] = search.matches[i - 1];
			search.scores[i] = search.scores[i - 1];
		}
		search.matches[at] = { .id = path, .label = path };
		search.scores[at] = score;
	}
	bar.set_results(search.matches[:search.count]);
}

fn void file_accept(void* context, String id) {
	Editor* ed = (Editor*)context;
	ed.file_search.stop();
	ed.load_file(id);
	ed.focus_editor();
}

fn void file_dismiss(void* context) {
	((Editor*)context).file_search.stop();
}

fn void FileSearch.stop(&self) {
	if (!self.scanning) return;
	(void)self.worker.terminate();
	(void)self.worker.join();
	self.worker.destroy();
	self.scanning = false;
}

fn void Editor.show_file_search(&self) {
	FileSearch* search = &self.file_search;
	search.stop();
	foreach (path : search.paths) mem::free(path.ptr);
	search.paths.free();
	search.paths.init(mem);
	search.partial_len = 0;
	search.overflow = false;
	self.command_bar = new_command_bar("Open file", "Search files…");
	self.command_bar.context = self;
	self.command_bar.on_query = &file_query;
	self.command_bar.on_accept = &file_accept;
	self.command_bar.on_dismiss = &file_dismiss;
	self.command_bar.show();
	// ripgrep applies ignore files and does not follow directory symlinks.
	if (try worker = process::spawn({ "rg", "--files", "--hidden", "-0", "-g", "!.git", "." },
		SpawnOptions.INHERIT_ENV, err: process::INHERIT)) {
		search.worker = worker;
		if (catch err = ((NativeSocket)libc::fileno(worker.stdout_file)).set_non_blocking(true)) {
			search.scanning = true;
			search.stop();
			self.command_bar.hint = "Could not start file search";
			return;
		}
		search.scanning = true;
		self.command_bar.hint = "Scanning…";
		milktea::tick(16, owner: search);
	} else {
		self.command_bar.hint = "File search requires rg (ripgrep) on PATH";
	}
}

fn void Editor.poll_file_search(&self) {
	FileSearch* search = &self.file_search;
	if (!search.scanning) return;
	char[65536] buffer;
	sz n = search.worker.read_stdout(&buffer[0], buffer.len) ?? 0;
	foreach (c : buffer[:n]) {
		if (c == 0) {
			if (!search.overflow && search.partial_len) {
				String path = (String)search.partial[:search.partial_len];
				if (path.starts_with("./")) path = path[2..];
				search.paths.push(path.copy(mem));
			}
			search.partial_len = 0;
			search.overflow = false;
		} else if (search.partial_len < search.partial.len) {
			search.partial[search.partial_len++] = c;
		} else { search.overflow = true; }
	}
	if (n && self.command_bar.open) {
		String selected = search.count && self.command_bar.selected < search.count ? search.matches[self.command_bar.selected].id : "";
		file_query(&self.command_bar, self, self.command_bar.input.text());
		foreach (i, result : self.command_bar.results) if (result.id == selected) self.command_bar.selected = i;
		if (self.command_bar.selected >= COMMAND_ROWS) self.command_bar.scroll = self.command_bar.selected - COMMAND_ROWS + 1;
	}
	if (n == 0 && !(search.worker.is_running() ?? false)) {
		search.worker.destroy();
		search.scanning = false;
		self.command_bar.hint = search.worker.return_status > 1 ? "File search failed" : "";
	} else {
		milktea::tick(16, owner: search);
	}
}
