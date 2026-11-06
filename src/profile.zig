//! profile.zig — gerenciamento de perfis

const std = @import("std");
const desktop = @import("desktop.zig");
const desktop_settings = @import("desktop_settings.zig");
const display = @import("display.zig");
const keychain = @import("keychain.zig");
const paths = @import("paths.zig");
const skills = @import("skills.zig");
const plugins = @import("plugins.zig");
const mcp = @import("mcp.zig");
const sessions = @import("sessions.zig");
const usage = @import("usage.zig");
const marketplaces = @import("marketplaces.zig");
const oauth_login = @import("oauth.zig");
const exec = @import("exec.zig");
const accounts = @import("accounts.zig");

const c = @cImport({
    @cInclude("dirent.h");
    @cInclude("unistd.h");
});

const KEYCHAIN_CODE = "Claude Code-credentials";
const KC_PROFILE_CODE = "claudacity-code-";

// ── API pública ───────────────────────────────────────────────────────────────

pub fn list(gpa: std.mem.Allocator) ![]const []const u8 {
    const h = try paths.home(gpa);
    defer gpa.free(h);
    return listIn(gpa, h);
}

pub fn current(gpa: std.mem.Allocator) !?[]const u8 {
    const h = try paths.home(gpa);
    defer gpa.free(h);
    return currentIn(gpa, h);
}

pub fn profileJsonEmail(gpa: std.mem.Allocator, name: []const u8) !?[]const u8 {
    const h = try paths.home(gpa);
    defer gpa.free(h);
    return profileJsonEmailIn(gpa, h, name);
}

/// Saves the live login as `name`'s and pins `name` to its account: the user
/// saying which account the profile is.
pub fn cmdSave(gpa: std.mem.Allocator, io: std.Io, name: []const u8) !void {
    return saveAs(gpa, io, name, .explicit);
}

const SaveKind = enum {
    /// `claudacity save`: whatever is signed in becomes the profile's account.
    explicit,
    /// The save before a switch: a login for another account is not saved.
    auto,
};

fn saveAs(gpa: std.mem.Allocator, io: std.Io, name: []const u8, kind: SaveKind) !void {
    const h = try paths.home(gpa);
    defer gpa.free(h);

    // Only the first save, of a setup claudacity has not moved yet, creates the
    // profile's files. Any other unknown name would get the active profile's
    // login under a profile nothing lists.
    try migrateToProfileIn(gpa, io, h, name);
    const p_json = try paths.profileJsonIn(gpa, h, name);
    defer gpa.free(p_json);
    if (!desktop.pathExists(gpa, p_json)) {
        display.print("❌  Profile '{s}' does not exist. To add an account, create it first: claudacity new {s}\n", .{ name, name });
        return error.ProfileNotFound;
    }

    var c_token: ?[]const u8 = null;
    var c_acct: []const u8 = "";
    if (keychain.get(gpa, io, KEYCHAIN_CODE)) |token| {
        display.info("Reading Claude Code session...");
        c_token = token;
        c_acct = keychain.getAccount(gpa, io, KEYCHAIN_CODE);
    } else |_| {
        display.info("Claude Code not available — skipping.");
    }
    defer if (c_token) |t| gpa.free(t);
    defer if (c_acct.len > 0) gpa.free(c_acct);

    if (c_token) |token| keep: {
        // The live login's own account, else the one `claude auth login` wrote.
        const live = oauth_login.liveAccountEmail(gpa, io) orelse (profileJsonEmailIn(gpa, h, name) catch null);
        defer if (live) |l| gpa.free(l);
        const pinned = if (kind == .auto) expectedAccount(gpa, h, name) else accounts.pinned(gpa, h, name);
        defer if (pinned) |p| gpa.free(p);
        if (live) |l| {
            if (pinned) |p| if (!accounts.same(l, p)) switch (kind) {
                .auto => {
                    display.print("⚠️  Claude Code is signed in as {s}, not '{s}' ({s}), so '{s}' keeps its saved login.\n", .{ l, name, p, name });
                    break :keep;
                },
                .explicit => display.print("'{s}' is now {s} (was {s})\n", .{ name, l, p }),
            };
            if (pinned == null or kind == .explicit) accounts.pin(gpa, h, name, l) catch |err| {
                display.print("⚠️  Could not record '{s}' as {s}: {s}\n", .{ name, l, @errorName(err) });
            };
        }
        const svc = try std.fmt.allocPrint(gpa, "{s}{s}", .{ KC_PROFILE_CODE, name });
        defer gpa.free(svc);
        try keychain.set(gpa, io, svc, c_acct, token);
        if (kind == .auto) renewSaved(gpa, io, name);
    }

    const msg = try std.fmt.allocPrint(gpa, "Profile '{s}' saved", .{name});
    defer gpa.free(msg);
    display.ok(msg);
}

/// Renews the login just saved from Claude Code before the switch away from `name`.
/// `claude` processes still running as `name` hold the same login, and whichever
/// side renews it first leaves the other's copy dead; renewing now makes the saved
/// copy the live one. Those processes re-read Claude Code's stored login when their
/// renewal fails, so they move to the incoming account rather than signing out.
fn renewSaved(gpa: std.mem.Allocator, io: std.Io, name: []const u8) void {
    const login = oauth_login.freshAccessTokenWith(gpa, io, name, true, .{ .force = true }) catch |err| {
        display.print("⚠️  Could not renew '{s}''s login ({s}); a session still running as it may leave it needing sign-in.\n", .{ name, @errorName(err) });
        return;
    };
    switch (login) {
        .token => |t| {
            @memset(t, 0);
            gpa.free(t);
        },
        .needs_sign_in => display.print("⚠️  '{s}''s login is no longer valid; sign in again with: claudacity login {s}\n", .{ name, name }),
        .missing => {},
    }
}

/// Switches to `name` and reports which open sessions were carried.
pub fn cmdUse(gpa: std.mem.Allocator, io: std.Io, name: []const u8, opts: UseOptions) !void {
    var result = try useWith(gpa, io, name, opts);
    defer result.deinit(gpa);
    if (result.carry) |carried| {
        if (carried.carried > 0) display.print("Carried {d} open session(s) into '{s}'\n", .{ carried.carried, name });
        for (carried.failed.items) |f| display.print("  not carried: {s} ({s})\n", .{ f.title, f.reason });
    } else if (result.carry_skipped) |why| display.print("⚠️  Sessions not carried: {s}\n", .{why});
}

pub const UseOptions = struct {
    /// Move every open local Code session into the target profile (KTD7).
    carry_sessions: bool = true,
};

pub const UseResult = struct {
    carry: ?sessions.Result = null,
    /// Why carry-over failed, when it was requested and there was a profile to carry from.
    carry_skipped: ?[]const u8 = null,

    pub fn deinit(r: *UseResult, gpa: std.mem.Allocator) void {
        if (r.carry) |*carried| carried.deinit(gpa);
    }
};

/// Carries Desktop's preferences, MCP servers and local environments from
/// `from`, already swapped out, into the live Desktop dir now holding `to`.
/// A failure only warns.
fn carryDesktopSettings(gpa: std.mem.Allocator, io: std.Io, h: []const u8, from: []const u8, to: []const u8) void {
    if (std.mem.eql(u8, from, to)) return;
    const from_dir = paths.desktopProfileDirIn(gpa, h, from) catch return;
    defer gpa.free(from_dir);
    const to_dir = paths.desktopDirIn(gpa, h) catch return;
    defer gpa.free(to_dir);
    _ = desktop_settings.carryIn(gpa, io, from_dir, to_dir) catch |err| {
        display.print("⚠️  Could not carry Desktop settings from '{s}': {s}\n", .{ from, @errorName(err) });
    };
    // Local environments are keyed by account; a profile not yet signed in has none.
    const from_acct = profileAccountUuid(gpa, io, h, from) orelse return;
    defer gpa.free(from_acct);
    const to_acct = profileAccountUuid(gpa, io, h, to) orelse return;
    defer gpa.free(to_acct);
    _ = desktop_settings.carryPresetsIn(gpa, io, from_dir, from_acct, to_dir, to_acct) catch |err| {
        display.print("⚠️  Could not carry local environments from '{s}': {s}\n", .{ from, @errorName(err) });
    };
}

