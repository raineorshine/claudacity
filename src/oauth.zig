//! oauth.zig — Claude Code OAuth logins saved in the Keychain.
//!
//! Saved logins expire. A refresh rotates the refresh token, so the new login
//! is written back to the same Keychain entry before anything else uses it.
//! Observed Claude behavior this relies on: docs/claude-internals.md

const std = @import("std");
const http = @import("http.zig");
const keychain = @import("keychain.zig");

/// Claude Code's public OAuth client id.
pub const CLIENT_ID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e";
pub const TOKEN_URL = "https://platform.claude.com/v1/oauth/token";
pub const KEYCHAIN_ACTIVE = "Claude Code-credentials";
pub const KEYCHAIN_PROFILE_PREFIX = "claudacity-code-";

/// A login is treated as expired this long before its stated expiry.
const EXPIRY_MARGIN_MS: i64 = 5 * 60 * 1000;

fn oauthObject(root: std.json.Value) ?std.json.ObjectMap {
    if (root != .object) return null;
    const o = root.object.get("claudeAiOauth") orelse return null;
    return if (o == .object) o.object else null;
}

fn stringIn(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

fn intIn(obj: std.json.ObjectMap, key: []const u8) ?i64 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .integer => |i| i,
        .float => |f| @intFromFloat(f),
        else => null,
    };
}

pub fn isExpired(expires_at_ms: ?i64, now_ms: i64) bool {
    const exp = expires_at_ms orelse return true;
    return exp - EXPIRY_MARGIN_MS <= now_ms;
}

/// Returns an owned copy of the access token when the stored login is still valid.
pub fn validAccessToken(gpa: std.mem.Allocator, stored_json: []const u8, now_ms: i64) !?[]u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, stored_json, .{});
    defer parsed.deinit();
    const o = oauthObject(parsed.value) orelse return error.MalformedLogin;
    if (isExpired(intIn(o, "expiresAt"), now_ms)) return null;
    const token = stringIn(o, "accessToken") orelse return error.MalformedLogin;
    return try gpa.dupe(u8, token);
}

/// Owned copy of the stored refresh token.
pub fn refreshToken(gpa: std.mem.Allocator, stored_json: []const u8) ![]u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, stored_json, .{});
    defer parsed.deinit();
    const o = oauthObject(parsed.value) orelse return error.MalformedLogin;
    return gpa.dupe(u8, stringIn(o, "refreshToken") orelse return error.MalformedLogin);
}

/// The JSON body of a refresh_token grant. Caller owns the result.
pub fn refreshBody(gpa: std.mem.Allocator, refresh_token: []const u8) ![]u8 {
    return std.json.Stringify.valueAlloc(gpa, .{
        .grant_type = "refresh_token",
        .refresh_token = refresh_token,
        .client_id = CLIENT_ID,
    }, .{});
}

pub const RefreshOutcome = enum { refreshed, needs_sign_in };

/// Merges a successful token response into the stored login, preserving every
/// other field. Returns the new stored JSON (owned). Errors carry no token text.
pub fn applyRefresh(gpa: std.mem.Allocator, stored_json: []const u8, response_json: []const u8, now_ms: i64) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const stored = try std.json.parseFromSliceLeaky(std.json.Value, arena, stored_json, .{});
    const resp = std.json.parseFromSliceLeaky(std.json.Value, arena, response_json, .{}) catch return error.MalformedRefreshResponse;
    if (resp != .object) return error.MalformedRefreshResponse;
    const access = resp.object.get("access_token") orelse return error.MalformedRefreshResponse;
    if (access != .string) return error.MalformedRefreshResponse;

    if (stored != .object) return error.MalformedLogin;
    const o_ptr = stored.object.getPtr("claudeAiOauth") orelse return error.MalformedLogin;
    if (o_ptr.* != .object) return error.MalformedLogin;
    const o = &o_ptr.object;

    try o.put(arena, "accessToken", access);
    if (resp.object.get("refresh_token")) |r| {
        if (r == .string) try o.put(arena, "refreshToken", r);
    }
    const expires_in: i64 = if (resp.object.get("expires_in")) |e| switch (e) {
        .integer => |i| i,
        else => 28800,
    } else 28800;
    try o.put(arena, "expiresAt", .{ .integer = now_ms + expires_in * 1000 });

    return std.json.Stringify.valueAlloc(gpa, stored, .{});
}

/// True when the token endpoint's error body says the refresh token is dead.
pub fn isInvalidGrant(body: []const u8) bool {
    return std.mem.indexOf(u8, body, "\"invalid_grant\"") != null;
}

pub const Login = union(enum) {
    /// Owned access token.
    token: []u8,
    needs_sign_in,
    missing,
};

fn nowMs() i64 {
    const c_time = @cImport(@cInclude("time.h"));
    return @as(i64, c_time.time(null)) * 1000;
}

