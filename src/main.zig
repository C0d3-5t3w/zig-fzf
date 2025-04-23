const std = @import("std");
const cli = @import("cli/cli.zig");
const search = @import("search/search.zig");

pub fn fuzzyMatch(pattern: []const u8, text: []const u8) u32 {
    if (pattern.len == 0) return 0;
    if (text.len == 0) return 0;

    var score: u32 = 0;
    var pattern_idx: usize = 0;
    var last_match_idx: usize = 0;
    var consecutive_matches: u32 = 0;

    for (text, 0..) |c, i| {
        if (pattern_idx < pattern.len and std.ascii.toLower(c) == std.ascii.toLower(pattern[pattern_idx])) {
            score += 10;

            if (i == 0 or (i > 0 and (text[i - 1] == '/' or text[i - 1] == '.' or text[i - 1] == '_' or text[i - 1] == ' '))) {
                score += 20;
            }

            if (pattern_idx > 0 and i > 0 and i == last_match_idx + 1) {
                consecutive_matches += 1;
                score += consecutive_matches * 5;
            } else {
                consecutive_matches = 0;
            }

            if (c == pattern[pattern_idx]) {
                score += 5;
            }

            last_match_idx = i;
            pattern_idx += 1;

            if (pattern_idx == pattern.len) {
                score += 50;

                if (i == text.len - 1) {
                    score += 100;
                }
                break;
            }
        }
    }

    if (pattern_idx < pattern.len) {
        score = score / 2;
    }

    return score;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var directory: ?[]const u8 = null;
    var initial_query: ?[]const u8 = null;
    var search_type: enum { Content, Files } = .Content;
    var preview_mode: cli.PreviewMode = .Right;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-d") or std.mem.eql(u8, arg, "--dir")) {
            if (i + 1 < args.len) {
                directory = args[i + 1];
                i += 1;
            }
        } else if (std.mem.eql(u8, arg, "-f") or std.mem.eql(u8, arg, "--files")) {
            search_type = .Files;
        } else if (std.mem.eql(u8, arg, "--no-preview")) {
            preview_mode = .None;
        } else if (std.mem.eql(u8, arg, "--preview-bottom")) {
            preview_mode = .Bottom;
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            printHelp();
            return;
        } else if (std.mem.eql(u8, arg, "--interactive-test")) {
            return try runInteractiveTest(allocator);
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            initial_query = arg;
        }
    }

    var raw_term = try cli.RawTerminal.init();
    defer raw_term.deinit();

    var fuzzy = cli.FuzzyFinder.init(allocator);
    defer fuzzy.deinit();

    if (search_type == .Files) {
        fuzzy.toggleSearchType();
    }

    fuzzy.preview_mode = preview_mode;

    if (initial_query) |query| {
        try fuzzy.setQuery(query);
    } else {
        try fuzzy.setQuery("");
    }

    const search_options = search.SearchOptions{
        .directory = directory,
        .case_sensitive = false,
        .search_hidden = false,
    };

    try fuzzy.updateSearch(search_options);

    const stdout = std.io.getStdOut().writer();
    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();

    const writer = buffer.writer();

    var running = true;
    var input_mode = false;
    var new_query = std.ArrayList(u8).init(allocator);
    defer new_query.deinit();

    while (running) {
        buffer.clearRetainingCapacity();
        try fuzzy.render(writer);
        try stdout.writeAll(buffer.items);

        const key_event = try raw_term.readKey();

        if (input_mode) {
            switch (key_event) {
                .char => |c| {
                    try new_query.append(c);
                    try stdout.print("{c}", .{c});
                },
                .backspace => {
                    if (new_query.items.len > 0) {
                        _ = new_query.pop();
                        try stdout.writeAll("\x08 \x08");
                    }
                },
                .enter => {
                    input_mode = false;
                    try fuzzy.setQuery(new_query.items);
                    try fuzzy.updateSearch(search_options);
                    new_query.clearRetainingCapacity();
                },
                .escape => {
                    input_mode = false;
                    new_query.clearRetainingCapacity();
                },
                else => {},
            }
        } else {
            switch (key_event) {
                .char => |c| {
                    switch (c) {
                        '/' => {
                            input_mode = true;
                            new_query.clearRetainingCapacity();
                            try stdout.print("\rEnter search: ", .{});
                        },
                        'p' => {
                            fuzzy.cyclePreviewMode();
                        },
                        'j' => fuzzy.moveCursor(.Down),
                        'k' => fuzzy.moveCursor(.Up),
                        'g' => fuzzy.moveCursor(.Home),
                        'G' => fuzzy.moveCursor(.End),
                        'q' => {
                            try stdout.writeAll(cli.CLEAR_SCREEN);
                            running = false;
                        },
                        else => {
                            const updated_query = try std.fmt.allocPrint(allocator, "{s}{c}", .{ fuzzy.query, c });
                            try fuzzy.setQuery(updated_query);
                            try fuzzy.updateSearch(search_options);
                        },
                    }
                },
                .backspace => {
                    if (fuzzy.query.len > 0) {
                        const updated_query = try allocator.dupe(u8, fuzzy.query[0 .. fuzzy.query.len - 1]);
                        try fuzzy.setQuery(updated_query);
                        try fuzzy.updateSearch(search_options);
                    }
                },
                .arrow_up => fuzzy.moveCursor(.Up),
                .arrow_down => fuzzy.moveCursor(.Down),
                .page_up => fuzzy.moveCursor(.PageUp),
                .page_down => fuzzy.moveCursor(.PageDown),
                .home => fuzzy.moveCursor(.Home),
                .end => fuzzy.moveCursor(.End),
                .tab => {
                    fuzzy.toggleSearchType();
                    try fuzzy.updateSearch(search_options);
                },
                .space => {
                    try fuzzy.toggleSelectItem();
                },
                .enter => {
                    const selected_items = try fuzzy.getSelectedItems();
                    defer selected_items.deinit();

                    if (selected_items.items.len > 0) {
                        try stdout.writeAll(cli.CLEAR_SCREEN);
                        raw_term.deinit();

                        for (selected_items.items) |selected| {
                            try stdout.print("{s}:{d}: {s}\n", .{ selected.path, selected.line_number, selected.content });
                        }

                        return;
                    }
                },
                .ctrl => |c| {
                    switch (c) {
                        'c' => {
                            try stdout.writeAll(cli.CLEAR_SCREEN);
                            running = false;
                        },
                        'p' => try fuzzy.previousHistoryQuery(),
                        'n' => try fuzzy.nextHistoryQuery(),
                        else => {},
                    }
                },
                else => {},
            }
        }
    }
}

