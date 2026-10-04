//! envs.zig — copy Claude Code cloud environments from one profile to the others.
//!
//! A cloud environment (network allowlist, environment variables, setup script)
//! belongs to the account that made it, so a host allowed on one account is
//! still blocked on the others. `claudacity envs sync` makes every other profile hold
//! the source profile's environments: matched by name, created when missing,
//! updated when the config differs. Environments only the target has are left alone.
//! Observed Claude behavior this relies on: docs/claude-internals.md

const std = @import("std");
const display = @import("display.zig");
const http = @import("http.zig");
const json = @import("json.zig");
const oauth = @import("oauth.zig");
const paths = @import("paths.zig");
const profile = @import("profile.zig");
const sessions = @import("sessions.zig");

pub const API = "https://api.anthropic.com/v1/environment_providers";
const BETA = "ccr-byoc-2025-07-29";
const MAX_PAGES = 10;

pub const Env = struct {
    id: []const u8,
    name: []const u8,
    /// The environment's `config` object. The list leaves it null; `fetchConfig` fills it.
    config: std.json.Value = .null,
};

/// Parses one page of the environment list, keeping live cloud environments only.
/// All memory comes from `arena`.
pub fn parsePage(arena: std.mem.Allocator, body: []const u8, out: *std.ArrayList(Env)) !?[]const u8 {
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{}) catch return error.MalformedEnvironmentList;
    if (root != .object) return error.MalformedEnvironmentList;
    const data = root.object.get("environments") orelse return error.MalformedEnvironmentList;
    if (data != .array) return error.MalformedEnvironmentList;
    for (data.array.items) |e| {
        const id = json.stringField(e, "environment_id") orelse continue;
        const name = json.stringField(e, "name") orelse continue;
        if (!std.mem.eql(u8, json.stringField(e, "kind") orelse "", "anthropic_cloud")) continue;
        if (std.mem.eql(u8, json.stringField(e, "state") orelse "", "archived")) continue;
        try out.append(arena, .{ .id = id, .name = name, .config = e.object.get("config") orelse .null });
    }
    const has_more = if (root.object.get("has_more")) |h| h == .bool and h.bool else false;
    if (!has_more or data.array.items.len == 0) return null;
    return json.stringField(root, "last_id");
}

/// Deep equality where object key order does not matter.
pub fn jsonEqual(a: std.json.Value, b: std.json.Value) bool {
    return switch (a) {
        .null => b == .null,
        .bool => |x| b == .bool and b.bool == x,
        .integer => |x| switch (b) {
            .integer => |y| x == y,
            .float => |y| @as(f64, @floatFromInt(x)) == y,
            else => false,
        },
        .float => |x| switch (b) {
            .float => |y| x == y,
            .integer => |y| x == @as(f64, @floatFromInt(y)),
            else => false,
        },
        .number_string => |x| b == .number_string and std.mem.eql(u8, x, b.number_string),
        .string => |x| b == .string and std.mem.eql(u8, x, b.string),
        .array => |x| blk: {
            if (b != .array or b.array.items.len != x.items.len) break :blk false;
            for (x.items, b.array.items) |p, q| if (!jsonEqual(p, q)) break :blk false;
            break :blk true;
        },
        .object => |x| blk: {
            if (b != .object or b.object.count() != x.count()) break :blk false;
            var it = x.iterator();
            while (it.next()) |kv| {
                const other = b.object.get(kv.key_ptr.*) orelse break :blk false;
                if (!jsonEqual(kv.value_ptr.*, other)) break :blk false;
            }
            break :blk true;
        },
    };
}

pub const Action = union(enum) {
    create,
    /// The target's environment id.
    update: []const u8,
    unchanged,
};

pub const Step = struct {
    source: Env,
    action: Action,
};

/// What a target needs to hold the source's environments, one step per source environment.
/// A name the target holds twice is matched to its first environment.
pub fn plan(arena: std.mem.Allocator, source: []const Env, target: []const Env) ![]Step {
    const steps = try arena.alloc(Step, source.len);
    for (source, steps) |s, *step| {
        step.* = .{ .source = s, .action = .create };
        for (target) |t| {
            if (!std.mem.eql(u8, s.name, t.name)) continue;
            step.action = if (jsonEqual(s.config, t.config))
                .unchanged
            else
                .{ .update = t.id };
            break;
        }
    }
    return steps;
}

