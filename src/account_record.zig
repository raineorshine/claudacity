//! account_record.zig — keeps each profile's `oauthAccount` on its own account.
//!
//! A `claude` process left running after a switch still holds the outgoing
//! account, and when it refreshes that account's profile it writes the
//! `oauthAccount` through `~/.claude.json`, now a link to another profile's JSON.
//! That profile then names the wrong account in `whoami` and the picker, and its
//! Desktop session records are looked up under the wrong account's ids.
//!
//! Every switch checks both profiles against their pins (`accounts.json`): a record
//! that matches is kept as the profile's last good copy in
//! `~/Library/Application Support/claudacity/oauth-accounts.json`, and one that
//! names another account is put back from that copy, or else from the newest of
//! Claude Code's own backups (`~/.claude.<profile>/backups/`) that names the pin.

const std = @import("std");
const accounts = @import("accounts.zig");
const paths = @import("paths.zig");

pub const Outcome = union(enum) {
    /// No pin, or no readable JSON or `oauthAccount`: nothing to check against.
    unchecked,
    ok,
    /// Put back; holds the email the record had named (owned).
    repaired: []u8,
    /// Wrong, with no good copy to put back; holds the email it names (owned).
    wrong: []u8,

    pub fn deinit(self: Outcome, gpa: std.mem.Allocator) void {
        switch (self) {
            .repaired, .wrong => |e| gpa.free(e),
            else => {},
        }
    }
};

pub fn stashPathIn(gpa: std.mem.Allocator, base: []const u8) ![]u8 {
    return std.fs.path.join(gpa, &.{ base, "Library", "Application Support", "claudacity", "oauth-accounts.json" });
}

/// Checks `name`'s `oauthAccount` against its pin, keeping a good one and
/// putting a wrong one back where a good copy exists.
pub fn checkIn(gpa: std.mem.Allocator, io: std.Io, base: []const u8, name: []const u8) !Outcome {
    const pin = accounts.pinned(gpa, base, name) orelse return .unchecked;
    defer gpa.free(pin);

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const json_path = try paths.profileJsonIn(arena, base, name);
    var root = readJson(arena, io, json_path) orelse return .unchecked;
    if (root != .object) return .unchecked;
    const current = root.object.get("oauthAccount") orelse return .unchecked;
    const current_email = emailOf(current) orelse return .unchecked;

    const stash_path = try stashPathIn(arena, base);
    var stash = readJson(arena, io, stash_path) orelse std.json.Value{ .object = .empty };
    if (stash != .object) stash = .{ .object = .empty };

    if (accounts.same(current_email, pin)) {
        const kept = stash.object.get(name);
        if (kept == null or !sameRecord(kept.?, current)) {
            try stash.object.put(arena, name, current);
            try writeAtomic(gpa, io, stash_path, stash, 0o600);
        }
        return .ok;
    }

    const good = goodCopy(stash, name, pin) orelse
        try newestBackup(arena, io, base, name, pin) orelse
        return .{ .wrong = try gpa.dupe(u8, current_email) };
    try root.object.put(arena, "oauthAccount", good);
    try writeAtomic(gpa, io, json_path, root, 0o600);
    return .{ .repaired = try gpa.dupe(u8, current_email) };
}

fn goodCopy(stash: std.json.Value, name: []const u8, pin: []const u8) ?std.json.Value {
    const kept = stash.object.get(name) orelse return null;
    const email = emailOf(kept) orelse return null;
    return if (accounts.same(email, pin)) kept else null;
}

/// The `oauthAccount` of the newest Claude Code backup in the profile's own
/// directory that names `pin`, or null.
fn newestBackup(arena: std.mem.Allocator, io: std.Io, base: []const u8, name: []const u8, pin: []const u8) !?std.json.Value {
    const dir_path = try std.fs.path.join(arena, &.{ try paths.profileDirIn(arena, base, name), "backups" });
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return null;
    defer dir.close(io);

    const prefix = ".claude.json.backup.";
    var best: ?std.json.Value = null;
    var best_stamp: u64 = 0;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.startsWith(u8, entry.name, prefix)) continue;
        const stamp = std.fmt.parseInt(u64, entry.name[prefix.len..], 10) catch continue;
        if (best != null and stamp <= best_stamp) continue;
        const file = try std.fs.path.join(arena, &.{ dir_path, entry.name });
        const backup = readJson(arena, io, file) orelse continue;
        if (backup != .object) continue;
        const record = backup.object.get("oauthAccount") orelse continue;
        const email = emailOf(record) orelse continue;
        if (!accounts.same(email, pin)) continue;
        best = record;
        best_stamp = stamp;
    }
    return best;
}

fn emailOf(record: std.json.Value) ?[]const u8 {
    if (record != .object) return null;
    const v = record.object.get("emailAddress") orelse return null;
    return if (v == .string) v.string else null;
}

fn sameRecord(a: std.json.Value, b: std.json.Value) bool {
    var buf_a: [64 * 1024]u8 = undefined;
    var buf_b: [64 * 1024]u8 = undefined;
    var wa: std.Io.Writer = .fixed(&buf_a);
    var wb: std.Io.Writer = .fixed(&buf_b);
    std.json.Stringify.value(a, .{}, &wa) catch return false;
    std.json.Stringify.value(b, .{}, &wb) catch return false;
    return std.mem.eql(u8, wa.buffered(), wb.buffered());
}

/// Parsed with numbers left as written, so a rewrite changes nothing but what it sets.
fn readJson(arena: std.mem.Allocator, io: std.Io, path: []const u8) ?std.json.Value {
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(64 * 1024 * 1024)) catch return null;
    return std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{ .parse_numbers = false }) catch null;
}