/// A usable access token for `profile_name`, refreshing and writing back when
/// the saved login has expired. `is_active` also refreshes the live Claude Code
/// entry, so both stay on the same rotated refresh token.
pub fn freshAccessToken(gpa: std.mem.Allocator, io: std.Io, profile_name: []const u8, is_active: bool) !Login {
    const profile_svc = try std.fmt.allocPrint(gpa, "{s}{s}", .{ KEYCHAIN_PROFILE_PREFIX, profile_name });
    defer gpa.free(profile_svc);
    const svc: []const u8 = if (is_active) KEYCHAIN_ACTIVE else profile_svc;

    const stored = keychain.get(gpa, io, svc) catch return .missing;
    defer gpa.free(stored);
    const now = nowMs();
    if (try validAccessToken(gpa, stored, now)) |t| return .{ .token = t };

    const rt = try refreshToken(gpa, stored);
    defer gpa.free(rt);
    const body = try refreshBody(gpa, rt);
    defer gpa.free(body);
    const resp = http.send(gpa, io, .{
        .method = "POST",
        .url = TOKEN_URL,
        .headers = &.{.{ .name = "Content-Type", .value = "application/json" }},
        .body = body,
    }) catch return error.RefreshFailed;
    defer resp.deinit(gpa);

    if (resp.status != 200) {
        if (isInvalidGrant(resp.body)) return .needs_sign_in;
        return error.RefreshFailed;
    }

    const updated = try applyRefresh(gpa, stored, resp.body, now);
    defer gpa.free(updated);
    const acct = keychain.getAccount(gpa, io, svc);
    defer gpa.free(acct);
    try keychain.update(gpa, io, svc, acct, updated);
    if (is_active) {
        const p_acct = keychain.getAccount(gpa, io, profile_svc);
        defer gpa.free(p_acct);
        keychain.update(gpa, io, profile_svc, p_acct, updated) catch {};
    }
    return .{ .token = (try validAccessToken(gpa, updated, now)) orelse return error.RefreshFailed };
}

pub const PROFILE_URL = "https://api.anthropic.com/api/oauth/profile";

/// The plan Claude Code stores as `subscriptionType`, from the profile
/// endpoint's `organization.organization_type`; null when unrecognized.
pub fn planFromProfile(gpa: std.mem.Allocator, body: []const u8) !?[]const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, body, .{}) catch return error.MalformedProfile;
    defer parsed.deinit();
    if (parsed.value != .object) return error.MalformedProfile;
    const org = parsed.value.object.get("organization") orelse return null;
    if (org != .object) return null;
    const kind = stringIn(org.object, "organization_type") orelse return null;
    const plans = [_][2][]const u8{
        .{ "claude_max", "max" },
        .{ "claude_pro", "pro" },
        .{ "claude_team", "team" },
        .{ "claude_enterprise", "enterprise" },
    };
    for (plans) |m| if (std.mem.eql(u8, kind, m[0])) return m[1];
    return null;
}

/// The stored login with `subscriptionType` set to `plan` (owned), or null
/// when it already says so.
pub fn applyPlan(gpa: std.mem.Allocator, stored_json: []const u8, plan: []const u8) !?[]u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const stored = try std.json.parseFromSliceLeaky(std.json.Value, arena, stored_json, .{});
    if (stored != .object) return error.MalformedLogin;
    const o_ptr = stored.object.getPtr("claudeAiOauth") orelse return error.MalformedLogin;
    if (o_ptr.* != .object) return error.MalformedLogin;
    if (stringIn(o_ptr.object, "subscriptionType")) |cur| if (std.mem.eql(u8, cur, plan)) return null;
    try o_ptr.object.put(arena, "subscriptionType", .{ .string = plan });
    return try std.json.Stringify.valueAlloc(gpa, stored, .{});
}

/// Updates the plan in `profile_name`'s saved login from the account's current
/// plan. A login records its plan at sign-in, so an upgrade leaves it stale.
/// Only the saved copy is written; Claude Code owns the live entry.
pub fn syncPlan(gpa: std.mem.Allocator, io: std.Io, profile_name: []const u8, access_token: []const u8) !void {
    const auth = try std.fmt.allocPrint(gpa, "Bearer {s}", .{access_token});
    defer {
        @memset(auth, 0);
        gpa.free(auth);
    }
    const resp = try http.send(gpa, io, .{
        .url = PROFILE_URL,
        .headers = &.{
            .{ .name = "Authorization", .value = auth },
            .{ .name = "anthropic-beta", .value = "oauth-2025-04-20" },
        },
    });
    defer resp.deinit(gpa);
    if (resp.status != 200) return error.ProfileRequestFailed;
    const plan = (try planFromProfile(gpa, resp.body)) orelse return;

    const svc = try std.fmt.allocPrint(gpa, "{s}{s}", .{ KEYCHAIN_PROFILE_PREFIX, profile_name });
    defer gpa.free(svc);
    const stored = try keychain.get(gpa, io, svc);
    defer gpa.free(stored);
    const updated = (try applyPlan(gpa, stored, plan)) orelse return;
    defer gpa.free(updated);
    const acct = keychain.getAccount(gpa, io, svc);
    defer gpa.free(acct);
    try keychain.update(gpa, io, svc, acct, updated);
}