/// Names of the config keys whose values differ, for a report that never prints a value
/// (environment variables can hold secrets).
pub fn changedKeys(arena: std.mem.Allocator, source: std.json.Value, target: ?std.json.Value) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    if (source != .object) return out.toOwnedSlice(arena);
    var it = source.object.iterator();
    while (it.next()) |kv| {
        const same = if (target) |t| if (t == .object) if (t.object.get(kv.key_ptr.*)) |v| jsonEqual(kv.value_ptr.*, v) else false else false else false;
        if (same) continue;
        if (out.items.len > 0) try out.appendSlice(arena, ", ");
        try out.appendSlice(arena, kv.key_ptr.*);
    }
    return out.toOwnedSlice(arena);
}

/// The list carries no description and claude.ai's own dialogs send an empty one.
pub fn createBody(arena: std.mem.Allocator, e: Env) ![]u8 {
    return std.json.Stringify.valueAlloc(arena, .{
        .name = e.name,
        .kind = "anthropic_cloud",
        .description = "",
        .config = e.config,
    }, .{});
}

pub fn updateBody(arena: std.mem.Allocator, e: Env) ![]u8 {
    return std.json.Stringify.valueAlloc(arena, .{
        .name = e.name,
        .description = "",
        .config = e.config,
    }, .{});
}

/// One environment's URL: GET reads its config, POST replaces it.
pub fn envUrl(arena: std.mem.Allocator, env_id: []const u8) ![]u8 {
    return std.fmt.allocPrint(arena, "{s}/{s}", .{ API, env_id });
}

/// The `config` object of a single-environment response.
pub fn parseConfig(arena: std.mem.Allocator, body: []const u8) !std.json.Value {
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{}) catch return error.MalformedEnvironment;
    if (root != .object) return error.MalformedEnvironment;
    const config = root.object.get("config") orelse return error.MalformedEnvironment;
    if (config != .object) return error.MalformedEnvironment;
    return config;
}

/// A profile's API access: a fresh token and its organization.
const Account = struct {
    token: []const u8,
    org: []const u8,

    fn headers(a: Account, arena: std.mem.Allocator) ![]const http.Header {
        const auth = try std.fmt.allocPrint(arena, "Bearer {s}", .{a.token});
        return arena.dupe(http.Header, &.{
            .{ .name = "Authorization", .value = auth },
            .{ .name = "Content-Type", .value = "application/json" },
            .{ .name = "anthropic-beta", .value = BETA },
            .{ .name = "anthropic-version", .value = "2023-06-01" },
            .{ .name = "x-organization-uuid", .value = a.org },
        });
    }
};

const AccountError = error{ NeedsSignIn, NoLogin, NoAccount };

fn account(arena: std.mem.Allocator, io: std.Io, name: []const u8, active: bool) !Account {
    const h = try paths.home(arena);
    const p = try paths.profileJsonIn(arena, h, name);
    const rel = sessions.accountRel(arena, io, p) catch return error.NoAccount;
    const slash = std.mem.indexOfScalar(u8, rel, '/') orelse return error.NoAccount;
    const token = switch (try oauth.freshAccessToken(arena, io, name, active)) {
        .token => |t| t,
        .needs_sign_in => return error.NeedsSignIn,
        .missing => return error.NoLogin,
    };
    return .{ .token = token, .org = rel[slash + 1 ..] };
}

fn list(arena: std.mem.Allocator, io: std.Io, acct: Account) ![]Env {
    const hdrs = try acct.headers(arena);
    var out: std.ArrayList(Env) = .empty;
    var after: ?[]const u8 = null;
    var pages: usize = 0;
    while (pages < MAX_PAGES) : (pages += 1) {
        const url = if (after) |a|
            try std.fmt.allocPrint(arena, "{s}?limit=100&after_id={s}", .{ API, a })
        else
            try std.fmt.allocPrint(arena, "{s}?limit=100", .{API});
        const resp = try http.send(arena, io, .{ .url = url, .headers = hdrs });
        if (resp.status != 200) return error.EnvironmentListFailed;
        after = try parsePage(arena, resp.body, &out) orelse break;
    }
    for (out.items) |*e| {
        const resp = try http.send(arena, io, .{ .url = try envUrl(arena, e.id), .headers = hdrs });
        if (resp.status != 200) return error.EnvironmentReadFailed;
        e.config = try parseConfig(arena, resp.body);
    }
    return out.toOwnedSlice(arena);
}

