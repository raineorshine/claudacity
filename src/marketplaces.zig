//! marketplaces.zig — re-sync an account's claude.ai plugin marketplaces.
//!
//! claude.ai never re-syncs a personal marketplace when its repo changes, and
//! cloud sessions (and Desktop's `<name>@synced` plugins) load the claude.ai
//! copy. A switch therefore syncs the marketplaces of the account it lands on.
//! The routes take Desktop's claude.ai session cookie; OAuth tokens get 403
//! (docs/claude-internals.md, Plugin marketplaces).

const std = @import("std");
const builtin = @import("builtin");
const desktop = @import("desktop.zig");
const display = @import("display.zig");
const http = @import("http.zig");
const paths = @import("paths.zig");
const profile = @import("profile.zig");
const sessions = @import("sessions.zig");

const BASE = "https://claude.ai/api/organizations/";
/// A sync of a large repo took 17s on claude.ai's side.
const SYNC_TIMEOUT_S = 60;

pub const Marketplace = struct {
    id: []const u8,
    name: []const u8,
    status: ?[]const u8 = null,
    sha: ?[]const u8 = null,
};

fn str(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

fn record(v: std.json.Value) ?Marketplace {
    if (v != .object) return null;
    return .{
        .id = str(v.object, "id") orelse return null,
        .name = str(v.object, "name") orelse return null,
        .status = str(v.object, "sync_status"),
        .sha = str(v.object, "last_synced_sha"),
    };
}

/// The marketplaces in a `list-account-marketplaces` response.
pub fn parseList(arena: std.mem.Allocator, body: []const u8) ![]Marketplace {
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{}) catch return error.MalformedList;
    if (root != .object) return error.MalformedList;
    const list = root.object.get("marketplaces") orelse return error.MalformedList;
    if (list != .array) return error.MalformedList;
    var out: std.ArrayList(Marketplace) = .empty;
    for (list.array.items) |item| if (record(item)) |m| try out.append(arena, m);
    return out.toOwnedSlice(arena);
}

/// The marketplace record an `account-sync` call answers with.
pub fn parseSynced(arena: std.mem.Allocator, body: []const u8) !Marketplace {
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{}) catch return error.MalformedRecord;
    return record(root) orelse error.MalformedRecord;
}

pub const Outcome = struct {
    name: []const u8,
    /// The synced commit, or why the marketplace did not sync.
    result: union(enum) { synced: ?[]const u8, failed: []const u8 },
};

pub const Report = union(enum) {
    outcomes: []Outcome,
    /// Why nothing was synced.
    skipped: []const u8,
};

const Credentials = struct {
    cookie: []const u8,
    org: []const u8,

    fn headers(c: Credentials) [3]http.Header {
        return .{
            .{ .name = "Cookie", .value = c.cookie },
            .{ .name = "Accept", .value = "application/json" },
            .{ .name = "Content-Type", .value = "application/json" },
        };
    }
};

/// claude.ai's web app treats these sync states as still running and polls.
pub fn isPending(status: ?[]const u8) bool {
    const s = status orelse return false;
    return std.mem.eql(u8, s, "in_progress") or std.mem.eql(u8, s, "unspecified");
}

const POLL_INTERVAL_S = 3;
const POLL_ATTEMPTS = 10;

