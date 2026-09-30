//! Carries Claude Desktop's app preferences and MCP servers from the profile
//! being left to the one being switched to, so settings stay in sync across
//! accounts. Account state (logins, cookies, Remote Control connection) stays
//! in each profile's own data directory.

const std = @import("std");

const config_name = "claude_desktop_config.json";
/// Top-level keys of `claude_desktop_config.json` shared across profiles.
const shared_keys = [_][]const u8{ "preferences", "mcpServers" };
/// Preferences Desktop derives from the signed-in account's organization.
/// Each profile keeps its own.
const account_prefs = [_][]const u8{ "coworkHipaaRestricted", "orgWorkAcrossAppsDisabled" };

/// Copies the shared keys of `from_dir`'s config into `to_dir`'s, keeping
/// every other key of the target. A key missing from the source is removed
/// from the target. Returns false when the source has no config to carry.
pub fn carryIn(gpa: std.mem.Allocator, io: std.Io, from_dir: []const u8, to_dir: []const u8) !bool {
    const src_path = try std.fs.path.join(gpa, &.{ from_dir, config_name });
    defer gpa.free(src_path);
    const dst_path = try std.fs.path.join(gpa, &.{ to_dir, config_name });
    defer gpa.free(dst_path);

    const src_text = std.Io.Dir.cwd().readFileAlloc(io, src_path, gpa, .limited(4 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    defer gpa.free(src_text);
    const src = try std.json.parseFromSlice(std.json.Value, gpa, src_text, .{});
    defer src.deinit();
    if (src.value != .object) return error.InvalidDesktopConfig;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var dst: std.json.Value = .{ .object = .empty };
    if (std.Io.Dir.cwd().readFileAlloc(io, dst_path, arena, .limited(4 * 1024 * 1024))) |dst_text| {
        dst = try std.json.parseFromSliceLeaky(std.json.Value, arena, dst_text, .{});
        if (dst != .object) return error.InvalidDesktopConfig;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }

    const dst_prefs = dst.object.get("preferences");
    for (shared_keys) |key| {
        if (src.value.object.get(key)) |v| {
            try dst.object.put(arena, key, v);
        } else {
            _ = dst.object.orderedRemove(key);
        }
    }
    if (dst.object.getPtr("preferences")) |prefs| {
        if (prefs.* == .object) {
            prefs.* = try mergeAccountPrefs(arena, prefs.object, if (dst_prefs) |d| if (d == .object) d.object else null else null);
        }
    }

    const text = try std.json.Stringify.valueAlloc(gpa, dst, .{ .whitespace = .indent_2 });
    defer gpa.free(text);
    try std.Io.Dir.cwd().createDirPath(io, to_dir);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = dst_path, .data = text, .flags = .{ .permissions = .fromMode(0o600) } });
    return true;
}

/// A copy of the source preferences that keeps the target's org-derived keys
/// and, for maps keyed by account (`...ByAccount`), the target's entries the
/// source lacks.
fn mergeAccountPrefs(arena: std.mem.Allocator, src: std.json.ObjectMap, dst: ?std.json.ObjectMap) !std.json.Value {
    var out = try src.clone(arena);
    for (account_prefs) |key| {
        _ = out.orderedRemove(key);
        if (dst) |d| if (d.get(key)) |v| try out.put(arena, key, v);
    }
    const d = dst orelse return .{ .object = out };
    var it = d.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        if (!std.mem.endsWith(u8, key, "ByAccount") or entry.value_ptr.* != .object) continue;
        const merged = out.getPtr(key) orelse {
            try out.put(arena, key, entry.value_ptr.*);
            continue;
        };
        if (merged.* != .object) continue;
        var by_account = try merged.object.clone(arena);
        var accounts = entry.value_ptr.object.iterator();
        while (accounts.next()) |a| {
            if (!by_account.contains(a.key_ptr.*)) try by_account.put(arena, a.key_ptr.*, a.value_ptr.*);
        }
        merged.* = .{ .object = by_account };
    }
    return .{ .object = out };
}

// ── Tests ─────────────────────────────────────────────────────────────────────