/// Written beside `path` and renamed over it, so a live session never reads half a file.
fn writeAtomic(gpa: std.mem.Allocator, io: std.Io, path: []const u8, value: std.json.Value, mode: std.posix.mode_t) !void {
    const text = try std.json.Stringify.valueAlloc(gpa, value, .{ .whitespace = .indent_2 });
    defer gpa.free(text);
    const dir = std.fs.path.dirname(path) orelse return error.BadPath;
    try std.Io.Dir.cwd().createDirPath(io, dir);
    const tmp = try std.fmt.allocPrint(gpa, "{s}.claudacity-tmp", .{path});
    defer gpa.free(tmp);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = tmp, .data = text, .flags = .{ .permissions = .fromMode(mode) } });
    const tmp_z = try gpa.dupeZ(u8, tmp);
    defer gpa.free(tmp_z);
    const path_z = try gpa.dupeZ(u8, path);
    defer gpa.free(path_z);
    if (std.c.rename(tmp_z, path_z) != 0) return error.RenameFailed;
}

// ---- tests ----

const Fixture = struct {
    tmp: std.testing.TmpDir,
    base: []u8,

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

    fn write(f: Fixture, rel: []const u8, data: []const u8) !void {
        const gpa = std.testing.allocator;
        const path = try std.fs.path.join(gpa, &.{ f.base, rel });
        defer gpa.free(path);
        try std.Io.Dir.cwd().createDirPath(std.testing.io, std.fs.path.dirname(path).?);
        try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = data });
    }

    fn email(f: Fixture, name: []const u8) !?[]u8 {
        const gpa = std.testing.allocator;
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const path = try paths.profileJsonIn(arena.allocator(), f.base, name);
        const root = readJson(arena.allocator(), std.testing.io, path) orelse return null;
        const e = emailOf(root.object.get("oauthAccount").?) orelse return null;
        return try gpa.dupe(u8, e);
    }
};

test "a matching record is kept and later puts back a wrong one" {
    const gpa = std.testing.allocator;
    var f = try Fixture.init();
    defer f.deinit();
    try accounts.pin(gpa, f.base, "dev", "dev@x.cc");
    try f.write(".claude.dev.json", "{\"n\":1.50,\"oauthAccount\":{\"emailAddress\":\"Dev@x.cc\",\"accountUuid\":\"d\"}}");

    const first = try checkIn(gpa, std.testing.io, f.base, "dev");
    defer first.deinit(gpa);
    try std.testing.expect(first == .ok);

    try f.write(".claude.dev.json", "{\"n\":1.50,\"oauthAccount\":{\"emailAddress\":\"other@y.com\",\"accountUuid\":\"o\"}}");
    const second = try checkIn(gpa, std.testing.io, f.base, "dev");
    defer second.deinit(gpa);
    try std.testing.expectEqualStrings("other@y.com", second.repaired);

    const now = (try f.email("dev")).?;
    defer gpa.free(now);
    try std.testing.expectEqualStrings("Dev@x.cc", now);
    // Other keys survive as written.
    const path = try paths.profileJsonIn(gpa, f.base, "dev");
    defer gpa.free(path);
    const text = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, gpa, .limited(1 << 20));
    defer gpa.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "1.50") != null);
}

test "with no kept copy the newest matching backup puts it back" {
    const gpa = std.testing.allocator;
    var f = try Fixture.init();
    defer f.deinit();
    try accounts.pin(gpa, f.base, "dev", "dev@x.cc");
    try f.write(".claude.dev.json", "{\"oauthAccount\":{\"emailAddress\":\"other@y.com\"}}");
    try f.write(".claude.dev/backups/.claude.json.backup.100", "{\"oauthAccount\":{\"emailAddress\":\"dev@x.cc\",\"accountUuid\":\"old\"}}");
    try f.write(".claude.dev/backups/.claude.json.backup.200", "{\"oauthAccount\":{\"emailAddress\":\"dev@x.cc\",\"accountUuid\":\"new\"}}");
    try f.write(".claude.dev/backups/.claude.json.backup.300", "{\"oauthAccount\":{\"emailAddress\":\"other@y.com\"}}");

    const got = try checkIn(gpa, std.testing.io, f.base, "dev");
    defer got.deinit(gpa);
    try std.testing.expect(got == .repaired);

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const path = try paths.profileJsonIn(arena.allocator(), f.base, "dev");
    const root = readJson(arena.allocator(), std.testing.io, path).?;
    try std.testing.expectEqualStrings("new", root.object.get("oauthAccount").?.object.get("accountUuid").?.string);
}

test "a wrong record with no good copy is reported and left alone" {
    const gpa = std.testing.allocator;
    var f = try Fixture.init();
    defer f.deinit();
    try accounts.pin(gpa, f.base, "dev", "dev@x.cc");
    try f.write(".claude.dev.json", "{\"oauthAccount\":{\"emailAddress\":\"other@y.com\"}}");

    const got = try checkIn(gpa, std.testing.io, f.base, "dev");
    defer got.deinit(gpa);
    try std.testing.expectEqualStrings("other@y.com", got.wrong);
    const now = (try f.email("dev")).?;
    defer gpa.free(now);
    try std.testing.expectEqualStrings("other@y.com", now);
}

test "an unpinned profile is not checked" {
    const gpa = std.testing.allocator;
    var f = try Fixture.init();
    defer f.deinit();
    try f.write(".claude.dev.json", "{\"oauthAccount\":{\"emailAddress\":\"other@y.com\"}}");
    const got = try checkIn(gpa, std.testing.io, f.base, "dev");
    try std.testing.expect(got == .unchecked);
}