const Task = struct {
    creds: Credentials,
    market: Marketplace,
    outcome: Outcome = undefined,
    arena: std.heap.ArenaAllocator,

    fn request(t: *Task, io: std.Io, method: []const u8, route: []const u8) !Marketplace {
        const a = t.arena.allocator();
        const url = try std.fmt.allocPrint(a, "{s}{s}/marketplaces/{s}/{s}", .{ BASE, t.creds.org, t.market.id, route });
        const hdrs = t.creds.headers();
        const post = std.mem.eql(u8, method, "POST");
        const resp = try http.sendDirect(a, io, .{ .method = method, .url = url, .headers = &hdrs, .body = if (post) "{}" else null, .timeout_s = SYNC_TIMEOUT_S });
        if (resp.status == 429) return error.RateLimited;
        if (resp.status != 200) {
            t.outcome.result = .{ .failed = try std.fmt.allocPrint(a, "HTTP {d}", .{resp.status}) };
            return error.HttpStatus;
        }
        return parseSynced(a, resp.body);
    }

    fn run(t: *Task, io: std.Io) void {
        t.outcome = .{ .name = t.market.name, .result = .{ .failed = "unknown" } };
        const m = t.sync(io) catch |err| {
            if (err != error.HttpStatus) t.outcome.result = .{ .failed = @errorName(err) };
            return;
        };
        const status = m.status orelse "success";
        t.outcome.result = if (std.mem.eql(u8, status, "success"))
            .{ .synced = m.sha }
        else if (isPending(status))
            .{ .failed = "still syncing" }
        else
            .{ .failed = status };
    }

    /// Kicks a sync, then follows it to a settled state the way claude.ai's
    /// "Check for updates" does. A 429 means a sync ran recently; its state is read instead.
    fn sync(t: *Task, io: std.Io) !Marketplace {
        var m = t.request(io, "POST", "account-sync") catch |err| switch (err) {
            error.RateLimited => try t.request(io, "GET", "account-get"),
            else => return err,
        };
        var attempts: usize = 0;
        while (isPending(m.status) and attempts < POLL_ATTEMPTS) : (attempts += 1) {
            try io.sleep(std.Io.Duration.fromSeconds(POLL_INTERVAL_S), .awake);
            m = try t.request(io, "GET", "account-get");
        }
        return m;
    }
};

/// Syncs every claude.ai marketplace of the account whose Desktop data is live
/// under `h`, in the organization of profile `name`. Marketplaces sync
/// concurrently. Everything is allocated in `arena`.
pub fn syncIn(arena: std.mem.Allocator, io: std.Io, h: []const u8, name: []const u8) !Report {
    const p_json = try paths.profileJsonIn(arena, h, name);
    const rel = sessions.accountRel(arena, io, p_json) catch return .{ .skipped = "the profile has no account in its .claude.<profile>.json" };
    const slash = std.mem.indexOfScalar(u8, rel, '/') orelse return .{ .skipped = "the profile has no organization" };
    const key = desktop.sessionKeyIn(arena, io, h) catch return .{ .skipped = "Claude Desktop holds no claude.ai sign-in" };
    const creds: Credentials = .{
        .cookie = try std.fmt.allocPrint(arena, "sessionKey={s}", .{key}),
        .org = rel[slash + 1 ..],
    };

    const list_url = try std.fmt.allocPrint(arena, "{s}{s}/marketplaces/list-account-marketplaces", .{ BASE, creds.org });
    const hdrs = creds.headers();
    const resp = http.sendDirect(arena, io, .{ .url = list_url, .headers = &hdrs }) catch |err|
        return .{ .skipped = try std.fmt.allocPrint(arena, "listing failed ({s})", .{@errorName(err)}) };
    if (resp.status == 401 or resp.status == 403)
        return .{ .skipped = try std.fmt.allocPrint(arena, "claude.ai refused Desktop's sign-in (HTTP {d}); sign in to Desktop again", .{resp.status}) };
    if (resp.status != 200)
        return .{ .skipped = try std.fmt.allocPrint(arena, "listing answered HTTP {d}", .{resp.status}) };
    const markets = parseList(arena, resp.body) catch return .{ .skipped = "claude.ai's marketplace list had an unexpected shape" };

    const tasks = try arena.alloc(Task, markets.len);
    var group: std.Io.Group = .init;
    for (markets, tasks) |m, *t| {
        t.* = .{ .creds = creds, .market = m, .arena = .init(std.heap.smp_allocator) };
        group.async(io, Task.run, .{ t, io });
    }
    group.await(io) catch {};

    const outcomes = try arena.alloc(Outcome, tasks.len);
    for (tasks, outcomes) |*t, *o| {
        o.* = .{ .name = t.outcome.name, .result = switch (t.outcome.result) {
            .synced => |sha| .{ .synced = if (sha) |s| try arena.dupe(u8, s) else null },
            .failed => |why| .{ .failed = try arena.dupe(u8, why) },
        } };
        t.arena.deinit();
    }
    return .{ .outcomes = outcomes };
}