fn profileAccountUuid(gpa: std.mem.Allocator, io: std.Io, h: []const u8, name: []const u8) ?[]u8 {
    const p_json = paths.profileJsonIn(gpa, h, name) catch return null;
    defer gpa.free(p_json);
    const rel = sessions.accountRel(gpa, io, p_json) catch return null;
    defer gpa.free(rel);
    const end = std.mem.indexOfScalar(u8, rel, '/') orelse rel.len;
    return gpa.dupe(u8, rel[0..end]) catch null;
}

/// Carries open local sessions from the active profile `from` into `to`.
/// Runs after Desktop has quit and before the profile directories swap.
fn carrySessions(gpa: std.mem.Allocator, io: std.Io, h: []const u8, from: []const u8, to: []const u8) !sessions.Result {
    const src_desktop = try paths.desktopDirIn(gpa, h);
    defer gpa.free(src_desktop);
    const dst_desktop = try paths.desktopProfileDirIn(gpa, h, to);
    defer gpa.free(dst_desktop);
    const src_code = try paths.profileDirIn(gpa, h, from);
    defer gpa.free(src_code);
    const dst_code = try paths.profileDirIn(gpa, h, to);
    defer gpa.free(dst_code);
    const src_json = try paths.profileJsonIn(gpa, h, from);
    defer gpa.free(src_json);
    const dst_json = try paths.profileJsonIn(gpa, h, to);
    defer gpa.free(dst_json);
    const src_rel = try sessions.accountRel(gpa, io, src_json);
    defer gpa.free(src_rel);
    const dst_rel = try sessions.accountRel(gpa, io, dst_json);
    defer gpa.free(dst_rel);

    var busy = try sessions.settleSessionProcesses(gpa, io, src_desktop, 30);
    defer sessions.freeIds(gpa, &busy);
    const busy_const: []const []const u8 = @ptrCast(busy.items);
    return sessions.carryIn(gpa, io, .{ .desktop_dir = src_desktop, .account_rel = src_rel, .code_dir = src_code }, .{ .desktop_dir = dst_desktop, .account_rel = dst_rel, .code_dir = dst_code }, busy_const);
}

pub fn useWith(gpa: std.mem.Allocator, io: std.Io, name: []const u8, opts: UseOptions) !UseResult {
    var use_result: UseResult = .{};
    errdefer use_result.deinit(gpa);
    const h = try paths.home(gpa);
    defer gpa.free(h);

    const p_json = try paths.profileJsonIn(gpa, h, name);
    defer gpa.free(p_json);

    if (!desktop.pathExists(gpa, p_json)) {
        display.print("❌  Profile '{s}' not found. Create it first: claudacity new {s}\n", .{ name, name });
        return error.ProfileNotFound;
    }

    const shared_source = try skills.sourceForIn(gpa, h, name);
    defer if (shared_source) |source| gpa.free(source);
    if (shared_source) |source| {
        const plugin_result = plugins.syncIn(gpa, io, h, source, name) catch |err| {
            display.print("❌  Could not sync plugins into '{s}': {s}. Profile was not switched.\n", .{ name, @errorName(err) });
            return err;
        };
        if (plugin_result.installed + plugin_result.updated + plugin_result.toggled > 0) {
            display.print("Synced plugins into '{s}' ({d} installed, {d} updated, {d} enabled states matched)\n", .{ name, plugin_result.installed, plugin_result.updated, plugin_result.toggled });
        }
        // A missing MCP server costs a session one tool; a refused switch costs
        // the account, so this one warns and switches anyway.
        if (mcp.syncIn(gpa, io, h, source, name)) |mcp_result| {
            if (mcp_result.added + mcp_result.updated > 0) {
                display.print("Synced MCP servers into '{s}' ({d} added, {d} updated)\n", .{ name, mcp_result.added, mcp_result.updated });
            }
        } else |err| {
            display.print("⚠️  Could not sync MCP servers into '{s}': {s}\n", .{ name, @errorName(err) });
        }
    }

    const shared_count = skills.syncIn(gpa, h, name) catch |err| blk: {
        display.print("⚠️  Could not refresh shared skills for '{s}': {s}\n", .{ name, @errorName(err) });
        break :blk 0;
    };
    if (shared_count > 0) display.print("Linked {d} new local skills into '{s}'\n", .{ shared_count, name });

    const cur = try currentIn(gpa, h);
    defer if (cur) |cur_owned| gpa.free(cur_owned);
    if (cur) |c_name| {
        if (!std.mem.eql(u8, c_name, name)) {
            const msg = try std.fmt.allocPrint(gpa, "Auto-saving current profile '{s}' before switching...", .{c_name});
            defer gpa.free(msg);
            display.info(msg);
            try saveAs(gpa, io, c_name, .auto);
        }
    }

    const svc = try std.fmt.allocPrint(gpa, "{s}{s}", .{ KC_PROFILE_CODE, name });
    defer gpa.free(svc);

    // Check the login being switched to before Claude Code gets it: one that
    // has lapsed, is missing or belongs to another account leaves every CLI
    // session failing or on the wrong account, while Desktop, which signs in on
    // its own, works. Skipped for the active profile, whose saved copy is older
    // than the live login.
    const switching = if (cur) |c_name| !std.mem.eql(u8, c_name, name) else true;
    const sign_in: ?SignInReason = if (switching) checkSaved(gpa, io, h, name) else null;

    const c_token = if (sign_in == null) keychain.get(gpa, io, svc) catch null else null;
    defer if (c_token) |t| gpa.free(t);
    const c_acct = keychain.getAccount(gpa, io, svc);
    defer gpa.free(c_acct);

    desktop.quit(gpa, io);

    if (opts.carry_sessions) {
        if (cur) |c_name| {
            if (std.mem.eql(u8, c_name, name)) {
                // Nothing to move: the sessions are already on this profile.
            } else {
                var progress: display.Progress = .{ .label = "Carrying open sessions" };
                progress.start(io);
                const carried = carrySessions(gpa, io, h, c_name, name);
                progress.stop(io);
                if (carried) |moved| use_result.carry = moved else |err| use_result.carry_skipped = @errorName(err);
            }
        }
    }

    if (c_token) |token| {
        const msg = try std.fmt.allocPrint(gpa, "Switching Claude Code → {s}", .{name});
        defer gpa.free(msg);
        display.info(msg);
        try keychain.set(gpa, io, KEYCHAIN_CODE, c_acct, token);
    } else if (switching) {
        // Left in place, the last profile's login would run this one's sessions.
        keychain.delete(gpa, io, KEYCHAIN_CODE) catch {};
    }

    try switchLinksIn(gpa, h, name);
    try desktop.swap(gpa, cur, name);
    if (cur) |c_name| carryDesktopSettings(gpa, io, h, c_name, name);
    // Desktop is quit, so its cookies are settled; sync before relaunching it.
    marketplaces.syncAfterSwitch(gpa, io, h, name);
    if (desktop.hasLiveData(gpa)) desktop.launch(gpa, io);

    const msg = try std.fmt.allocPrint(gpa, "Switched to '{s}'", .{name});
    defer gpa.free(msg);
    display.ok(msg);
    if (sign_in) |why| signInAgain(gpa, io, h, name, why);
    return use_result;
}

