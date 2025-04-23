const std = @import("std");
const search = @import("../search/search.zig");
const builtin = @import("builtin");
const c = @cImport({
    @cInclude("termios.h");
    @cInclude("sys/ioctl.h");
});

pub const CLEAR_SCREEN = "\x1B[2J\x1B[H";
pub const CLEAR_LINE = "\x1B[2K\r";
pub const MOVE_UP = "\x1B[1A";
pub const RESET_STYLE = "\x1B[0m";
pub const BOLD = "\x1B[1m";
pub const UNDERLINE = "\x1B[4m";
pub const HIGHLIGHT = "\x1B[7m";
pub const BLUE = "\x1B[34m";
pub const GREEN = "\x1B[32m";
pub const GRAY = "\x1B[90m";
pub const YELLOW = "\x1B[33m";
pub const CYAN = "\x1B[36m";
pub const RED = "\x1B[31m";

pub const PreviewMode = enum { None, Right, Bottom };

pub const FuzzyFinder = struct {
    results: std.ArrayList(search.SearchResult),
    allocator: std.mem.Allocator,
    query: []const u8,
    cursor: usize = 0,
    offset: usize = 0,
    max_display: usize = 0,
    search_type: enum { Content, Files } = .Content,
    preview_mode: PreviewMode = .Right,
    selected_items: std.AutoHashMap(usize, void),
    history: std.ArrayList([]const u8),
    history_index: usize = 0,

    pub fn init(allocator: std.mem.Allocator) FuzzyFinder {
        return .{
            .results = std.ArrayList(search.SearchResult).init(allocator),
            .allocator = allocator,
            .query = "",
            .selected_items = std.AutoHashMap(usize, void).init(allocator),
            .history = std.ArrayList([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *FuzzyFinder) void {
        for (self.results.items) |*item| {
            item.deinit(self.allocator);
        }
        self.results.deinit();
        self.allocator.free(self.query);
        self.selected_items.deinit();

        for (self.history.items) |item| {
            self.allocator.free(item);
        }
        self.history.deinit();
    }

    pub fn setQuery(self: *FuzzyFinder, query: []const u8) !void {
        if (self.query.len > 0) {
            self.allocator.free(self.query);
        }
        self.query = try self.allocator.dupe(u8, query);
        self.cursor = 0;
        self.offset = 0;

        if (query.len > 0 and (self.history.items.len == 0 or !std.mem.eql(u8, self.history.items[self.history.items.len - 1], query))) {
            const history_entry = try self.allocator.dupe(u8, query);
            try self.history.append(history_entry);
            self.history_index = self.history.items.len;
        }
    }

    pub fn updateSearch(self: *FuzzyFinder, options: search.SearchOptions) !void {
        for (self.results.items) |*item| {
            item.deinit(self.allocator);
        }
        self.results.clearRetainingCapacity();
        self.selected_items.clearRetainingCapacity();

        if (self.search_type == .Content) {
            self.results = try search.searchWithRipgrep(self.allocator, self.query, options);
        } else {
            self.results = try search.findFiles(self.allocator, self.query, options);
        }

        self.cursor = 0;
        self.offset = 0;
    }

    fn getTerminalSize(_: *FuzzyFinder) !struct { width: u16, height: u16 } {
        var winsize = std.mem.zeroes(c.winsize);
        const fd = std.io.getStdOut().handle;

        if (c.ioctl(fd, c.TIOCGWINSZ, &winsize) == -1) {
            return error.IoctlError;
        }

        return .{ .width = winsize.ws_col, .height = winsize.ws_row };
    }

    fn getPreviewContent(self: *FuzzyFinder, path: []const u8, _: usize) ![]const u8 {
        if (path.len == 0) return "";

        const max_preview_size = 1024 * 50;

        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();

        const file_size = try file.getEndPos();
        const read_size = @min(file_size, max_preview_size);

        var buffer = try self.allocator.alloc(u8, read_size);
        errdefer self.allocator.free(buffer);

        const bytes_read = try file.readAll(buffer);
        if (bytes_read < read_size) {
            buffer = self.allocator.resize(buffer, bytes_read) orelse buffer[0..bytes_read];
        }

        return buffer;
    }

    fn renderPreview(self: *FuzzyFinder, writer: anytype, term_size: struct { width: u16, height: u16 }) !void {
        if (self.preview_mode == .None) return;

        if (self.results.items.len == 0 or self.cursor >= self.results.items.len) {
            try writer.writeAll(GRAY ++ "No preview available" ++ RESET_STYLE);
            return;
        }

        const result = self.results.items[self.cursor];

        var preview_width: usize = undefined;
        var preview_height: usize = undefined;
        var preview_x: usize = 0;
        var preview_y: usize = 0;

        switch (self.preview_mode) {
            .Right => {
                preview_width = term_size.width / 2;
                preview_height = term_size.height - 5;
                preview_x = term_size.width - preview_width;
            },
            .Bottom => {
                preview_width = term_size.width;
                preview_height = term_size.height / 3;
                preview_y = term_size.height - preview_height - 2;
            },
            .None => unreachable,
        }

        try writer.print("\x1B[{d};{d}H", .{ preview_y + 1, preview_x + 1 });
        try writer.print("{s}=== Preview: {s} ==={s}", .{ BOLD, result.path, RESET_STYLE });

        const preview_content = self.getPreviewContent(result.path, result.line_number) catch |err| blk: {
            const err_msg = std.fmt.allocPrint(self.allocator, "Error reading file: {s}", .{@errorName(err)}) catch "Error reading file";
            break :blk err_msg;
        };
        defer if (preview_content.len > 0) self.allocator.free(preview_content);

        var lines = std.mem.splitScalar(u8, preview_content, '\n');
        var line_idx: usize = 0;
        var display_line: usize = 1;

        const target_line = result.line_number;
        if (target_line > 0) {
            const half_height = preview_height / 2;
            if (target_line > half_height) {
                var skip_lines = target_line - half_height;
                while (skip_lines > 0 and lines.next() != null) : (skip_lines -= 1) {
                    line_idx += 1;
                }
            }
        }

        while (display_line < preview_height and lines.next()) |line| : (display_line += 1) {
            line_idx += 1;
            try writer.print("\x1B[{d};{d}H", .{ preview_y + 1 + display_line, preview_x + 1 });

            if (line_idx == result.line_number) {
                try writer.print("{s}{s}{s}", .{ HIGHLIGHT, truncateString(line, preview_width), RESET_STYLE });
            } else {
                try writer.print("{s}", .{truncateString(line, preview_width)});
            }
        }
    }

    fn truncateString(str: []const u8, max_len: usize) []const u8 {
        if (str.len <= max_len) return str;
        return str[0..max_len];
    }

    fn highlightMatch(self: *FuzzyFinder, writer: anytype, text: []const u8, query: []const u8) !void {
        if (query.len == 0) {
            try writer.print("{s}", .{text});
            return;
        }

        var match_positions = try self.allocator.alloc(bool, text.len);
        defer self.allocator.free(match_positions);

        @memset(match_positions, false);

        var q_idx: usize = 0;
        for (text, 0..) |char, i| {
            if (q_idx < query.len and std.ascii.toLower(char) == std.ascii.toLower(query[q_idx])) {
                match_positions[i] = true;
                q_idx += 1;
            }
        }

        var highlighted = false;
        for (text, 0..) |char, i| {
            if (match_positions[i] and !highlighted) {
                try writer.writeAll(YELLOW);
                highlighted = true;
            } else if (!match_positions[i] and highlighted) {
                try writer.writeAll(RESET_STYLE);
                highlighted = false;
            }
            try writer.writeByte(char);
        }

        if (highlighted) try writer.writeAll(RESET_STYLE);
    }

    pub fn render(self: *FuzzyFinder, writer: anytype) !void {
        const term_size = try self.getTerminalSize();

        var results_width = term_size.width;
        var results_height = term_size.height;

        switch (self.preview_mode) {
            .None => {},
            .Right => results_width = term_size.width / 2,
            .Bottom => results_height = term_size.height * 2 / 3,
        }

        const header_height = 3;
        const footer_height = 2;
        self.max_display = results_height - header_height - footer_height;

        try writer.writeAll(CLEAR_SCREEN);

        try writer.print("{s}=== Zig Fuzzy Finder ({s}) ==={s}\n", .{ BOLD, if (self.search_type == .Content) "Content Search" else "File Search", RESET_STYLE });

        try writer.print("Query: {s}{s}{s}\n\n", .{ BOLD, self.query, RESET_STYLE });

        if (self.cursor < self.offset) {
            self.offset = self.cursor;
        } else if (self.cursor >= self.offset + self.max_display) {
            self.offset = self.cursor - self.max_display + 1;
        }

        var display_count: usize = 0;
        for (self.results.items[self.offset..], self.offset..) |result, idx| {
            if (display_count >= self.max_display) break;

            const is_selected = self.selected_items.contains(idx);

            const prefix = if (is_selected) CYAN ++ "* " ++ RESET_STYLE else "  ";

            if (idx == self.cursor) {
                try writer.print("{s}{s}", .{ HIGHLIGHT, prefix });
            } else {
                try writer.print("{s}", .{prefix});
            }

            if (self.search_type == .Content) {
                try writer.print("{s}:{d}: ", .{ result.path, result.line_number });
                try self.highlightMatch(writer, result.content, self.query);
            } else {
                try self.highlightMatch(writer, result.path, self.query);
            }

            if (idx == self.cursor) {
                try writer.print("{s}", .{RESET_STYLE});
            }

            try writer.writeAll("\n");
            display_count += 1;
        }

        while (display_count < self.max_display) : (display_count += 1) {
            try writer.writeAll("~\n");
        }

        const total_pages = if (self.results.items.len == 0) 1 else (self.results.items.len + self.max_display - 1) / self.max_display;
        const current_page = if (self.results.items.len == 0) 1 else (self.offset / self.max_display) + 1;
        const selected_count = self.selected_items.count();

        try writer.print("\n{s}[{d}/{d} results] [{d} selected] [Page {d}/{d}]{s}\n", .{ GRAY, self.results.items.len, self.results.items.len, selected_count, current_page, total_pages, RESET_STYLE });

        try writer.print("{s}[↑/↓:Nav] [Tab:Mode] [Space:Select] [p:Preview] [/:Search] [Enter:Open] [Ctrl+C:Quit]{s}", .{ GRAY, RESET_STYLE });

        if (self.preview_mode != .None) {
            try self.renderPreview(writer, term_size);
        }
    }

    pub fn moveCursor(self: *FuzzyFinder, direction: enum { Up, Down, PageUp, PageDown, Home, End }) void {
        switch (direction) {
            .Up => {
                if (self.cursor > 0) self.cursor -= 1;
            },
            .Down => {
                if (self.cursor < self.results.items.len - 1) self.cursor += 1;
            },
            .PageUp => {
                if (self.cursor > self.max_display) {
                    self.cursor -= self.max_display;
                } else {
                    self.cursor = 0;
                }
            },
            .PageDown => {
                self.cursor += self.max_display;
                if (self.cursor >= self.results.items.len) {
                    self.cursor = @max(1, self.results.items.len) - 1;
                }
            },
            .Home => {
                self.cursor = 0;
            },
            .End => {
                self.cursor = @max(1, self.results.items.len) - 1;
            },
        }
    }

    pub fn getSelected(self: *FuzzyFinder) ?search.SearchResult {
        if (self.results.items.len == 0 or self.cursor >= self.results.items.len) {
            return null;
        }
        return self.results.items[self.cursor];
    }

    pub fn getSelectedItems(self: *FuzzyFinder) !std.ArrayList(search.SearchResult) {
        var selected = std.ArrayList(search.SearchResult).init(self.allocator);
        errdefer selected.deinit();

        if (self.selected_items.count() > 0) {
            var it = self.selected_items.keyIterator();
            while (it.next()) |idx| {
                if (idx.* < self.results.items.len) {
                    const item = try self.allocator.dupe(search.SearchResult, &[_]search.SearchResult{self.results.items[idx.*]});
                    try selected.append(item[0]);
                }
            }
        } else if (self.getSelected()) |current| {
            const item = try self.allocator.dupe(search.SearchResult, &[_]search.SearchResult{current});
            try selected.append(item[0]);
        }

        return selected;
    }

    pub fn toggleSelectItem(self: *FuzzyFinder) !void {
        if (self.results.items.len == 0 or self.cursor >= self.results.items.len) {
            return;
        }

        if (self.selected_items.contains(self.cursor)) {
            _ = self.selected_items.remove(self.cursor);
        } else {
            try self.selected_items.put(self.cursor, {});
        }
    }

    pub fn toggleSearchType(self: *FuzzyFinder) void {
        self.search_type = switch (self.search_type) {
            .Content => .Files,
            .Files => .Content,
        };
    }

    pub fn cyclePreviewMode(self: *FuzzyFinder) void {
        self.preview_mode = switch (self.preview_mode) {
            .None => .Right,
            .Right => .Bottom,
            .Bottom => .None,
        };
    }

    pub fn previousHistoryQuery(self: *FuzzyFinder) !void {
        if (self.history.items.len == 0 or self.history_index == 0) return;

        self.history_index -= 1;
        try self.setQuery(self.history.items[self.history_index]);
    }

    pub fn nextHistoryQuery(self: *FuzzyFinder) !void {
        if (self.history.items.len == 0 or self.history_index >= self.history.items.len) return;

        self.history_index += 1;
        if (self.history_index >= self.history.items.len) {
            try self.setQuery("");
        } else {
            try self.setQuery(self.history.items[self.history_index]);
        }
    }
};

pub const RawTerminal = struct {
    original_termios: c.termios,

    pub fn init() !RawTerminal {
        const fd = std.io.getStdIn().handle;
        var original: c.termios = undefined;

        if (c.tcgetattr(fd, &original) == -1) {
            return error.TerminalConfigError;
        }

        var raw = original;

        raw.c_iflag &= ~@as(c_uint, c.IGNBRK | c.BRKINT | c.PARMRK | c.ISTRIP |
            c.INLCR | c.IGNCR | c.ICRNL | c.IXON);

        raw.c_oflag &= ~@as(c_uint, c.OPOST);

        raw.c_cflag |= c.CS8;

        raw.c_lflag &= ~@as(c_uint, c.ECHO | c.ECHONL | c.ICANON | c.ISIG | c.IEXTEN);

        raw.c_cc[c.VMIN] = 1;
        raw.c_cc[c.VTIME] = 0;

        if (c.tcsetattr(fd, c.TCSAFLUSH, &raw) == -1) {
            return error.TerminalConfigError;
        }

        return RawTerminal{ .original_termios = original };
    }

    pub fn deinit(self: *RawTerminal) void {
        const fd = std.io.getStdIn().handle;
        _ = c.tcsetattr(fd, c.TCSAFLUSH, &self.original_termios);
    }

    pub const KeyEvent = union(enum) {
        char: u8,
        enter,
        escape,
        backspace,
        delete,
        arrow_up,
        arrow_down,
        arrow_left,
        arrow_right,
        page_up,
        page_down,
        home,
        end,
        tab,
        space,
        ctrl: u8,
    };

    pub fn readKey(self: *RawTerminal) !KeyEvent {
        _ = self;
        var buffer: [4]u8 = undefined;
        const stdin = std.io.getStdIn().reader();

        const n = try stdin.read(&buffer);
        if (n == 0) return error.EndOfFile;

        if (n == 1) {
            return switch (buffer[0]) {
                '\r', '\n' => KeyEvent.enter,
                '\x1B' => KeyEvent.escape,
                127 => KeyEvent.backspace,
                8 => KeyEvent.backspace,
                '\t' => KeyEvent.tab,
                ' ' => KeyEvent.space,
                1...26 => KeyEvent{ .ctrl = @as(u8, buffer[0] + 'a' - 1) },
                else => KeyEvent{ .char = buffer[0] },
            };
        } else if (n >= 3 and buffer[0] == '\x1B' and buffer[1] == '[') {
            return switch (buffer[2]) {
                'A' => KeyEvent.arrow_up,
                'B' => KeyEvent.arrow_down,
                'C' => KeyEvent.arrow_right,
                'D' => KeyEvent.arrow_left,
                'H' => KeyEvent.home,
                'F' => KeyEvent.end,
                '5' => if (n >= 4 and buffer[3] == '~') KeyEvent.page_up else KeyEvent.escape,
                '6' => if (n >= 4 and buffer[3] == '~') KeyEvent.page_down else KeyEvent.escape,
                '3' => if (n >= 4 and buffer[3] == '~') KeyEvent.delete else KeyEvent.escape,
                '1' => if (n >= 4 and buffer[3] == '~') KeyEvent.home else KeyEvent.escape,
                '4' => if (n >= 4 and buffer[3] == '~') KeyEvent.end else KeyEvent.escape,
                '7' => if (n >= 4 and buffer[3] == '~') KeyEvent.home else KeyEvent.escape,
                '8' => if (n >= 4 and buffer[3] == '~') KeyEvent.end else KeyEvent.escape,
                else => KeyEvent.escape,
            };
        } else if (n == 3 and buffer[0] == '\x1B' and buffer[1] == 'O') {
            return switch (buffer[2]) {
                'H' => KeyEvent.home,
                'F' => KeyEvent.end,
                'A' => KeyEvent.arrow_up,
                'B' => KeyEvent.arrow_down,
                'C' => KeyEvent.arrow_right,
                'D' => KeyEvent.arrow_left,
                else => KeyEvent.escape,
            };
        }

        return KeyEvent.escape;
    }
};