fn apply(arena: std.mem.Allocator, io: std.Io, acct: Account, step: Step) !void {
    const req: http.Request = switch (step.action) {
        .unchanged => return,
        .create => .{
            .method = "POST",
            .url = API ++ "/cloud/create",
            .headers = try acct.headers(arena),
            .body = try createBody(arena, step.source),
        },
        .update => |id| .{
            .method = "POST",
            .url = try envUrl(arena, id),
            .headers = try acct.headers(arena),
            .body = try updateBody(arena, step.source),
        },
    };
    const resp = try http.send(arena, io, req);
    if (resp.status != 200 and resp.status != 201) {
        if (!@import("builtin").is_test) display.print("      HTTP {d}: {s}\n", .{ resp.status, resp.body[0..@min(resp.body.len, 300)] });
        return error.EnvironmentWriteFailed;
    }
}

pub const Options = struct {
    /// Profile to copy from; the active profile when null.
    from: ?[]const u8 = null,
    dry_run: bool = false,
};

fn accountProblem(e: anyerror) []const u8 {
    return switch (e) {
        error.NeedsSignIn => "needs signing in again",
        error.NoLogin => "no saved login",
        error.NoAccount => "no account in its .claude.<profile>.json",
        else => "environments could not be read",
    };
}

pub fn cmdSync(gpa: std.mem.Allocator, io: std.Io, opts: Options) !void {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const names = try profile.list(arena);
    const current = try profile.current(arena);
    const source_name = opts.from orelse current orelse {
        display.err("No active profile; name one with --from <profile>.");
        return error.NoSource;
    };
    const isActive = struct {
        fn f(cur: ?[]const u8, n: []const u8) bool {
            return if (cur) |c| std.mem.eql(u8, c, n) else false;
        }
    }.f;

    var known = false;
    for (names) |n| known = known or std.mem.eql(u8, n, source_name);
    if (!known) {
        display.print("❌  Unknown profile: {s}\n", .{source_name});
        return error.UnknownProfile;
    }

    const src_acct = account(arena, io, source_name, isActive(current, source_name)) catch |e| {
        display.print("❌  {s}: {s}\n", .{ source_name, accountProblem(e) });
        return e;
    };
    const source = list(arena, io, src_acct) catch |e| {
        display.print("❌  {s}: {s}\n", .{ source_name, accountProblem(e) });
        return e;
    };
    display.print("\nSource {s}: {d} cloud environment(s)\n", .{ source_name, source.len });
    for (source) |e| display.print("  {s}\n", .{e.name});

    var failures: usize = 0;
    for (names) |name| {
        if (std.mem.eql(u8, name, source_name)) continue;
        display.print("\n{s}\n", .{name});
        const acct = account(arena, io, name, isActive(current, name)) catch |e| {
            display.print("  skipped: {s}\n", .{accountProblem(e)});
            failures += 1;
            continue;
        };
        if (std.mem.eql(u8, acct.org, src_acct.org)) {
            display.print("  skipped: same organization as {s}\n", .{source_name});
            continue;
        }
        const target = list(arena, io, acct) catch |e| {
            display.print("  skipped: {s}\n", .{accountProblem(e)});
            failures += 1;
            continue;
        };
        for (try plan(arena, source, target)) |step| {
            const existing: ?std.json.Value = switch (step.action) {
                .update => |id| for (target) |t| {
                    if (std.mem.eql(u8, t.id, id)) break t.config;
                } else null,
                else => null,
            };
            const verb: []const u8 = switch (step.action) {
                .create => if (opts.dry_run) "would create" else "create",
                .update => if (opts.dry_run) "would update" else "update",
                .unchanged => "up to date",
            };
            switch (step.action) {
                .unchanged, .create => display.print("  {s:<13} {s}\n", .{ verb, step.source.name }),
                .update => display.print("  {s:<13} {s}  ({s})\n", .{ verb, step.source.name, try changedKeys(arena, step.source.config, existing) }),
            }
            if (opts.dry_run) continue;
            apply(arena, io, acct, step) catch {
                display.print("      failed\n", .{});
                failures += 1;
            };
        }
    }
    display.print("\n", .{});
    if (failures > 0) return error.SyncIncomplete;
}