/// The account `name` belongs to: its pin, else the account its JSON names,
/// pinned now so a later `claude auth login` as another account cannot move it.
fn expectedAccount(gpa: std.mem.Allocator, h: []const u8, name: []const u8) ?[]u8 {
    if (accounts.pinned(gpa, h, name)) |p| return p;
    const from_json = (profileJsonEmailIn(gpa, h, name) catch null) orelse return null;
    const owned = gpa.dupe(u8, from_json) catch null;
    gpa.free(from_json);
    const email = owned orelse return null;
    accounts.pin(gpa, h, name, email) catch {};
    return email;
}

const SignInReason = union(enum) {
    lapsed,
    missing,
    /// The saved login's account, which is not the profile's.
    other_account: []u8,
};

/// Why `name`'s saved login cannot be handed to Claude Code, or null when it
/// can. A login whose account cannot be read (offline) is trusted.
fn checkSaved(gpa: std.mem.Allocator, io: std.Io, h: []const u8, name: []const u8) ?SignInReason {
    const login = oauth_login.freshAccessToken(gpa, io, name, false) catch return null;
    switch (login) {
        .needs_sign_in => return .lapsed,
        .missing => return .missing,
        .token => |t| {
            defer {
                @memset(t, 0);
                gpa.free(t);
            }
            const got = oauth_login.accountEmail(gpa, io, t) orelse return null;
            const pinned = expectedAccount(gpa, h, name) orelse {
                // Nothing names this profile's account: its saved login does.
                accounts.pin(gpa, h, name, got) catch {};
                gpa.free(got);
                return null;
            };
            defer gpa.free(pinned);
            if (accounts.same(got, pinned)) {
                gpa.free(got);
                return null;
            }
            return .{ .other_account = got };
        },
    }
}

const SIGN_IN_TRIES = 3;

/// Signs the now-active profile `name` in as its own account, then saves it, so
/// the switch leaves Claude Code working. Needs a terminal for the
/// sign-in; an unattended switch only warns, leaving Claude Code signed out.
fn signInAgain(gpa: std.mem.Allocator, io: std.Io, h: []const u8, name: []const u8, why: SignInReason) void {
    defer if (why == .other_account) gpa.free(why.other_account);
    const want = expectedAccount(gpa, h, name);
    defer if (want) |w| gpa.free(w);
    const as = want orelse "its account";
    switch (why) {
        .lapsed => display.print("🔑  '{s}' Claude Code login has lapsed.\n", .{name}),
        .missing => display.print("🔑  '{s}' has no saved Claude Code login.\n", .{name}),
        .other_account => |got| display.print("🔑  '{s}' saved Claude Code login is {s}, not {s}.\n", .{ name, got, as }),
    }
    if (std.c.isatty(std.posix.STDIN_FILENO) != 1) {
        display.print("⚠️  Claude Code is signed out, so its sessions will fail. Sign in again with: claudacity login {s}\n", .{name});
        return;
    }

    // `claude auth login` rewrites the active profile's account, so a sign-in
    // as the wrong one is put back from this copy.
    const json_path = paths.profileJsonIn(gpa, h, name) catch return;
    defer gpa.free(json_path);
    const before = readFileAlloc(gpa, json_path);
    defer if (before) |b| gpa.free(b);

    var tries: usize = 0;
    while (tries < SIGN_IN_TRIES) : (tries += 1) {
        signInPrompt(name, want);
        if (!runLogin(gpa, io, want)) {
            display.print("❌  Sign-in did not finish.\n", .{});
            break;
        }
        const got = oauth_login.liveAccountEmail(gpa, io) orelse signedInEmail(gpa, io);
        defer if (got) |g| gpa.free(g);
        if (want == null or (got != null and accounts.same(got.?, want.?))) {
            saveAs(gpa, io, name, .explicit) catch |err| {
                display.print("❌  Signed in, but could not save '{s}': {s}\n", .{ name, @errorName(err) });
                return;
            };
            const msg = std.fmt.allocPrint(gpa, "Signed '{s}' in as {s} and saved it", .{ name, got orelse as }) catch return;
            defer gpa.free(msg);
            display.ok(msg);
            return;
        }
        display.print("❌  Signed in as {s}, not {s}.\n", .{ got orelse "an unknown account", as });
    }

    keychain.delete(gpa, io, KEYCHAIN_CODE) catch {};
    if (before) |b| writeFileAll(gpa, json_path, b) catch {};
    display.print("⚠️  Claude Code is left signed out under '{s}'. Sign in again with: claudacity login {s}\n", .{ name, name });
}

fn signInPrompt(name: []const u8, want: ?[]const u8) void {
    if (want) |w|
        display.print("🔑  Open the link below in a browser signed in to claude.ai as {s}, and paste back the code it shows.\n", .{w})
    else
        display.print("🔑  Open the link below in a browser signed in to the claude.ai account for '{s}', and paste back the code it shows.\n", .{name});
}

/// Runs `claude auth login` with a browser that opens nothing, so the sign-in is
/// only the link it prints, for the reader to open in a browser profile already
/// signed in to the account: claudacity cannot tell which account a browser is
/// signed in to, and `--email` only pre-fills the form.
fn runLogin(gpa: std.mem.Allocator, io: std.Io, want: ?[]const u8) bool {
    return runLoginIn(gpa, io, want, null);
}

/// `runLogin` with `CLAUDE_CONFIG_DIR=config_dir`, whose login Claude Code keeps
/// in its own Keychain entry (`oauth.configDirService`), apart from the live one.
fn runLoginIn(gpa: std.mem.Allocator, io: std.Io, want: ?[]const u8, config_dir: ?[]const u8) bool {
    const config_env = if (config_dir) |d| std.fmt.allocPrint(gpa, "CLAUDE_CONFIG_DIR={s}", .{d}) catch return false else null;
    defer if (config_env) |e| gpa.free(e);
    var argv_buf: [8][]const u8 = undefined;
    var argv_len: usize = 0;
    for ([_]?[]const u8{ "/usr/bin/env", "BROWSER=/usr/bin/true", config_env, "claude", "auth", "login" }) |a| if (a) |arg| {
        argv_buf[argv_len] = arg;
        argv_len += 1;
    };
    if (want) |w| {
        argv_buf[argv_len] = "--email";
        argv_buf[argv_len + 1] = w;
        argv_len += 2;
    }
    const argv: []const []const u8 = argv_buf[0..argv_len];
    var child = std.process.spawn(io, .{ .argv = argv, .stdin = .inherit, .stdout = .inherit, .stderr = .inherit }) catch |err| {
        display.print("❌  Could not run claude auth login: {s}\n", .{@errorName(err)});
        return false;
    };
    const term = child.wait(io) catch return false;
    return term == .exited and term.exited == 0;
}

fn readFileAlloc(gpa: std.mem.Allocator, path: []const u8) ?[]u8 {
    const path_z = gpa.dupeZ(u8, path) catch return null;
    defer gpa.free(path_z);
    const fd = std.c.open(path_z, .{}, @as(std.c.mode_t, 0));
    if (fd < 0) return null;
    defer _ = std.c.close(fd);
    var out: std.ArrayList(u8) = .empty;
    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        const n = std.c.read(fd, &buf, buf.len);
        if (n < 0) {
            out.deinit(gpa);
            return null;
        }
        if (n == 0) break;
        out.appendSlice(gpa, buf[0..@intCast(n)]) catch {
            out.deinit(gpa);
            return null;
        };
    }
    return out.toOwnedSlice(gpa) catch null;
}