fn runInteractiveTest(allocator: std.mem.Allocator) !void {
    std.debug.print("\nRunning interactive fuzzy finder test...\n", .{});
    std.debug.print("Press Ctrl+C to exit the test\n\n", .{});

    var raw_term = try cli.RawTerminal.init();
    defer raw_term.deinit();

    var fuzzy = cli.FuzzyFinder.init(allocator);
    defer fuzzy.deinit();

    try fuzzy.setQuery("");

    const search_options = search.SearchOptions{
        .directory = ".",
        .case_sensitive = false,
        .search_hidden = false,
    };

    const stdout = std.io.getStdOut().writer();
    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();

    const writer = buffer.writer();

    var running = true;
    while (running) {
        buffer.clearRetainingCapacity();
        try fuzzy.render(writer);
        try stdout.writeAll(buffer.items);

        const key_event = try raw_term.readKey();

        switch (key_event) {
            .char => |c| {
                if (c == 'q') {
                    running = false;
                } else if (c == 'p') {
                    fuzzy.cyclePreviewMode();
                } else {
                    const query_with_char = try std.fmt.allocPrint(allocator, "{s}{c}", .{ fuzzy.query, c });
                    try fuzzy.setQuery(query_with_char);
                    try fuzzy.updateSearch(search_options);
                }
            },
            .backspace => {
                if (fuzzy.query.len > 0) {
                    const new_query = try allocator.dupe(u8, fuzzy.query[0 .. fuzzy.query.len - 1]);
                    try fuzzy.setQuery(new_query);
                    try fuzzy.updateSearch(search_options);
                }
            },
            .arrow_up => fuzzy.moveCursor(.Up),
            .arrow_down => fuzzy.moveCursor(.Down),
            .page_up => fuzzy.moveCursor(.PageUp),
            .page_down => fuzzy.moveCursor(.PageDown),
            .tab => {
                fuzzy.toggleSearchType();
                try fuzzy.updateSearch(search_options);
            },
            .space => {
                try fuzzy.toggleSelectItem();
            },
            .enter => {
                const selected = fuzzy.getSelected();
                if (selected) |result| {
                    try stdout.writeAll(cli.CLEAR_SCREEN);
                    try stdout.print("Selected: {s}:{d}: {s}\n", .{ result.path, result.line_number, result.content });
                    try stdout.print("\nPress any key to continue...", .{});
                    _ = try raw_term.readKey();
                }
            },
            .ctrl => |c| {
                if (c == 'c') {
                    running = false;
                }
            },
            else => {},
        }
    }

    try stdout.writeAll(cli.CLEAR_SCREEN);
    std.debug.print("Interactive test completed.\n", .{});
}

fn printHelp() void {
    const stdout = std.io.getStdOut().writer();
    stdout.print(
        \\Zig Fuzzy Finder - A telescope-like fuzzy finder for the terminal
        \\
        \\Usage: zig_fzf [options] [initial_query]
        \\
        \\Options:
        \\  -d, --dir DIRECTORY   Specify the search directory
        \\  -f, --files           Start in file search mode (default is content search)
        \\  --no-preview          Disable preview pane
        \\  --preview-bottom      Show preview pane at bottom (default is right)
        \\  -h, --help            Show this help message
        \\  --interactive-test    Run interactive fuzzy finder test
        \\
        \\Keyboard Controls:
        \\  Up/Down, j/k         Navigate through results
        \\  PgUp/PgDn            Navigate pages
        \\  /                    Search mode
        \\  Space                Select/deselect item
        \\  Tab                  Toggle between content/file search
        \\  p                    Cycle through preview modes
        \\  Enter                Confirm selection
        \\  Ctrl+c               Exit
        \\  Ctrl+p, Ctrl+n       Navigate search history
        \\
    , .{}) catch {};
}

test "simple test" {
    var list = std.ArrayList(i32).init(std.testing.allocator);
    defer list.deinit();
    try list.append(42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}

test "use other module" {
    try std.testing.expectEqual(@as(u32, 105), fuzzyMatch("abc", "abcd"));
}

test "interactive test" {
    if (@import("builtin").is_test) {
        std.debug.print("\nTo run the interactive test, use: zig build run -- --interactive-test\n", .{});
    }
}