/// One line for the synced marketplaces, one warning per failure.
pub fn printReport(name: []const u8, report: Report, quiet_when_empty: bool) void {
    if (builtin.is_test) return;
    switch (report) {
        .skipped => |why| display.print("⚠️  claude.ai marketplaces not synced for '{s}': {s}\n", .{ name, why }),
        .outcomes => |outcomes| {
            if (outcomes.len == 0) {
                if (!quiet_when_empty) display.print("No claude.ai marketplaces on '{s}'\n", .{name});
                return;
            }
            var synced: usize = 0;
            for (outcomes) |o| if (o.result == .synced) {
                synced += 1;
            };
            if (synced > 0) {
                display.print("Synced claude.ai marketplaces:", .{});
                var first = true;
                for (outcomes) |o| switch (o.result) {
                    .synced => |sha| {
                        display.print("{s} {s}", .{ if (first) "" else ",", o.name });
                        if (sha) |s| display.print(" @ {s}", .{s[0..@min(s.len, 7)]});
                        first = false;
                    },
                    .failed => {},
                };
                display.print("\n", .{});
            }
            for (outcomes) |o| switch (o.result) {
                .failed => |why| display.print("⚠️  claude.ai marketplace '{s}' did not sync: {s}\n", .{ o.name, why }),
                .synced => {},
            };
        },
    }
}

/// Syncs after a switch to `name`; a failure only warns.
pub fn syncAfterSwitch(gpa: std.mem.Allocator, io: std.Io, h: []const u8, name: []const u8) void {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const report = syncIn(arena_state.allocator(), io, h, name) catch |err| {
        if (!builtin.is_test) display.print("⚠️  claude.ai marketplaces not synced for '{s}': {s}\n", .{ name, @errorName(err) });
        return;
    };
    printReport(name, report, true);
}

/// `claudacity marketplaces sync`: syncs the active profile's marketplaces.
pub fn cmdSync(gpa: std.mem.Allocator, io: std.Io) !void {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const name = try profile.current(arena) orelse {
        display.err("No active profile.");
        return error.NoActiveProfile;
    };
    const report = try syncIn(arena, io, try paths.home(arena), name);
    printReport(name, report, false);
    switch (report) {
        .skipped => return error.MarketplaceSyncFailed,
        .outcomes => |outcomes| for (outcomes) |o| if (o.result == .failed) return error.MarketplaceSyncFailed,
    }
}

test "parseList reads ids, names and sync state" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const list = try parseList(arena_state.allocator(),
        \\{"marketplaces":[
        \\  {"id":"marketplace_01A","name":"blunt","source":"github","sync_status":"success","last_synced_sha":"ee0bd1009e54"},
        \\  {"id":"marketplace_01B","name":"fresh","sync_status":null,"last_synced_sha":null},
        \\  {"name":"no-id"}
        \\]}
    );
    try std.testing.expectEqual(@as(usize, 2), list.len);
    try std.testing.expectEqualStrings("marketplace_01A", list[0].id);
    try std.testing.expectEqualStrings("blunt", list[0].name);
    try std.testing.expectEqualStrings("success", list[0].status.?);
    try std.testing.expectEqualStrings("ee0bd1009e54", list[0].sha.?);
    try std.testing.expect(list[1].sha == null);
}

test "parseList rejects a body without a marketplace list" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    try std.testing.expectError(error.MalformedList, parseList(arena_state.allocator(), "<!DOCTYPE html>"));
    try std.testing.expectError(error.MalformedList, parseList(arena_state.allocator(), "{\"error\":{}}"));
}

test "isPending matches claude.ai's transient sync states" {
    try std.testing.expect(isPending("in_progress"));
    try std.testing.expect(isPending("unspecified"));
    try std.testing.expect(!isPending("success"));
    try std.testing.expect(!isPending("failed_auth"));
    try std.testing.expect(!isPending(null));
}

test "parseSynced reads the record account-sync answers with" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const m = try parseSynced(arena_state.allocator(), "{\"id\":\"marketplace_01A\",\"name\":\"blunt\",\"sync_status\":\"failed\",\"last_synced_sha\":\"abc\"}");
    try std.testing.expectEqualStrings("failed", m.status.?);
}

test "syncIn skips a profile without an account" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &buf);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".claude.p.json", .data = "{}" });
    const report = try syncIn(arena_state.allocator(), std.testing.io, buf[0..len], "p");
    try std.testing.expect(report == .skipped);
}