fn writeFileAll(gpa: std.mem.Allocator, path: []const u8, data: []const u8) !void {
    const path_z = try gpa.dupeZ(u8, path);
    defer gpa.free(path_z);
    const fd = std.c.open(path_z, .{ .ACCMODE = .WRONLY, .TRUNC = true }, @as(std.c.mode_t, 0));
    if (fd < 0) return error.OpenFailed;
    defer _ = std.c.close(fd);
    if (std.c.write(fd, data.ptr, data.len) != data.len) return error.WriteFailed;
}

/// The account Claude Code is signed in as, from `claude auth status`.
fn signedInEmail(gpa: std.mem.Allocator, io: std.Io) ?[]u8 {
    const r = exec.run(gpa, io, .{ .argv = &.{ "claude", "auth", "status", "--json" }, .timeout_s = 30 }) catch return null;
    defer r.deinit(gpa);
    if (!r.ok()) return null;
    return statusEmail(gpa, r.stdout);
}

pub fn statusEmail(gpa: std.mem.Allocator, status_json: []const u8) ?[]u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, status_json, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const email = parsed.value.object.get("email") orelse return null;
    if (email != .string) return null;
    return gpa.dupe(u8, email.string) catch null;
}

pub fn cmdNew(gpa: std.mem.Allocator, io: std.Io, name: []const u8) !void {
    const h = try paths.home(gpa);
    defer gpa.free(h);

    const p_json = try paths.profileJsonIn(gpa, h, name);
    defer gpa.free(p_json);
    const p_dir = try paths.profileDirIn(gpa, h, name);
    defer gpa.free(p_dir);

    if (desktop.pathExists(gpa, p_json) or desktop.pathExists(gpa, p_dir)) {
        display.print("❌  Profile '{s}' files already exist. Use: claudacity use {s}\n", .{ name, name });
        return error.ProfileAlreadyExists;
    }

    try ensureCurrentSavedIn(gpa, io, h);
    desktop.quit(gpa, io);

    // Create empty profile JSON
    {
        const p_json_z = try gpa.dupeZ(u8, p_json);
        defer gpa.free(p_json_z);
        const fd = std.c.open(p_json_z, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o600));
        if (fd < 0) return error.CreateFileFailed;
        _ = std.c.write(fd, "{}", 2);
        _ = std.c.close(fd);
    }

    try desktop.mkdirAllC(gpa, p_dir);
    keychain.delete(gpa, io, KEYCHAIN_CODE) catch {};

    const cur_name = try currentIn(gpa, h);
    defer if (cur_name) |cn| gpa.free(cn);

    try switchLinksIn(gpa, h, name);
    try desktop.swap(gpa, cur_name, name);
    if (cur_name) |cn| {
        carryDesktopSettings(gpa, io, h, cn, name);
        shareIntoNew(gpa, io, h, cn, name);
    }

    const ok_msg = try std.fmt.allocPrint(gpa, "Profile '{s}' created and activated.", .{name});
    defer gpa.free(ok_msg);
    display.ok(ok_msg);
    const info_msg = try std.fmt.allocPrint(
        gpa,
        "Now sign Claude Code in with: `claudacity login {s}`, and Claude Desktop in its own window\n",
        .{name},
    );
    defer gpa.free(info_msg);
    display.info(info_msg);
}

/// A new profile shares skills, plugins and MCP servers from the profile the
/// outgoing one shares from (else the outgoing one), so it starts with the same
/// tools and keeps getting them on each switch. The profile already exists by
/// now, so a failure only warns: the share is recorded first, and the next
/// switch to the profile retries the plugin and MCP sync.
fn shareIntoNew(gpa: std.mem.Allocator, io: std.Io, h: []const u8, outgoing: []const u8, name: []const u8) void {
    const source = skills.newSourceIn(gpa, h, outgoing) catch |err| {
        display.print("⚠️  Could not read what '{s}' shares from: {s}. Run `claudacity share <source> {s}`.\n", .{ outgoing, @errorName(err), name });
        return;
    };
    defer gpa.free(source);
    const count = skills.shareIn(gpa, h, source, name) catch |err| {
        display.print("⚠️  Could not share from '{s}' into '{s}': {s}. Run `claudacity share {s} {s}`.\n", .{ source, name, @errorName(err), source, name });
        return;
    };
    const plugin_result = plugins.syncIn(gpa, io, h, source, name) catch |err| {
        display.print("⚠️  Could not install '{s}''s plugins into '{s}': {s}. They install on the next `claudacity use {s}`.\n", .{ source, name, @errorName(err), name });
        return;
    };
    const mcp_result = mcp.syncIn(gpa, io, h, source, name) catch |err| blk: {
        display.print("⚠️  Could not copy '{s}''s MCP servers into '{s}': {s}\n", .{ source, name, @errorName(err) });
        break :blk mcp.SyncResult{};
    };
    display.print("Sharing from '{s}' ({d} skill links, {d} plugins installed, {d} MCP servers added).\n", .{ source, count, plugin_result.installed, mcp_result.added });
}

pub fn cmdShare(gpa: std.mem.Allocator, io: std.Io, source: []const u8, target: []const u8) !void {
    const h = try paths.home(gpa);
    defer gpa.free(h);
    const count = try skills.shareIn(gpa, h, source, target);
    const plugin_result = try plugins.syncIn(gpa, io, h, source, target);
    const mcp_result = try mcp.syncIn(gpa, io, h, source, target);
    display.print("Sharing local skills, plugins and MCP servers from '{s}' to '{s}' ({d} new skill links, {d} plugins installed, {d} updated, {d} enabled states matched, {d} MCP servers added, {d} updated). Future additions sync when you switch to '{s}'.\n", .{ source, target, count, plugin_result.installed, plugin_result.updated, plugin_result.toggled, mcp_result.added, mcp_result.updated, target });
}

pub fn cmdUnshare(gpa: std.mem.Allocator, target: []const u8) !void {
    const h = try paths.home(gpa);
    defer gpa.free(h);
    const count = try skills.unshareIn(gpa, h, target);
    display.print("Stopped sharing skills, plugins and MCP servers into '{s}' ({d} shared skill links removed). Installed plugins and MCP servers remain in the profile.\n", .{ target, count });
}

pub fn cmdDelete(gpa: std.mem.Allocator, io: std.Io, name_opt: ?[]const u8) !void {
    const h = try paths.home(gpa);
    defer gpa.free(h);

    const name = if (name_opt) |n| try gpa.dupe(u8, n) else blk: {
        const profiles = try listIn(gpa, h);
        defer {
            for (profiles) |p| gpa.free(p);
            gpa.free(profiles);
        }
        if (profiles.len == 0) {
            display.err("No profiles saved yet.");
            return error.NoProfiles;
        }
        const chosen = try fuzzyPick(gpa, io, h, profiles, null, "Delete profile > ", false);
        break :blk chosen orelse {
            display.err("No profile selected");
            return error.NoneSelected;
        };
    };
    defer gpa.free(name);

    const p_json = try paths.profileJsonIn(gpa, h, name);
    defer gpa.free(p_json);
    const p_dir = try paths.profileDirIn(gpa, h, name);
    defer gpa.free(p_dir);
    const d_dir = try paths.desktopProfileDirIn(gpa, h, name);
    defer gpa.free(d_dir);

    if (!desktop.pathExists(gpa, p_json) and !desktop.pathExists(gpa, p_dir)) {
        display.print("❌  Profile '{s}' not found\n", .{name});
        return error.ProfileNotFound;
    }

    const profiles = try listIn(gpa, h);
    defer {
        for (profiles) |p| gpa.free(p);
        gpa.free(profiles);
    }
    for (profiles) |p| {
        if (std.mem.eql(u8, p, name)) continue;
        const source = try skills.sourceForIn(gpa, h, p);
        defer if (source) |s| gpa.free(s);
        if (source) |s| {
            if (std.mem.eql(u8, s, name)) {
                display.print("❌  Profile '{s}' supplies shared skills, plugins and MCP servers to '{s}'. Run `claudacity unshare {s}` first.\n", .{ name, p, p });
                return error.ProfileHasSharedSkillsDependents;
            }
        }
    }

    const cj = try paths.claudeJsonIn(gpa, h);
    defer gpa.free(cj);

    var link_buf: [std.fs.max_path_bytes]u8 = undefined;
    const is_active = blk: {
        const n = desktop.readLinkC(gpa, cj, &link_buf) catch break :blk false;
        break :blk std.mem.eql(u8, link_buf[0..n], p_json);
    };

    if (is_active) {
        desktop.quit(gpa, io);
        keychain.delete(gpa, io, KEYCHAIN_CODE) catch {};
        const links = [_][]const u8{
            try paths.claudeJsonIn(gpa, h),
            try paths.claudeDirIn(gpa, h),
            try paths.desktopDirIn(gpa, h),
        };
        defer for (links) |l| gpa.free(l);
        for (links) |l| {
            if (desktop.isSymlink(gpa, l)) desktop.deletePathC(gpa, l);
        }
    }

    const svc = try std.fmt.allocPrint(gpa, "{s}{s}", .{ KC_PROFILE_CODE, name });
    defer gpa.free(svc);
    keychain.delete(gpa, io, svc) catch {};

    if (desktop.pathExists(gpa, p_json)) desktop.deletePathC(gpa, p_json);
    if (desktop.pathExists(gpa, p_dir)) try deleteTreeC(gpa, io, p_dir);
    if (desktop.pathExists(gpa, d_dir)) try deleteTreeC(gpa, io, d_dir);

    const msg = try std.fmt.allocPrint(gpa, "Profile '{s}' deleted", .{name});
    defer gpa.free(msg);
    display.ok(msg);
}

