const std = @import("std");
const main = @import("../main.zig");

pub const SearchResult = struct {
    path: []const u8,
    line_number: usize,
    content: []const u8,
    score: u32 = 0,

    pub fn deinit(self: *SearchResult, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.content);
    }
};

pub const SearchOptions = struct {
    case_sensitive: bool = false,
    search_hidden: bool = false,
    max_results: ?usize = null,
    directory: ?[]const u8 = null,
};

pub fn searchWithRipgrep(
    allocator: std.mem.Allocator,
    query: []const u8,
    options: SearchOptions,
) !std.ArrayList(SearchResult) {
    var results = std.ArrayList(SearchResult).init(allocator);
    errdefer {
        for (results.items) |*item| {
            item.deinit(allocator);
        }
        results.deinit();
    }

    var args = std.ArrayList([]const u8).init(allocator);
    defer args.deinit();

    try args.append("rg");
    try args.append("--line-number");
    try args.append("--with-filename");
    try args.append("--color=never");

    if (!options.case_sensitive) {
        try args.append("--ignore-case");
    }

    if (options.search_hidden) {
        try args.append("--hidden");
    }

    if (options.max_results) |max| {
        const max_str = try std.fmt.allocPrint(allocator, "--max-count={d}", .{max});
        defer allocator.free(max_str);
        try args.append(max_str);
    }

    try args.append(query);

    if (options.directory) |dir| {
        try args.append(dir);
    }

    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = args.items,
        .max_output_bytes = 10 * 1024 * 1024,
    });

    defer allocator.free(result.stderr);
    defer allocator.free(result.stdout);

    if (result.term.Exited != 0 and result.term.Exited != 1) {
        const err_msg = try std.fmt.allocPrint(allocator, "ripgrep failed with exit code {d}: {s}", .{ result.term.Exited, result.stderr });
        defer allocator.free(err_msg);
        return error.RipgrepFailed;
    }

    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;

        var parts = std.mem.splitScalar(u8, line, ':');
        const file_path = parts.next() orelse continue;
        const line_number_str = parts.next() orelse continue;
        const content = parts.rest();

        const line_number = std.fmt.parseInt(usize, line_number_str, 10) catch continue;

        const path_copy = try allocator.dupe(u8, file_path);
        const content_copy = try allocator.dupe(u8, content);

        try results.append(.{
            .path = path_copy,
            .line_number = line_number,
            .content = content_copy,
            .score = main.fuzzyMatch(query, content),
        });
    }

    return results;
}

pub fn findFiles(
    allocator: std.mem.Allocator,
    pattern: []const u8,
    options: SearchOptions,
) !std.ArrayList(SearchResult) {
    var args = std.ArrayList([]const u8).init(allocator);
    defer args.deinit();

    try args.append("rg");
    try args.append("--files");
    try args.append("--color=never");

    if (options.search_hidden) {
        try args.append("--hidden");
    }

    if (pattern.len > 0) {
        try args.append("--glob");
        const glob_pattern = try std.fmt.allocPrint(allocator, "*{s}*", .{pattern});
        defer allocator.free(glob_pattern);
        try args.append(glob_pattern);
    }

    if (options.directory) |dir| {
        try args.append(dir);
    }

    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = args.items,
        .max_output_bytes = 10 * 1024 * 1024,
    });

    defer allocator.free(result.stderr);
    defer allocator.free(result.stdout);

    var results = std.ArrayList(SearchResult).init(allocator);
    errdefer {
        for (results.items) |*item| {
            item.deinit(allocator);
        }
        results.deinit();
    }

    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;

        const path_copy = try allocator.dupe(u8, line);
        const content_copy = try allocator.dupe(u8, "");

        try results.append(.{
            .path = path_copy,
            .line_number = 0,
            .content = content_copy,
            .score = main.fuzzyMatch(pattern, line),
        });
    }

    std.sort.pdq(SearchResult, results.items, {}, struct {
        fn lessThan(_: void, lhs: SearchResult, rhs: SearchResult) bool {
            return lhs.score > rhs.score;
        }
    }.lessThan);

    return results;
}
