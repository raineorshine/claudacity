//! accounts.zig — which account each profile's Claude Code login belongs to.
//!
//! `claude auth login` rewrites `oauthAccount` in the active profile's JSON to
//! whichever account the browser authorized, so that JSON only says who the
//! live login is, never who the profile is meant to be. claudacity pins each
//! profile's account here when the user saves it, and checks logins against it.
//!
//! `~/Library/Application Support/claudacity/accounts.json`: {"<profile>": "<email>"}.

const std = @import("std");

pub fn pathIn(gpa: std.mem.Allocator, base: []const u8) ![]u8 {
    return std.fs.path.join(gpa, &.{ base, "Library", "Application Support", "claudacity", "accounts.json" });
}

/// Same account, ignoring case: claude.ai reports the email as typed at sign-up.
pub fn same(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

/// The email pinned for `name` in `json`, or null.
pub fn pinnedIn(gpa: std.mem.Allocator, json: []const u8, name: []const u8) ?[]u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, json, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const v = parsed.value.object.get(name) orelse return null;
    if (v != .string) return null;
    return gpa.dupe(u8, v.string) catch null;
}

/// `json` with `name` pinned to `email`; other profiles keep theirs.
pub fn withPin(gpa: std.mem.Allocator, json: ?[]const u8, name: []const u8, email: []const u8) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var map: std.json.ObjectMap = .empty;
    if (json) |j| {
        if (std.json.parseFromSliceLeaky(std.json.Value, a, j, .{})) |v| {
            if (v == .object) map = v.object;
        } else |_| {}
    }
    try map.put(a, name, .{ .string = email });
    return std.json.Stringify.valueAlloc(gpa, std.json.Value{ .object = map }, .{ .whitespace = .indent_2 });
}

fn readAll(gpa: std.mem.Allocator, path: []const u8) ?[]u8 {
    const path_z = gpa.dupeZ(u8, path) catch return null;
    defer gpa.free(path_z);
    const fd = std.c.open(path_z, .{}, @as(std.c.mode_t, 0));
    if (fd < 0) return null;
    defer _ = std.c.close(fd);
    var buf: [256 * 1024]u8 = undefined;
    var total: usize = 0;
    while (total < buf.len) {
        const n = std.c.read(fd, buf[total..].ptr, buf.len - total);
        if (n <= 0) break;
        total += @intCast(n);
    }
    return gpa.dupe(u8, buf[0..total]) catch null;
}

/// The account pinned for `name` under home `base`, or null.
pub fn pinned(gpa: std.mem.Allocator, base: []const u8, name: []const u8) ?[]u8 {
    const path = pathIn(gpa, base) catch return null;
    defer gpa.free(path);
    const json = readAll(gpa, path) orelse return null;
    defer gpa.free(json);
    return pinnedIn(gpa, json, name);
}

/// Pins `name` to `email` under home `base`.
pub fn pin(gpa: std.mem.Allocator, base: []const u8, name: []const u8, email: []const u8) !void {
    const path = try pathIn(gpa, base);
    defer gpa.free(path);
    const old = readAll(gpa, path);
    defer if (old) |o| gpa.free(o);
    const json = try withPin(gpa, old, name, email);
    defer gpa.free(json);

    const dir = std.fs.path.dirname(path).?;
    try mkdirAll(gpa, dir);
    const tmp = try std.fmt.allocPrintSentinel(gpa, "{s}.tmp", .{path}, 0);
    defer gpa.free(tmp);
    const fd = std.c.open(tmp, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o600));
    if (fd < 0) return error.CreateFileFailed;
    const written = std.c.write(fd, json.ptr, json.len);
    _ = std.c.close(fd);
    if (written != json.len) return error.WriteFailed;
    const path_z = try gpa.dupeZ(u8, path);
    defer gpa.free(path_z);
    if (std.c.rename(tmp, path_z) != 0) return error.RenameFailed;
}

fn mkdirAll(gpa: std.mem.Allocator, dir: []const u8) !void {
    var i: usize = 1;
    while (i <= dir.len) : (i += 1) {
        if (i != dir.len and dir[i] != '/') continue;
        const part = try gpa.dupeZ(u8, dir[0..i]);
        defer gpa.free(part);
        _ = std.c.mkdir(part, 0o755);
    }
}

test "pinnedIn reads one profile's account" {
    const gpa = std.testing.allocator;
    const got = pinnedIn(gpa, "{\"work\":\"me@work.com\",\"home\":\"me@home.com\"}", "home").?;
    defer gpa.free(got);
    try std.testing.expectEqualStrings("me@home.com", got);
    try std.testing.expect(pinnedIn(gpa, "{\"work\":\"me@work.com\"}", "home") == null);
    try std.testing.expect(pinnedIn(gpa, "garbage", "home") == null);
}

test "withPin replaces one profile and keeps the rest" {
    const gpa = std.testing.allocator;
    const json = try withPin(gpa, "{\"work\":\"me@work.com\",\"home\":\"old@home.com\"}", "home", "me@home.com");
    defer gpa.free(json);
    const home = pinnedIn(gpa, json, "home").?;
    defer gpa.free(home);
    const work = pinnedIn(gpa, json, "work").?;
    defer gpa.free(work);
    try std.testing.expectEqualStrings("me@home.com", home);
    try std.testing.expectEqualStrings("me@work.com", work);

    const fresh = try withPin(gpa, null, "home", "me@home.com");
    defer gpa.free(fresh);
    const got = pinnedIn(gpa, fresh, "home").?;
    defer gpa.free(got);
    try std.testing.expectEqualStrings("me@home.com", got);
}

test "pin writes a file pinned reads back" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(std.testing.io, &buf);
    const base = buf[0..n];
    try std.testing.expect(pinned(gpa, base, "home") == null);
    try pin(gpa, base, "home", "me@home.com");
    try pin(gpa, base, "work", "me@work.com");
    const got = pinned(gpa, base, "home").?;
    defer gpa.free(got);
    try std.testing.expectEqualStrings("me@home.com", got);
    try std.testing.expect(same("Me@Home.com", got));
}