pub fn cmdList(gpa: std.mem.Allocator, io: std.Io) !void {
    const h = try paths.home(gpa);
    defer gpa.free(h);
    try ensureCurrentSavedIn(gpa, io, h);

    const profiles = try listIn(gpa, h);
    defer {
        for (profiles) |p| gpa.free(p);
        gpa.free(profiles);
    }

    if (profiles.len == 0) {
        display.print("No profiles saved yet. Use: claudacity save <n>\n", .{});
        return;
    }

    const active = try currentIn(gpa, h);
    defer if (active) |a| gpa.free(a);

    for (profiles) |p| {
        const marker: []const u8 = if (active != null and std.mem.eql(u8, p, active.?)) "  ◀" else "";
        display.print("  • {s}{s}\n", .{ p, marker });
    }
}

pub fn cmdPick(gpa: std.mem.Allocator, io: std.Io) !void {
    const h = try paths.home(gpa);
    defer gpa.free(h);

    const profiles = try listIn(gpa, h);
    defer {
        for (profiles) |p| gpa.free(p);
        gpa.free(profiles);
    }

    if (profiles.len == 0) {
        display.err("No profiles saved yet. Use: claudacity save <n>");
        return error.NoProfiles;
    }

    const labels = try usage.pickerLabels(gpa, io, profiles);
    defer usage.freeLabels(gpa, labels);

    if (try fuzzyPick(gpa, io, h, profiles, labels, "Pick profile > ", true)) |chosen| {
        defer gpa.free(chosen);
        try cmdUse(gpa, io, chosen, .{});
    }
}

/// Signs `name` in again without switching: `claude auth login` runs under a
/// throwaway config directory, so the live login, Desktop and open sessions stay
/// as they are, and the new login is saved as `name`'s once it is `name`'s account.
pub fn cmdLogin(gpa: std.mem.Allocator, io: std.Io, name: []const u8) !void {
    const h = try paths.home(gpa);
    defer gpa.free(h);
    const p_json = try paths.profileJsonIn(gpa, h, name);
    defer gpa.free(p_json);
    if (!desktop.pathExists(gpa, p_json)) {
        display.print("❌  Profile '{s}' not found. Create it first: claudacity new {s}\n", .{ name, name });
        return error.ProfileNotFound;
    }
    if (std.c.isatty(std.posix.STDIN_FILENO) != 1) {
        display.print("❌  Signing in takes a pasted code, so it needs a terminal.\n", .{});
        return error.NotATerminal;
    }

    const dir = try std.fmt.allocPrint(gpa, "/tmp/claudacity-login-{d}", .{std.c.getpid()});
    defer gpa.free(dir);
    std.Io.Dir.cwd().createDirPath(io, dir) catch |err| {
        display.print("❌  Could not create {s}: {s}\n", .{ dir, @errorName(err) });
        return err;
    };
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    var svc_buf: [64]u8 = undefined;
    const temp_svc = oauth_login.configDirService(&svc_buf, dir);
    defer keychain.delete(gpa, io, temp_svc) catch {};

    // `claude auth login` records the account it signed in as (`oauthAccount`)
    // in `$CLAUDE_CONFIG_DIR/.claude.json`. Linking that to the profile's JSON
    // lands it there, so `whoami` and Desktop's session paths follow the new
    // account; a sign-in that is not saved puts the old JSON back.
    const before = readFileAlloc(gpa, p_json);
    defer if (before) |b| gpa.free(b);
    var saved = false;
    defer if (!saved) if (before) |b| writeFileAll(gpa, p_json, b) catch {};
    {
        const link = try std.fs.path.join(gpa, &.{ dir, ".claude.json" });
        defer gpa.free(link);
        try std.Io.Dir.cwd().symLink(io, p_json, link, .{});
    }

    const want = expectedAccount(gpa, h, name);
    defer if (want) |w| gpa.free(w);
    const as = want orelse "its account";

    var tries: usize = 0;
    while (tries < SIGN_IN_TRIES) : (tries += 1) {
        signInPrompt(name, want);
        if (!runLoginIn(gpa, io, want, dir)) {
            display.print("❌  Sign-in did not finish.\n", .{});
            return error.SignInFailed;
        }
        const login = keychain.get(gpa, io, temp_svc) catch {
            display.print("❌  claude auth login finished but saved no login.\n", .{});
            return error.SignInFailed;
        };
        defer gpa.free(login);
        const token = (oauth_login.validAccessToken(gpa, login, oauth_login.nowMs()) catch null) orelse {
            display.print("❌  The new login has no usable token.\n", .{});
            return error.SignInFailed;
        };
        const got = oauth_login.accountEmail(gpa, io, token);
        @memset(token, 0);
        gpa.free(token);
        defer if (got) |g| gpa.free(g);
        if (want != null and (got == null or !accounts.same(got.?, want.?))) {
            display.print("❌  Signed in as {s}, not {s}.\n", .{ got orelse "an unknown account", as });
            keychain.delete(gpa, io, temp_svc) catch {};
            if (before) |b| writeFileAll(gpa, p_json, b) catch {};
            continue;
        }
        if (want == null) if (got) |g| accounts.pin(gpa, h, name, g) catch {};

        const svc = try std.fmt.allocPrint(gpa, "{s}{s}", .{ KC_PROFILE_CODE, name });
        defer gpa.free(svc);
        const acct = keychain.getAccount(gpa, io, temp_svc);
        defer gpa.free(acct);
        try keychain.set(gpa, io, svc, acct, login);
        // The active profile runs on the live login, which Claude Code reads.
        const cur = try currentIn(gpa, h);
        defer if (cur) |c_name| gpa.free(c_name);
        if (cur) |c_name| if (std.mem.eql(u8, c_name, name)) try keychain.set(gpa, io, KEYCHAIN_CODE, acct, login);
        saved = true;

        const msg = try std.fmt.allocPrint(gpa, "Signed '{s}' in as {s} and saved it", .{ name, got orelse as });
        defer gpa.free(msg);
        display.ok(msg);
        return;
    }
    display.print("❌  '{s}' keeps its old login.\n", .{name});
    return error.SignInFailed;
}

