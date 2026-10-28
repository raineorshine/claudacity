//! Mirror user-scoped MCP servers (`mcpServers` in `~/.claude.<profile>.json`)
//! through Claude's own `claude mcp` CLI. claude.ai connectors are account-synced
//! and never appear in `mcpServers`, so they stay with their own accounts.

const std = @import("std");
const desktop = @import("desktop.zig");
const display = @import("display.zig");
const paths = @import("paths.zig");

pub const SyncResult = struct {
    added: usize = 0,
    updated: usize = 0,
};

const Change = struct {
    name: []const u8,
    /// The source's entry, serialized for `claude mcp add-json`.
    json: []u8,
    /// The target has a different entry under this name, removed first.
    replace: bool,
};

fn servers(value: std.json.Value) ?std.json.ObjectMap {
    if (value != .object) return null;
    const field = value.object.get("mcpServers") orelse return null;
    return if (field == .object) field.object else null;
}

fn isEmpty(value: std.json.Value) bool {
    return switch (value) {
        .array => |a| a.items.len == 0,
        .object => |o| o.count() == 0,
        .null => true,
        else => false,
    };
}

/// Deep equality where an absent key matches an empty `args` or `env`: Claude
/// writes `"args": []` into an entry added without one, and that alone must not
/// re-add the server on every switch.
fn same(a: std.json.Value, b: std.json.Value) bool {
    switch (a) {
        .object => |ao| {
            if (b != .object) return false;
            const bo = b.object;
            var it = ao.iterator();
            while (it.next()) |entry| {
                const other = bo.get(entry.key_ptr.*) orelse {
                    if (isEmpty(entry.value_ptr.*)) continue;
                    return false;
                };
                if (!same(entry.value_ptr.*, other)) return false;
            }
            var back = bo.iterator();
            while (back.next()) |entry| {
                if (ao.get(entry.key_ptr.*) == null and !isEmpty(entry.value_ptr.*)) return false;
            }
            return true;
        },
        .array => |aa| {
            if (b != .array or b.array.items.len != aa.items.len) return false;
            for (aa.items, b.array.items) |x, y| if (!same(x, y)) return false;
            return true;
        },
        .string => |s| return b == .string and std.mem.eql(u8, s, b.string),
        .integer => |i| return b == .integer and b.integer == i,
        .float => |f| return b == .float and b.float == f,
        .number_string => |s| return b == .number_string and std.mem.eql(u8, s, b.number_string),
        .bool => |v| return b == .bool and b.bool == v,
        .null => return b == .null,
    }
}

fn freeChanges(gpa: std.mem.Allocator, changes: *std.ArrayList(Change)) void {
    for (changes.items) |c| gpa.free(c.json);
    changes.deinit(gpa);
}

/// What the target needs so every source server matches. Servers only the
/// target has stay, as target-only plugins do. Names borrow from `source`.
fn plan(gpa: std.mem.Allocator, source: std.json.Value, target: std.json.Value) !std.ArrayList(Change) {
    var changes: std.ArrayList(Change) = .empty;
    errdefer freeChanges(gpa, &changes);
    const from = servers(source) orelse return changes;
    const to = servers(target);
    var it = from.iterator();
    while (it.next()) |entry| {
        const existing = if (to) |t| t.get(entry.key_ptr.*) else null;
        if (existing) |e| if (same(entry.value_ptr.*, e)) continue;
        const json = try std.json.Stringify.valueAlloc(gpa, entry.value_ptr.*, .{});
        errdefer gpa.free(json);
        try changes.append(gpa, .{ .name = entry.key_ptr.*, .json = json, .replace = existing != null });
    }
    return changes;
}

fn readProfile(gpa: std.mem.Allocator, io: std.Io, path: []const u8) !std.json.Parsed(std.json.Value) {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(64 * 1024 * 1024));
    defer gpa.free(bytes);
    return std.json.parseFromSlice(std.json.Value, gpa, bytes, .{ .allocate = .alloc_always });
}

/// Runs `claude` against the profile JSON at `config_link`'s directory: Claude
/// reads `$CLAUDE_CONFIG_DIR/.claude.json`, and writes through the symlink there
/// to the profile's own file, with the same locking a live session uses.
fn runClaude(gpa: std.mem.Allocator, io: std.Io, config_dir: []const u8, args: []const []const u8) !void {
    const env_arg = try std.fmt.allocPrint(gpa, "CLAUDE_CONFIG_DIR={s}", .{config_dir});
    defer gpa.free(env_arg);
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.appendSlice(gpa, &.{ "env", env_arg, "claude", "mcp" });
    try argv.appendSlice(gpa, args);
    const result = try std.process.run(gpa, io, .{
        .argv = argv.items,
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(16 * 1024),
    });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) return error.ClaudeMcpCommandFailed;
}