const STORED =
    \\{"claudeAiOauth":{"accessToken":"old-at","refreshToken":"old-rt","expiresAt":1000,"scopes":["user:inference"],"subscriptionType":"max"}}
;

test "isExpired treats missing and near-expiry logins as expired" {
    try std.testing.expect(isExpired(null, 0));
    try std.testing.expect(isExpired(1000, 2000));
    try std.testing.expect(isExpired(10 * 60 * 1000, 6 * 60 * 1000));
    try std.testing.expect(!isExpired(60 * 60 * 1000, 0));
}

test "validAccessToken returns null for an expired login" {
    const gpa = std.testing.allocator;
    try std.testing.expect((try validAccessToken(gpa, STORED, 5000)) == null);
    const t = (try validAccessToken(gpa, STORED, -10 * 60 * 1000)).?;
    defer gpa.free(t);
    try std.testing.expectEqualStrings("old-at", t);
}

test "applyRefresh rotates both tokens and keeps other fields" {
    const gpa = std.testing.allocator;
    const out = try applyRefresh(gpa, STORED,
        \\{"access_token":"new-at","refresh_token":"new-rt","expires_in":3600}
    , 1_000_000);
    defer gpa.free(out);
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, out, .{});
    defer parsed.deinit();
    const o = oauthObject(parsed.value).?;
    try std.testing.expectEqualStrings("new-at", stringIn(o, "accessToken").?);
    try std.testing.expectEqualStrings("new-rt", stringIn(o, "refreshToken").?);
    try std.testing.expectEqual(@as(i64, 1_000_000 + 3_600_000), intIn(o, "expiresAt").?);
    try std.testing.expectEqualStrings("max", stringIn(o, "subscriptionType").?);
    try std.testing.expect(o.get("scopes").? == .array);
}

test "applyRefresh keeps the old refresh token when none is returned" {
    const gpa = std.testing.allocator;
    const out = try applyRefresh(gpa, STORED, "{\"access_token\":\"new-at\"}", 0);
    defer gpa.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"refreshToken\":\"old-rt\"") != null);
}

test "applyRefresh rejects a malformed response without echoing it" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(error.MalformedRefreshResponse, applyRefresh(gpa, STORED, "{\"error\":\"x\",\"leak\":\"sk-123\"}", 0));
    try std.testing.expectError(error.MalformedRefreshResponse, applyRefresh(gpa, STORED, "not json", 0));
}

test "isInvalidGrant recognizes a dead refresh token" {
    try std.testing.expect(isInvalidGrant("{\"error\": \"invalid_grant\", \"error_description\": \"Refresh token not found or invalid\"}"));
    try std.testing.expect(!isInvalidGrant("{\"error\":\"server_error\"}"));
}

test "refreshBody carries the grant and client id" {
    const gpa = std.testing.allocator;
    const b = try refreshBody(gpa, "rt-1");
    defer gpa.free(b);
    try std.testing.expectEqualStrings("{\"grant_type\":\"refresh_token\",\"refresh_token\":\"rt-1\",\"client_id\":\"9d1c250a-e61b-44d9-88ed-5944d1962f5e\"}", b);
}

test "planFromProfile maps the organization type to Claude Code's plan name" {
    const gpa = std.testing.allocator;
    try std.testing.expectEqualStrings("max", (try planFromProfile(gpa,
        \\{"account":{"email":"a@b.c"},"organization":{"organization_type":"claude_max","rate_limit_tier":"default_claude_max_20x"}}
    )).?);
    try std.testing.expectEqualStrings("pro", (try planFromProfile(gpa, "{\"organization\":{\"organization_type\":\"claude_pro\"}}")).?);
    try std.testing.expect((try planFromProfile(gpa, "{\"organization\":{\"organization_type\":\"other\"}}")) == null);
    try std.testing.expect((try planFromProfile(gpa, "{}")) == null);
    try std.testing.expectError(error.MalformedProfile, planFromProfile(gpa, "nope"));
}

test "applyPlan rewrites a stale plan and keeps other fields" {
    const gpa = std.testing.allocator;
    try std.testing.expect((try applyPlan(gpa, STORED, "max")) == null);
    const out = (try applyPlan(gpa, STORED, "pro")).?;
    defer gpa.free(out);
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, out, .{});
    defer parsed.deinit();
    const o = oauthObject(parsed.value).?;
    try std.testing.expectEqualStrings("pro", stringIn(o, "subscriptionType").?);
    try std.testing.expectEqualStrings("old-rt", stringIn(o, "refreshToken").?);
}