pub fn cmdLogoutAll(gpa: std.mem.Allocator, io: std.Io) !void {
    const h = try paths.home(gpa);
    defer gpa.free(h);

    display.info("Removing Claude Code keychain entry...");
    keychain.delete(gpa, io, KEYCHAIN_CODE) catch {};
    desktop.quit(gpa, io);

    const links = [_][]const u8{
        try paths.claudeJsonIn(gpa, h),
        try paths.claudeDirIn(gpa, h),
        try paths.desktopDirIn(gpa, h),
    };
    defer for (links) |l| gpa.free(l);

    for (links) |l| {
        if (desktop.isSymlink(gpa, l)) {
            const msg = try std.fmt.allocPrint(gpa, "Removing symlink {s}", .{l});
            defer gpa.free(msg);
            display.info(msg);
            desktop.deletePathC(gpa, l);
        }
    }
    display.ok("Logged out of all accounts. Symlinks removed.");
}

// ── Helpers internos (pub para testes) ───────────────────────────────────────

pub fn listIn(gpa: std.mem.Allocator, base: []const u8) ![]const []const u8 {
    var results: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (results.items) |item| gpa.free(item);
        results.deinit(gpa);
    }

    const base_z = try gpa.dupeZ(u8, base);
    defer gpa.free(base_z);

    const dir_handle = c.opendir(base_z) orelse return results.toOwnedSlice(gpa);
    defer _ = c.closedir(dir_handle);

    while (c.readdir(dir_handle)) |entry| {
        const full = entry.*.d_name;
        const end = std.mem.indexOfScalar(u8, &full, 0) orelse full.len;
        const name = full[0..end];
        if (!std.mem.startsWith(u8, name, ".claude.")) continue;
        if (!std.mem.endsWith(u8, name, ".json")) continue;
        const min_len = ".claude.".len + ".json".len;
        if (name.len <= min_len) continue;
        const stem = name[".claude.".len .. name.len - ".json".len];
        try results.append(gpa, try gpa.dupe(u8, stem));
    }

    const result = try results.toOwnedSlice(gpa);
    std.mem.sort([]const u8, result, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);
    return result;
}

pub fn currentIn(gpa: std.mem.Allocator, base: []const u8) !?[]const u8 {
    const link = try paths.claudeJsonIn(gpa, base);
    defer gpa.free(link);

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = desktop.readLinkC(gpa, link, &buf) catch return null;
    const target = buf[0..n];

    const fname = std.fs.path.basename(target);
    if (!std.mem.startsWith(u8, fname, ".claude.")) return null;
    if (!std.mem.endsWith(u8, fname, ".json")) return null;
    const stem = fname[".claude.".len .. fname.len - ".json".len];
    if (stem.len == 0) return null;
    return @as(?[]const u8, try gpa.dupe(u8, stem));
}

pub fn profileJsonEmailIn(gpa: std.mem.Allocator, base: []const u8, name: []const u8) !?[]const u8 {
    const path = try paths.profileJsonIn(gpa, base, name);
    defer gpa.free(path);

    const path_z = try gpa.dupeZ(u8, path);
    defer gpa.free(path_z);

    const fd = std.c.open(path_z, .{}, @as(std.c.mode_t, 0));
    if (fd < 0) return null;
    defer _ = std.c.close(fd);

    var buf: [1024 * 1024]u8 = undefined;
    const n = std.c.read(fd, &buf, buf.len);
    if (n <= 0) return null;
    const content = buf[0..@intCast(n)];

    const parsed = std.json.parseFromSlice(std.json.Value, gpa, content, .{}) catch return null;
    defer parsed.deinit();

    if (parsed.value != .object) return null;
    const oauth = parsed.value.object.get("oauthAccount") orelse return null;
    if (oauth != .object) return null;
    const email = oauth.object.get("emailAddress") orelse return null;
    if (email != .string) return null;
    return @as(?[]const u8, try gpa.dupe(u8, email.string));
}

pub fn switchLinkIn(gpa: std.mem.Allocator, link: []const u8, target: []const u8, ensure_dir: bool) !void {
    if (!desktop.pathExists(gpa, target)) {
        if (ensure_dir) {
            try desktop.mkdirAllC(gpa, target);
        } else return;
    }

    if (desktop.isSymlink(gpa, link)) {
        desktop.deletePathC(gpa, link);
    } else if (desktop.pathExists(gpa, link)) {
        display.print("❌  {s} exists and is not a symlink. Run 'claudacity save <name>' first.\n", .{link});
        return error.NotASymlink;
    }

    const target_z = try gpa.dupeZ(u8, target);
    defer gpa.free(target_z);
    const link_z = try gpa.dupeZ(u8, link);
    defer gpa.free(link_z);
    if (std.c.symlink(target_z, link_z) != 0) return error.SymlinkFailed;
}

pub fn switchLinksIn(gpa: std.mem.Allocator, base: []const u8, name: []const u8) !void {
    const p_json = try paths.profileJsonIn(gpa, base, name);
    defer gpa.free(p_json);
    const p_dir = try paths.profileDirIn(gpa, base, name);
    defer gpa.free(p_dir);

    if (!desktop.pathExists(gpa, p_json)) {
        display.print("❌  Profile config not found: {s}\nRun: claudacity new {s}\n", .{ p_json, name });
        return error.ProfileNotFound;
    }
    if (!desktop.pathExists(gpa, p_dir)) {
        display.print("❌  Profile dir not found: {s}\nRun: claudacity new {s}\n", .{ p_dir, name });
        return error.ProfileNotFound;
    }

    const cj = try paths.claudeJsonIn(gpa, base);
    defer gpa.free(cj);
    const cd = try paths.claudeDirIn(gpa, base);
    defer gpa.free(cd);

    try switchLinkIn(gpa, cj, p_json, false);
    try switchLinkIn(gpa, cd, p_dir, true);
}

pub fn migrateToProfileIn(gpa: std.mem.Allocator, io: std.Io, base: []const u8, name: []const u8) !void {
    const cj = try paths.claudeJsonIn(gpa, base);
    defer gpa.free(cj);
    const cd = try paths.claudeDirIn(gpa, base);
    defer gpa.free(cd);
    const p_json = try paths.profileJsonIn(gpa, base, name);
    defer gpa.free(p_json);
    const p_dir = try paths.profileDirIn(gpa, base, name);
    defer gpa.free(p_dir);

    if (!desktop.isSymlink(gpa, cj) and desktop.pathExists(gpa, cj)) {
        const msg = try std.fmt.allocPrint(gpa, "Migrating ~/.claude.json → .claude.{s}.json", .{name});
        defer gpa.free(msg);
        display.info(msg);
        try desktop.renameC(gpa, cj, p_json);
        const pj_z = try gpa.dupeZ(u8, p_json);
        defer gpa.free(pj_z);
        const cj_z = try gpa.dupeZ(u8, cj);
        defer gpa.free(cj_z);
        if (std.c.symlink(pj_z, cj_z) != 0) return error.SymlinkFailed;
    }

    if (!desktop.isSymlink(gpa, cd) and desktop.pathExists(gpa, cd)) {
        const msg = try std.fmt.allocPrint(gpa, "Migrating ~/.claude/ → .claude.{s}/", .{name});
        defer gpa.free(msg);
        display.info(msg);
        try desktop.renameC(gpa, cd, p_dir);
        const pd_z = try gpa.dupeZ(u8, p_dir);
        defer gpa.free(pd_z);
        const cd_z = try gpa.dupeZ(u8, cd);
        defer gpa.free(cd_z);
        if (std.c.symlink(pd_z, cd_z) != 0) return error.SymlinkFailed;
    }

    try desktop.migrateIn(gpa, base);
    _ = io;
}