pub fn syncIn(gpa: std.mem.Allocator, io: std.Io, base: []const u8, source: []const u8, target: []const u8) !SyncResult {
    const source_json = try paths.profileJsonIn(gpa, base, source);
    defer gpa.free(source_json);
    const target_json = try paths.profileJsonIn(gpa, base, target);
    defer gpa.free(target_json);
    const target_dir = try paths.profileDirIn(gpa, base, target);
    defer gpa.free(target_dir);
    if (!desktop.pathExists(gpa, source_json) or !desktop.pathExists(gpa, target_json)) return error.ProfileNotFound;

    var from = try readProfile(gpa, io, source_json);
    defer from.deinit();
    var to = try readProfile(gpa, io, target_json);
    defer to.deinit();
    var changes = try plan(gpa, from.value, to.value);
    defer freeChanges(gpa, &changes);
    var result: SyncResult = .{};
    if (changes.items.len == 0) return result;

    // A config dir holding only a link to the target's JSON, so `claude mcp`
    // edits that profile whether or not it is the active one.
    const config_dir = try std.fs.path.join(gpa, &.{ target_dir, ".claudacity-mcp" });
    defer gpa.free(config_dir);
    const cwd = std.Io.Dir.cwd();
    cwd.deleteTree(io, config_dir) catch {};
    try cwd.createDirPath(io, config_dir);
    defer cwd.deleteTree(io, config_dir) catch {};
    const link = try std.fs.path.join(gpa, &.{ config_dir, ".claude.json" });
    defer gpa.free(link);
    try cwd.symLink(io, target_json, link, .{});

    for (changes.items) |change| {
        if (change.replace) {
            display.print("Updating MCP server '{s}' in '{s}'\n", .{ change.name, target });
            try runClaude(gpa, io, config_dir, &.{ "remove", "--scope", "user", change.name });
            result.updated += 1;
        } else {
            display.print("Adding MCP server '{s}' to '{s}'\n", .{ change.name, target });
            result.added += 1;
        }
        // add-json takes the entry only as an argument, so an `env` or
        // `headers` secret in it is briefly visible in `ps`.
        try runClaude(gpa, io, config_dir, &.{ "add-json", "--scope", "user", change.name, change.json });
    }
    return result;
}

fn parse(text: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, std.testing.allocator, text, .{});
}

test "plan adds missing servers, replaces differing ones and keeps target-only ones" {
    const alloc = std.testing.allocator;
    var source = try parse(
        \\{"mcpServers":{
        \\  "supernova":{"type":"stdio","command":"node","args":["s.mts"],"env":{"NODE_USE_SYSTEM_CA":"1"}},
        \\  "spotify":{"type":"stdio","command":"npx","args":["spotify"],"env":{}},
        \\  "docs":{"type":"http","url":"https://new.example/mcp"}}}
    );
    defer source.deinit();
    var target = try parse(
        \\{"mcpServers":{
        \\  "spotify":{"type":"stdio","env":{},"args":["spotify"],"command":"npx"},
        \\  "docs":{"type":"http","url":"https://old.example/mcp"},
        \\  "mine":{"type":"stdio","command":"only-here"}}}
    );
    defer target.deinit();

    var changes = try plan(alloc, source.value, target.value);
    defer freeChanges(alloc, &changes);
    try std.testing.expectEqual(@as(usize, 2), changes.items.len);
    try std.testing.expectEqualStrings("supernova", changes.items[0].name);
    try std.testing.expect(!changes.items[0].replace);
    try std.testing.expectEqualStrings(
        \\{"type":"stdio","command":"node","args":["s.mts"],"env":{"NODE_USE_SYSTEM_CA":"1"}}
    , changes.items[0].json);
    try std.testing.expectEqualStrings("docs", changes.items[1].name);
    try std.testing.expect(changes.items[1].replace);
}

test "plan treats Claude's added empty args and env as the same server" {
    const alloc = std.testing.allocator;
    var source = try parse("{\"mcpServers\":{\"a\":{\"command\":\"x\"}}}");
    defer source.deinit();
    var target = try parse("{\"mcpServers\":{\"a\":{\"command\":\"x\",\"args\":[],\"env\":{}}}}");
    defer target.deinit();
    var changes = try plan(alloc, source.value, target.value);
    defer freeChanges(alloc, &changes);
    try std.testing.expectEqual(@as(usize, 0), changes.items.len);

    var differs = try parse("{\"mcpServers\":{\"a\":{\"command\":\"x\",\"args\":[\"-v\"]}}}");
    defer differs.deinit();
    var changed = try plan(alloc, source.value, differs.value);
    defer freeChanges(alloc, &changed);
    try std.testing.expectEqual(@as(usize, 1), changed.items.len);
}

test "plan copies every server into a profile without mcpServers and nothing from one without" {
    const alloc = std.testing.allocator;
    var source = try parse("{\"mcpServers\":{\"a\":{\"command\":\"x\"}}}");
    defer source.deinit();
    var bare = try parse("{\"userID\":\"u\"}");
    defer bare.deinit();
    var into_bare = try plan(alloc, source.value, bare.value);
    defer freeChanges(alloc, &into_bare);
    try std.testing.expectEqual(@as(usize, 1), into_bare.items.len);
    var from_bare = try plan(alloc, bare.value, source.value);
    defer freeChanges(alloc, &from_bare);
    try std.testing.expectEqual(@as(usize, 0), from_bare.items.len);
}