// ── Tests ────────────────────────────────────────────────────────────────────

const PAGE =
    \\{"environments":[
    \\ {"environment_id":"env_1","name":"Default","kind":"anthropic_cloud","state":"active","config":null,"bridge_info":null},
    \\ {"environment_id":"env_2","name":"Mac:projects:904d","kind":"bridge","state":"active","config":null,"bridge_info":{}},
    \\ {"environment_id":"env_3","name":"Old","kind":"anthropic_cloud","state":"archived","config":null}
    \\],"has_more":true,"last_id":"env_3"}
;

test "parsePage keeps live cloud environments and returns the next cursor" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var out: std.ArrayList(Env) = .empty;
    const next = try parsePage(arena, PAGE, &out);
    try std.testing.expectEqualStrings("env_3", next.?);
    try std.testing.expectEqual(@as(usize, 1), out.items.len);
    try std.testing.expectEqualStrings("Default", out.items[0].name);
    try std.testing.expect(try parsePage(arena, "{\"environments\":[],\"has_more\":false}", &out) == null);
    try std.testing.expectError(error.MalformedEnvironmentList, parsePage(arena, "[]", &out));
}

fn parseValue(arena: std.mem.Allocator, s: []const u8) !std.json.Value {
    return std.json.parseFromSliceLeaky(std.json.Value, arena, s, .{});
}

test "jsonEqual ignores key order but not values" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expect(jsonEqual(try parseValue(arena, "{\"a\":[1,{\"b\":null}],\"c\":\"x\"}"), try parseValue(arena, "{\"c\":\"x\",\"a\":[1,{\"b\":null}]}")));
    try std.testing.expect(!jsonEqual(try parseValue(arena, "{\"a\":[1,2]}"), try parseValue(arena, "{\"a\":[2,1]}")));
    try std.testing.expect(!jsonEqual(try parseValue(arena, "{\"a\":1}"), try parseValue(arena, "{\"a\":1,\"b\":1}")));
}

test "plan creates missing environments, updates changed ones by name, and skips equal ones" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const hosts = try parseValue(arena, "{\"network_config\":{\"allowed_hosts\":[\"pkg-containers.githubusercontent.com\"]}}");
    const none = try parseValue(arena, "{\"network_config\":{\"allowed_hosts\":[]}}");
    const source = [_]Env{
        .{ .id = "s1", .name = "Default", .config = hosts },
        .{ .id = "s2", .name = "Same", .config = none },
        .{ .id = "s3", .name = "New", .config = none },
    };
    const target = [_]Env{
        .{ .id = "t1", .name = "Default", .config = none },
        .{ .id = "t2", .name = "Same", .config = none },
        .{ .id = "t9", .name = "Theirs", .config = none },
    };
    const steps = try plan(arena, &source, &target);
    try std.testing.expectEqualStrings("t1", steps[0].action.update);
    try std.testing.expect(steps[1].action == .unchanged);
    try std.testing.expect(steps[2].action == .create);
    try std.testing.expectEqualStrings("network_config", try changedKeys(arena, hosts, none));
    try std.testing.expectEqualStrings("network_config", try changedKeys(arena, hosts, null));
}

test "request bodies carry the source config, and a single environment parses to its config" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const e: Env = .{ .id = "s1", .name = "Default", .config = try parseValue(arena, "{\"cwd\":\"/home/user\"}") };
    try std.testing.expectEqualStrings(
        "{\"name\":\"Default\",\"kind\":\"anthropic_cloud\",\"description\":\"\",\"config\":{\"cwd\":\"/home/user\"}}",
        try createBody(arena, e),
    );
    try std.testing.expectEqualStrings("{\"name\":\"Default\",\"description\":\"\",\"config\":{\"cwd\":\"/home/user\"}}", try updateBody(arena, e));
    try std.testing.expectEqualStrings("https://api.anthropic.com/v1/environment_providers/env_9", try envUrl(arena, "env_9"));
    const config = try parseConfig(arena,
        \\{"config":{"environment_type":"anthropic","network_config":{"allowed_hosts":["pkg-containers.githubusercontent.com"],"allow_default_hosts":true}}}
    );
    try std.testing.expect(config.object.get("network_config") != null);
    try std.testing.expectError(error.MalformedEnvironment, parseConfig(arena, "{\"config\":null}"));
}