fn ensureCurrentSavedIn(gpa: std.mem.Allocator, io: std.Io, base: []const u8) !void {
    const cj = try paths.claudeJsonIn(gpa, base);
    defer gpa.free(cj);
    const cd = try paths.claudeDirIn(gpa, base);
    defer gpa.free(cd);

    if (desktop.isSymlink(gpa, cj)) return;
    if (!desktop.pathExists(gpa, cj) and !desktop.pathExists(gpa, cd)) return;

    display.print("⚠️  Your current ~/.claude.json and ~/.claude/ are not managed by claudacity.\n", .{});
    display.print("Enter a name to save the current profile (or press Enter to skip): ", .{});

    var name_buf: [256]u8 = undefined;
    var n: usize = 0;
    while (n < name_buf.len - 1) {
        const ch_n = std.c.read(std.posix.STDIN_FILENO, name_buf[n .. n + 1].ptr, 1);
        if (ch_n <= 0) break;
        if (name_buf[n] == '\n') break;
        n += 1;
    }
    const line = std.mem.trim(u8, name_buf[0..n], " \t\r");
    if (line.len > 0) try cmdSave(gpa, io, line);
}

/// Linhas do picker: nome alinhado + tab + email (se houver). Caller libera.
/// One picker line per profile: the name, then the email, then its label (usage in
/// `claudacity pick`) when given. The first line is a header naming those columns.
pub fn pickerLinesIn(gpa: std.mem.Allocator, base: []const u8, profiles: []const []const u8, labels: ?[]const ?[]const u8) ![]const []const u8 {
    var width: usize = "profile".len;
    for (profiles) |p| width = @max(width, p.len);

    var lines: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (lines.items) |l| gpa.free(l);
        lines.deinit(gpa);
    }

    const emails = try gpa.alloc(?[]const u8, profiles.len);
    @memset(emails, null);
    defer {
        for (emails) |e| if (e) |s| gpa.free(s);
        gpa.free(emails);
    }
    var email_width: usize = 0;
    for (profiles, emails) |p, *e| {
        e.* = try profileJsonEmailIn(gpa, base, p);
        if (e.*) |s| email_width = @max(email_width, s.len);
    }
    if (email_width > 0) email_width = @max(email_width, "email".len);

    const header_email: ?[]const u8 = if (email_width > 0) "email" else null;
    const header_label: ?[]const u8 = if (labels != null) usage.PICKER_HEADER else null;
    const header = try pickerLine(gpa, "profile", width, header_email, email_width, header_label);
    defer gpa.free(header);
    try lines.append(gpa, try expandTabs(gpa, header));
    for (profiles, emails, 0..) |p, email, i| {
        const label: ?[]const u8 = if (labels) |ls| ls[i] else null;
        try lines.append(gpa, try pickerLine(gpa, p, width, email, email_width, label));
    }
    return lines.toOwnedSlice(gpa);
}

/// Tabs as spaces to the next 8-column stop, where sk puts them in a row: sk drops the tabs of a
/// header line, so the header is expanded up front to line up with the rows under it.
fn expandTabs(gpa: std.mem.Allocator, line: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (line) |ch| {
        if (ch == '\t') {
            try out.appendNTimes(gpa, ' ', 8 - out.items.len % 8);
        } else try out.append(gpa, ch);
    }
    return out.toOwnedSlice(gpa);
}

// name, email, then usage; emails are padded so the usage column lines up.
fn pickerLine(gpa: std.mem.Allocator, name: []const u8, width: usize, email: ?[]const u8, email_width: usize, label: ?[]const u8) ![]const u8 {
    var line: std.ArrayList(u8) = .empty;
    errdefer line.deinit(gpa);
    try line.appendSlice(gpa, name);
    if (label != null or email != null) try line.appendNTimes(gpa, ' ', width - name.len);
    if (email != null or (label != null and email_width > 0)) {
        const e = email orelse "";
        try line.print(gpa, "\t{s}", .{e});
        if (label != null) try line.appendNTimes(gpa, ' ', email_width - e.len);
    }
    if (label) |l| try line.print(gpa, "\t{s}", .{l});
    return line.toOwnedSlice(gpa);
}

/// Extrai o nome do perfil de uma linha escolhida no picker.
pub fn pickerName(line: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, line, '\t') orelse line.len;
    return std.mem.trim(u8, line[0..end], " \t\n\r");
}

/// The `--bind` value that moves the picker's cursor from the first profile to
/// `active`, one `down` per row (both sk and fzf run `load` once the list is
/// read); null when `active` is first or not listed.
pub fn cursorBind(gpa: std.mem.Allocator, profiles: []const []const u8, active: ?[]const u8) !?[]u8 {
    const cur = active orelse return null;
    const idx = for (profiles, 0..) |p, i| {
        if (std.mem.eql(u8, p, cur)) break i;
    } else return null;
    if (idx == 0) return null;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "load:");
    for (0..idx) |i| try out.appendSlice(gpa, if (i == 0) "down" else "+down");
    return try out.toOwnedSlice(gpa);
}

test "cursorBind moves to the current profile" {
    const gpa = std.testing.allocator;
    const profiles = [_][]const u8{ "dev1", "dev2", "primary" };
    const b = (try cursorBind(gpa, &profiles, "primary")).?;
    defer gpa.free(b);
    try std.testing.expectEqualStrings("load:down+down", b);
    try std.testing.expect((try cursorBind(gpa, &profiles, "dev1")) == null);
    try std.testing.expect((try cursorBind(gpa, &profiles, "gone")) == null);
    try std.testing.expect((try cursorBind(gpa, &profiles, null)) == null);
}

fn fuzzyPick(gpa: std.mem.Allocator, io: std.Io, base: []const u8, profiles: []const []const u8, labels: ?[]const ?[]const u8, prompt: []const u8, at_current: bool) !?[]const u8 {
    const cmd = try fuzzyCmd(gpa, io);
    defer gpa.free(cmd);

    // The cursor starts on the active profile, not the first row.
    const active = if (at_current) currentIn(gpa, base) catch null else null;
    defer if (active) |a| gpa.free(a);
    const bind = try cursorBind(gpa, profiles, active);
    defer if (bind) |b| gpa.free(b);

    const items = try pickerLinesIn(gpa, base, profiles, labels);
    defer {
        for (items) |l| gpa.free(l);
        gpa.free(items);
    }

    // The first item is the column header; --reverse draws it above the profiles instead of below.
    // stdin=pipe (we write items), stdout=pipe (we read selection), stderr=inherit (sk renders UI to terminal)
    var child = try std.process.spawn(io, .{
        .argv = if (bind) |b|
            &.{ cmd, "--ansi", "--reverse", "--header-lines", "1", "--prompt", prompt, "--bind", b }
        else
            &.{ cmd, "--ansi", "--reverse", "--header-lines", "1", "--prompt", prompt },
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .inherit,
    });

    if (child.stdin) |stdin| {
        for (items) |item| {
            _ = std.c.write(stdin.handle, item.ptr, item.len);
            _ = std.c.write(stdin.handle, "\n", 1);
        }
        _ = std.c.close(stdin.handle);
        child.stdin = null;
    }

    var buf: [4096]u8 = undefined;
    var total: usize = 0;
    if (child.stdout) |stdout| {
        while (total < buf.len) {
            const r = std.c.read(stdout.handle, buf[total..].ptr, buf.len - total);
            if (r <= 0) break;
            total += @intCast(r);
        }
        _ = std.c.close(stdout.handle);
        child.stdout = null;
    }

    _ = try child.wait(io);

    const chosen = pickerName(buf[0..total]);
    if (chosen.len == 0) return null;
    return try gpa.dupe(u8, chosen);
}