const Fixture = struct {
    tmp: std.testing.TmpDir,
    base: []const u8,

    fn init() !Fixture {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const n = try tmp.dir.realPath(std.testing.io, &buf);
        return .{ .tmp = tmp, .base = try std.testing.allocator.dupe(u8, buf[0..n]) };
    }

    fn deinit(f: *Fixture) void {
        std.testing.allocator.free(f.base);
        f.tmp.cleanup();
    }

    fn dir(f: Fixture, name: []const u8) ![]const u8 {
        return std.fs.path.join(std.testing.allocator, &.{ f.base, name });
    }

    fn write(f: Fixture, name: []const u8, data: []const u8) !void {
        const d = try f.dir(name);
        defer std.testing.allocator.free(d);
        try std.Io.Dir.cwd().createDirPath(std.testing.io, d);
        const p = try std.fs.path.join(std.testing.allocator, &.{ d, config_name });
        defer std.testing.allocator.free(p);
        try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = p, .data = data });
    }

    fn read(f: Fixture, name: []const u8) !std.json.Parsed(std.json.Value) {
        const p = try std.fs.path.join(std.testing.allocator, &.{ f.base, name, config_name });
        defer std.testing.allocator.free(p);
        const text = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, p, std.testing.allocator, .limited(1 << 20));
        defer std.testing.allocator.free(text);
        return std.json.parseFromSlice(std.json.Value, std.testing.allocator, text, .{});
    }
};

test "carryIn copies preferences and MCP servers, keeps target's other keys" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.write("from", "{\"preferences\":{\"remoteControl\":true},\"mcpServers\":{\"a\":{\"command\":\"x\"}},\"other\":1}");
    try f.write("to", "{\"preferences\":{\"remoteControl\":false},\"own\":\"keep\"}");

    const from = try f.dir("from");
    defer std.testing.allocator.free(from);
    const to = try f.dir("to");
    defer std.testing.allocator.free(to);
    try std.testing.expect(try carryIn(std.testing.allocator, std.testing.io, from, to));

    const got = try f.read("to");
    defer got.deinit();
    const o = got.value.object;
    try std.testing.expect(o.get("preferences").?.object.get("remoteControl").?.bool);
    try std.testing.expect(o.get("mcpServers").?.object.contains("a"));
    try std.testing.expectEqualStrings("keep", o.get("own").?.string);
    try std.testing.expect(!o.contains("other"));
}

test "carryIn removes MCP servers the source no longer has" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.write("from", "{\"preferences\":{}}");
    try f.write("to", "{\"mcpServers\":{\"old\":{}}}");

    const from = try f.dir("from");
    defer std.testing.allocator.free(from);
    const to = try f.dir("to");
    defer std.testing.allocator.free(to);
    try std.testing.expect(try carryIn(std.testing.allocator, std.testing.io, from, to));

    const got = try f.read("to");
    defer got.deinit();
    try std.testing.expect(!got.value.object.contains("mcpServers"));
}

test "carryIn creates the target config for a fresh profile" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.write("from", "{\"preferences\":{\"keepAwake\":true}}");

    const from = try f.dir("from");
    defer std.testing.allocator.free(from);
    const to = try f.dir("to");
    defer std.testing.allocator.free(to);
    try std.testing.expect(try carryIn(std.testing.allocator, std.testing.io, from, to));

    const got = try f.read("to");
    defer got.deinit();
    try std.testing.expect(got.value.object.get("preferences").?.object.get("keepAwake").?.bool);
}

test "carryIn does nothing without a source config" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.write("to", "{\"own\":1}");

    const from = try f.dir("from");
    defer std.testing.allocator.free(from);
    const to = try f.dir("to");
    defer std.testing.allocator.free(to);
    try std.testing.expect(!try carryIn(std.testing.allocator, std.testing.io, from, to));

    const got = try f.read("to");
    defer got.deinit();
    try std.testing.expect(!got.value.object.contains("preferences"));
}

test "carryIn keeps the target's org-derived and per-account preferences" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.write("from", "{\"preferences\":{\"keepAwakeEnabled\":true,\"coworkHipaaRestricted\":true,\"bypassPermissionsGateByAccount\":{\"a\":true}}}");
    try f.write("to", "{\"preferences\":{\"keepAwakeEnabled\":false,\"orgWorkAcrossAppsDisabled\":true,\"bypassPermissionsGateByAccount\":{\"a\":false,\"b\":true}}}");

    const from = try f.dir("from");
    defer std.testing.allocator.free(from);
    const to = try f.dir("to");
    defer std.testing.allocator.free(to);
    try std.testing.expect(try carryIn(std.testing.allocator, std.testing.io, from, to));

    const got = try f.read("to");
    defer got.deinit();
    const prefs = got.value.object.get("preferences").?.object;
    try std.testing.expect(prefs.get("keepAwakeEnabled").?.bool);
    try std.testing.expect(!prefs.contains("coworkHipaaRestricted"));
    try std.testing.expect(prefs.get("orgWorkAcrossAppsDisabled").?.bool);
    const by_account = prefs.get("bypassPermissionsGateByAccount").?.object;
    try std.testing.expect(by_account.get("a").?.bool);
    try std.testing.expect(by_account.get("b").?.bool);
}