fn fuzzyCmd(gpa: std.mem.Allocator, io: std.Io) ![]const u8 {
    for (&[_][]const u8{ "sk", "fzf" }) |cmd| {
        const result = std.process.run(gpa, io, .{
            .argv = &.{ "which", cmd },
            .stdout_limit = .limited(1024),
            .stderr_limit = .limited(1024),
        }) catch continue;
        defer gpa.free(result.stdout);
        defer gpa.free(result.stderr);
        if (result.term == .exited and result.term.exited == 0) return gpa.dupe(u8, cmd);
    }
    display.err("sk or fzf not found. Install with: brew install sk");
    return error.FuzzyNotFound;
}

fn deleteTreeC(gpa: std.mem.Allocator, io: std.Io, path: []const u8) !void {
    const result = try std.process.run(gpa, io, .{
        .argv = &.{ "rm", "-rf", path },
        .stdout_limit = .limited(1024),
        .stderr_limit = .limited(1024),
    });
    gpa.free(result.stdout);
    gpa.free(result.stderr);
}

// ── Tests ─────────────────────────────────────────────────────────────────────

test "listIn dir vazio" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var base_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const base_len = try tmp.dir.realPath(std.Options.debug_io, &base_buf);
    const base = try alloc.dupe(u8, base_buf[0..base_len]);
    defer alloc.free(base);
    const result = try listIn(alloc, base);
    defer alloc.free(result);
    try std.testing.expectEqual(@as(usize, 0), result.len);
}

test "listIn encontra perfis ordenados" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var base_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const base_len = try tmp.dir.realPath(std.Options.debug_io, &base_buf);
    const base = try alloc.dupe(u8, base_buf[0..base_len]);
    defer alloc.free(base);

    for (&[_][]const u8{ "work", "personal" }) |name| {
        const p = try paths.profileJsonIn(alloc, base, name);
        defer alloc.free(p);
        const p_z = try alloc.dupeZ(u8, p);
        defer alloc.free(p_z);
        const fd = std.c.open(p_z, .{ .ACCMODE = .WRONLY, .CREAT = true }, @as(std.c.mode_t, 0o644));
        if (fd >= 0) _ = std.c.close(fd);
    }

    const result = try listIn(alloc, base);
    defer {
        for (result) |p| alloc.free(p);
        alloc.free(result);
    }
    try std.testing.expectEqual(@as(usize, 2), result.len);
    try std.testing.expectEqualStrings("personal", result[0]);
    try std.testing.expectEqualStrings("work", result[1]);
}

test "currentIn retorna null sem symlink" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var base_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const base_len = try tmp.dir.realPath(std.Options.debug_io, &base_buf);
    const base = try alloc.dupe(u8, base_buf[0..base_len]);
    defer alloc.free(base);
    try std.testing.expectEqual(@as(?[]const u8, null), try currentIn(alloc, base));
}

test "currentIn retorna perfil ativo" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var base_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const base_len = try tmp.dir.realPath(std.Options.debug_io, &base_buf);
    const base = try alloc.dupe(u8, base_buf[0..base_len]);
    defer alloc.free(base);

    const p_json = try paths.profileJsonIn(alloc, base, "work");
    defer alloc.free(p_json);
    const p_z = try alloc.dupeZ(u8, p_json);
    defer alloc.free(p_z);
    const fd = std.c.open(p_z, .{ .ACCMODE = .WRONLY, .CREAT = true }, @as(std.c.mode_t, 0o644));
    if (fd >= 0) _ = std.c.close(fd);

    const cj = try paths.claudeJsonIn(alloc, base);
    defer alloc.free(cj);
    const cj_z = try alloc.dupeZ(u8, cj);
    defer alloc.free(cj_z);
    if (std.c.symlink(p_z, cj_z) != 0) return error.SymlinkFailed;

    const result = try currentIn(alloc, base);
    defer if (result) |r| alloc.free(r);
    try std.testing.expectEqualStrings("work", result.?);
}

test "emailIn parseia email do JSON" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var base_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const base_len = try tmp.dir.realPath(std.Options.debug_io, &base_buf);
    const base = try alloc.dupe(u8, base_buf[0..base_len]);
    defer alloc.free(base);

    const path = try paths.profileJsonIn(alloc, base, "work");
    defer alloc.free(path);
    const path_z = try alloc.dupeZ(u8, path);
    defer alloc.free(path_z);
    const fd = std.c.open(path_z, .{ .ACCMODE = .WRONLY, .CREAT = true }, @as(std.c.mode_t, 0o644));
    if (fd >= 0) {
        const content = "{\"oauthAccount\":{\"emailAddress\":\"me@work.com\"}}";
        _ = std.c.write(fd, content.ptr, content.len);
        _ = std.c.close(fd);
    }

    const result = try profileJsonEmailIn(alloc, base, "work");
    defer if (result) |r| alloc.free(r);
    try std.testing.expectEqualStrings("me@work.com", result.?);
}

test "pickerLinesIn alinha nome e email" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var base_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const base_len = try tmp.dir.realPath(std.Options.debug_io, &base_buf);
    const base = try alloc.dupe(u8, base_buf[0..base_len]);
    defer alloc.free(base);

    const p = try paths.profileJsonIn(alloc, base, "work");
    defer alloc.free(p);
    const p_z = try alloc.dupeZ(u8, p);
    defer alloc.free(p_z);
    const fd = std.c.open(p_z, .{ .ACCMODE = .WRONLY, .CREAT = true }, @as(std.c.mode_t, 0o644));
    try std.testing.expect(fd >= 0);
    const json = "{\"oauthAccount\":{\"emailAddress\":\"me@work.com\"}}";
    _ = std.c.write(fd, json.ptr, json.len);
    _ = std.c.close(fd);

    const lines = try pickerLinesIn(alloc, base, &.{ "personal", "work" }, null);
    defer {
        for (lines) |l| alloc.free(l);
        alloc.free(lines);
    }
    try std.testing.expectEqualStrings("profile         email", lines[0]);
    try std.testing.expectEqualStrings("personal", lines[1]);
    try std.testing.expectEqualStrings("work    \tme@work.com", lines[2]);

    const labeled = try pickerLinesIn(alloc, base, &.{ "personal", "work" }, &.{ "7d 10%", null });
    defer {
        for (labeled) |l| alloc.free(l);
        alloc.free(labeled);
    }
    try std.testing.expectEqualStrings("profile         email           " ++ usage.PICKER_HEADER, labeled[0]);
    try std.testing.expectEqualStrings("personal\t           \t7d 10%", labeled[1]);
    try std.testing.expectEqualStrings("work    \tme@work.com", labeled[2]);

    const both = try pickerLinesIn(alloc, base, &.{"work"}, &.{"7d 10%"});
    defer {
        for (both) |l| alloc.free(l);
        alloc.free(both);
    }
    try std.testing.expectEqualStrings("work   \tme@work.com\t7d 10%", both[1]);
    try std.testing.expectEqualStrings("personal", pickerName(labeled[1]));
}

test "pickerName extrai nome da linha" {
    try std.testing.expectEqualStrings("work", pickerName("work    \tme@work.com\n"));
    try std.testing.expectEqualStrings("personal", pickerName("personal\n"));
    try std.testing.expectEqualStrings("", pickerName("\n"));
}

test "statusEmail reads the signed-in account from claude auth status" {
    const gpa = std.testing.allocator;
    const got = statusEmail(gpa, "{\"loggedIn\":true,\"email\":\"a@b.com\"}").?;
    defer gpa.free(got);
    try std.testing.expectEqualStrings("a@b.com", got);
    try std.testing.expect(statusEmail(gpa, "{\"loggedIn\":false}") == null);
    try std.testing.expect(statusEmail(gpa, "not json") == null);
}
