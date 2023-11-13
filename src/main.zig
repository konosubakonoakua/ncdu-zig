// SPDX-FileCopyrightText: 2021-2023 Yoran Heling <projects@yorhel.nl>
// SPDX-License-Identifier: MIT

pub const program_version = "2.3";

const std = @import("std");
const model = @import("model.zig");
const scan = @import("scan.zig");
const ui = @import("ui.zig");
const browser = @import("browser.zig");
const delete = @import("delete.zig");
const util = @import("util.zig");
const exclude = @import("exclude.zig");
const c = @cImport(@cInclude("locale.h"));

test "imports" {
    _ = model;
    _ = scan;
    _ = ui;
    _ = browser;
    _ = delete;
    _ = util;
    _ = exclude;
}

// "Custom" allocator that wraps the libc allocator and calls ui.oom() on error.
// This allocator never returns an error, it either succeeds or causes ncdu to quit.
// (Which means you'll find a lot of "catch unreachable" sprinkled through the code,
// they look scarier than they are)
fn wrapAlloc(_: *anyopaque, len: usize, ptr_alignment: u8, return_address: usize) ?[*]u8 {
    while (true) {
        if (std.heap.c_allocator.vtable.alloc(undefined, len, ptr_alignment, return_address)) |r|
            return r
        else {}
        ui.oom();
    }
}

pub const allocator = std.mem.Allocator{
    .ptr = undefined,
    .vtable = &.{
        .alloc = wrapAlloc,
        // AFAIK, all uses of resize() to grow an allocation will fall back to alloc() on failure.
        .resize = std.heap.c_allocator.vtable.resize,
        .free = std.heap.c_allocator.vtable.free,
    },
};


pub const config = struct {
    pub const SortCol = enum { name, blocks, size, items, mtime };
    pub const SortOrder = enum { asc, desc };

    pub var same_fs: bool = false;
    pub var extended: bool = false;
    pub var follow_symlinks: bool = false;
    pub var exclude_caches: bool = false;
    pub var exclude_kernfs: bool = false;
    pub var exclude_patterns: std.ArrayList([:0]const u8) = std.ArrayList([:0]const u8).init(allocator);

    pub var update_delay: u64 = 100*std.time.ns_per_ms;
    pub var scan_ui: ?enum { none, line, full } = null;
    pub var si: bool = false;
    pub var nc_tty: bool = false;
    pub var ui_color: enum { off, dark, darkbg } = .off;
    pub var thousands_sep: []const u8 = ",";

    pub var show_hidden: bool = true;
    pub var show_blocks: bool = true;
    pub var show_shared: enum { off, shared, unique } = .shared;
    pub var show_items: bool = false;
    pub var show_mtime: bool = false;
    pub var show_graph: bool = true;
    pub var show_percent: bool = false;
    pub var graph_style: enum { hash, half, eighth } = .hash;
    pub var sort_col: SortCol = .blocks;
    pub var sort_order: SortOrder = .desc;
    pub var sort_dirsfirst: bool = false;
    pub var sort_natural: bool = true;

    pub var imported: bool = false;
    pub var can_delete: ?bool = null;
    pub var can_shell: ?bool = null;
    pub var can_refresh: ?bool = null;
    pub var confirm_quit: bool = false;
    pub var confirm_delete: bool = true;
    pub var ignore_delete_errors: bool = false;
};

pub var state: enum { scan, browse, refresh, shell, delete } = .scan;

// Simple generic argument parser, supports getopt_long() style arguments.
const Args = struct {
    lst: []const [:0]const u8,
    short: ?[:0]const u8 = null, // Remainder after a short option, e.g. -x<stuff> (which may be either more short options or an argument)
    last: ?[]const u8 = null,
    last_arg: ?[:0]const u8 = null, // In the case of --option=<arg>
    shortbuf: [2]u8 = undefined,
    argsep: bool = false,

    const Self = @This();
    const Option = struct {
        opt: bool,
        val: []const u8,

        fn is(self: @This(), cmp: []const u8) bool {
            return self.opt and std.mem.eql(u8, self.val, cmp);
        }
    };

    fn init(lst: []const [:0]const u8) Self {
        return Self{ .lst = lst };
    }

    fn pop(self: *Self) ?[:0]const u8 {
        if (self.lst.len == 0) return null;
        defer self.lst = self.lst[1..];
        return self.lst[0];
    }

    fn shortopt(self: *Self, s: [:0]const u8) Option {
        self.shortbuf[0] = '-';
        self.shortbuf[1] = s[0];
        self.short = if (s.len > 1) s[1.. :0] else null;
        self.last = &self.shortbuf;
        return .{ .opt = true, .val = &self.shortbuf };
    }

    /// Return the next option or positional argument.
    /// 'opt' indicates whether it's an option or positional argument,
    /// 'val' will be either -x, --something or the argument.
    pub fn next(self: *Self) ?Option {
        if (self.last_arg != null) ui.die("Option '{s}' does not expect an argument.\n", .{ self.last.? });
        if (self.short) |s| return self.shortopt(s);
        const val = self.pop() orelse return null;
        if (self.argsep or val.len == 0 or val[0] != '-') return Option{ .opt = false, .val = val };
        if (val.len == 1) ui.die("Invalid option '-'.\n", .{});
        if (val.len == 2 and val[1] == '-') {
            self.argsep = true;
            return self.next();
        }
        if (val[1] == '-') {
            if (std.mem.indexOfScalar(u8, val, '=')) |sep| {
                if (sep == 2) ui.die("Invalid option '{s}'.\n", .{val});
                self.last_arg = val[sep+1.. :0];
                self.last = val[0..sep];
                return Option{ .opt = true, .val = self.last.? };
            }
            self.last = val;
            return Option{ .opt = true, .val = val };
        }
        return self.shortopt(val[1..:0]);
    }

    /// Returns the argument given to the last returned option. Dies with an error if no argument is provided.
    pub fn arg(self: *Self) [:0]const u8 {
        if (self.short) |a| {
            defer self.short = null;
            return a;
        }
        if (self.last_arg) |a| {
            defer self.last_arg = null;
            return a;
        }
        if (self.pop()) |o| return o;
        ui.die("Option '{s}' requires an argument.\n", .{ self.last.? });
    }
};

fn argConfig(args: *Args, opt: Args.Option) bool {
    if (opt.is("-q") or opt.is("--slow-ui-updates")) config.update_delay = 2*std.time.ns_per_s
    else if (opt.is("--fast-ui-updates")) config.update_delay = 100*std.time.ns_per_ms
    else if (opt.is("-x") or opt.is("--one-file-system")) config.same_fs = true
    else if (opt.is("--cross-file-system")) config.same_fs = false
    else if (opt.is("-e") or opt.is("--extended")) config.extended = true
    else if (opt.is("--no-extended")) config.extended = false
    else if (opt.is("-r") and !(config.can_delete orelse true)) config.can_shell = false
    else if (opt.is("-r")) config.can_delete = false
    else if (opt.is("--enable-shell")) config.can_shell = true
    else if (opt.is("--disable-shell")) config.can_shell = false
    else if (opt.is("--enable-delete")) config.can_delete = true
    else if (opt.is("--disable-delete")) config.can_delete = false
    else if (opt.is("--enable-refresh")) config.can_refresh = true
    else if (opt.is("--disable-refresh")) config.can_refresh = false
    else if (opt.is("--show-hidden")) config.show_hidden = true
    else if (opt.is("--hide-hidden")) config.show_hidden = false
    else if (opt.is("--show-itemcount")) config.show_items = true
    else if (opt.is("--hide-itemcount")) config.show_items = false
    else if (opt.is("--show-mtime")) config.show_mtime = true
    else if (opt.is("--hide-mtime")) config.show_mtime = false
    else if (opt.is("--show-graph")) config.show_graph = true
    else if (opt.is("--hide-graph")) config.show_graph = false
    else if (opt.is("--show-percent")) config.show_percent = true
    else if (opt.is("--hide-percent")) config.show_percent = false
    else if (opt.is("--group-directories-first")) config.sort_dirsfirst = true
    else if (opt.is("--no-group-directories-first")) config.sort_dirsfirst = false
    else if (opt.is("--enable-natsort")) config.sort_natural = true
    else if (opt.is("--disable-natsort")) config.sort_natural = false
    else if (opt.is("--graph-style")) {
        const val = args.arg();
        if (std.mem.eql(u8, val, "hash")) config.graph_style = .hash
        else if (std.mem.eql(u8, val, "half-block")) config.graph_style = .half
        else if (std.mem.eql(u8, val, "eighth-block") or std.mem.eql(u8, val, "eigth-block")) config.graph_style = .eighth
        else ui.die("Unknown --graph-style option: {s}.\n", .{val});
    } else if (opt.is("--sort")) {
        var val: []const u8 = args.arg();
        var ord: ?config.SortOrder = null;
        if (std.mem.endsWith(u8, val, "-asc")) {
            val = val[0..val.len-4];
            ord = .asc;
        } else if (std.mem.endsWith(u8, val, "-desc")) {
            val = val[0..val.len-5];
            ord = .desc;
        }
        if (std.mem.eql(u8, val, "name")) {
            config.sort_col = .name;
            config.sort_order = ord orelse .asc;
        } else if (std.mem.eql(u8, val, "disk-usage")) {
            config.sort_col = .blocks;
            config.sort_order = ord orelse .desc;
        } else if (std.mem.eql(u8, val, "apparent-size")) {
            config.sort_col = .size;
            config.sort_order = ord orelse .desc;
        } else if (std.mem.eql(u8, val, "itemcount")) {
            config.sort_col = .items;
            config.sort_order = ord orelse .desc;
        } else if (std.mem.eql(u8, val, "mtime")) {
            config.sort_col = .mtime;
            config.sort_order = ord orelse .asc;
        } else ui.die("Unknown --sort option: {s}.\n", .{val});
    } else if (opt.is("--shared-column")) {
        const val = args.arg();
        if (std.mem.eql(u8, val, "off")) config.show_shared = .off
        else if (std.mem.eql(u8, val, "shared")) config.show_shared = .shared
        else if (std.mem.eql(u8, val, "unique")) config.show_shared = .unique
        else ui.die("Unknown --shared-column option: {s}.\n", .{val});
    } else if (opt.is("--apparent-size")) config.show_blocks = false
    else if (opt.is("--disk-usage")) config.show_blocks = true
    else if (opt.is("-0")) config.scan_ui = .none
    else if (opt.is("-1")) config.scan_ui = .line
    else if (opt.is("-2")) config.scan_ui = .full
    else if (opt.is("--si")) config.si = true
    else if (opt.is("--no-si")) config.si = false
    else if (opt.is("-L") or opt.is("--follow-symlinks")) config.follow_symlinks = true
    else if (opt.is("--no-follow-symlinks")) config.follow_symlinks = false
    else if (opt.is("--exclude")) exclude.addPattern(args.arg())
    else if (opt.is("-X") or opt.is("--exclude-from")) {
        const arg = args.arg();
        readExcludeFile(arg) catch |e| ui.die("Error reading excludes from {s}: {s}.\n", .{ arg, ui.errorString(e) });
    } else if (opt.is("--exclude-caches")) config.exclude_caches = true
    else if (opt.is("--include-caches")) config.exclude_caches = false
    else if (opt.is("--exclude-kernfs")) config.exclude_kernfs = true
    else if (opt.is("--include-kernfs")) config.exclude_kernfs = false
    else if (opt.is("--confirm-quit")) config.confirm_quit = true
    else if (opt.is("--no-confirm-quit")) config.confirm_quit = false
    else if (opt.is("--confirm-delete")) config.confirm_delete = true
    else if (opt.is("--no-confirm-delete")) config.confirm_delete = false
    else if (opt.is("--color")) {
        const val = args.arg();
        if (std.mem.eql(u8, val, "off")) config.ui_color = .off
        else if (std.mem.eql(u8, val, "dark")) config.ui_color = .dark
        else if (std.mem.eql(u8, val, "dark-bg")) config.ui_color = .darkbg
        else ui.die("Unknown --color option: {s}.\n", .{val});
    } else return false;
    return true;
}

fn tryReadArgsFile(path: [:0]const u8) void {
    var f = std.fs.cwd().openFileZ(path, .{}) catch |e| switch (e) {
        error.FileNotFound => return,
        error.NotDir => return,
        else => ui.die("Error opening {s}: {s}\nRun with --ignore-config to skip reading config files.\n", .{ path, ui.errorString(e) }),
    };
    defer f.close();

    var arglist = std.ArrayList([:0]const u8).init(allocator);
    
    var rd_ = std.io.bufferedReader(f.reader());
    const rd = rd_.reader();
    
    var line_buf: [4096]u8 = undefined;
    var line_fbs = std.io.fixedBufferStream(&line_buf);
    const line_writer = line_fbs.writer();

    while (true) : (line_fbs.reset()) {
        rd.streamUntilDelimiter(line_writer, '\n', line_buf.len) catch |err| switch (err) {
            error.EndOfStream => if (line_fbs.getPos() catch unreachable == 0) break,
            else => |e| ui.die("Error reading from {s}: {s}\nRun with --ignore-config to skip reading config files.\n", .{ path, ui.errorString(e) }),
        };
        var line_ = line_fbs.getWritten();

        var line = std.mem.trim(u8, line_, &std.ascii.whitespace);
        if (line.len == 0 or line[0] == '#') continue;
        if (std.mem.indexOfAny(u8, line, " \t=")) |i| {
            arglist.append(allocator.dupeZ(u8, line[0..i]) catch unreachable) catch unreachable;
            line = std.mem.trimLeft(u8, line[i+1..], &std.ascii.whitespace);
        }
        arglist.append(allocator.dupeZ(u8, line) catch unreachable) catch unreachable;
    }

    var args = Args.init(arglist.items);
    while (args.next()) |opt| {
        if (!argConfig(&args, opt))
            ui.die("Unrecognized option in config file '{s}': {s}.\nRun with --ignore-config to skip reading config files.\n", .{path, opt.val});
    }
    for (arglist.items) |i| allocator.free(i);
    arglist.deinit();
}

fn version() noreturn {
    const stdout = std.io.getStdOut();
    stdout.writeAll("ncdu " ++ program_version ++ "\n") catch {};
    std.process.exit(0);
}

fn help() noreturn {
    const stdout = std.io.getStdOut();
    stdout.writeAll(
    \\ncdu <options> <directory>
    \\
    \\Options:
    \\  -h,--help                  This help message
    \\  -q                         Quiet mode, refresh interval 2 seconds
    \\  -v,-V,--version            Print version
    \\  -x                         Same filesystem
    \\  -e                         Enable extended information
    \\  -r                         Read only
    \\  -o FILE                    Export scanned directory to FILE
    \\  -f FILE                    Import scanned directory from FILE
    \\  -0,-1,-2                   UI to use when scanning (0=none,2=full ncurses)
    \\  --si                       Use base 10 (SI) prefixes instead of base 2
    \\  --exclude PATTERN          Exclude files that match PATTERN
    \\  -X, --exclude-from FILE    Exclude files that match any pattern in FILE
    \\  -L, --follow-symlinks      Follow symbolic links (excluding directories)
    \\  --exclude-caches           Exclude directories containing CACHEDIR.TAG
    \\  --exclude-kernfs           Exclude Linux pseudo filesystems (procfs,sysfs,cgroup,...)
    \\  --confirm-quit             Confirm quitting ncdu
    \\  --color SCHEME             Set color scheme (off/dark/dark-bg)
    \\  --ignore-config            Don't load config files
    \\
    \\Refer to `man ncdu` for the full list of options.
    \\
    ) catch {};
    std.process.exit(0);
}


fn spawnShell() void {
    ui.deinit();
    defer ui.init();

    var path = std.ArrayList(u8).init(allocator);
    defer path.deinit();
    browser.dir_parent.fmtPath(true, &path);

    var env = std.process.getEnvMap(allocator) catch unreachable;
    defer env.deinit();
    // NCDU_LEVEL can only count to 9, keeps the implementation simple.
    if (env.get("NCDU_LEVEL")) |l|
        env.put("NCDU_LEVEL", if (l.len == 0) "1" else switch (l[0]) {
            '0'...'8' => |d| &[1] u8{d+1},
            '9' => "9",
            else => "1"
        }) catch unreachable
    else
        env.put("NCDU_LEVEL", "1") catch unreachable;

    const shell = std.os.getenvZ("NCDU_SHELL") orelse std.os.getenvZ("SHELL") orelse "/bin/sh";
    var child = std.process.Child.init(&.{shell}, allocator);
    child.cwd = path.items;
    child.env_map = &env;

    const stdin = std.io.getStdIn();
    const stderr = std.io.getStdErr();
    const term = child.spawnAndWait() catch |e| blk: {
        stderr.writer().print(
            "Error spawning shell: {s}\n\nPress enter to continue.\n",
            .{ ui.errorString(e) }
        ) catch {};
        stdin.reader().skipUntilDelimiterOrEof('\n') catch unreachable;
        break :blk std.process.Child.Term{ .Exited = 0 };
    };
    if (term != .Exited) {
        const n = switch (term) {
            .Exited  => "status",
            .Signal  => "signal",
            .Stopped => "stopped",
            .Unknown => "unknown",
        };
        const v = switch (term) {
            .Exited  => |v| v,
            .Signal  => |v| v,
            .Stopped => |v| v,
            .Unknown => |v| v,
        };
        stderr.writer().print(
            "Shell returned with {s} code {}.\n\nPress enter to continue.\n", .{ n, v }
        ) catch {};
        stdin.reader().skipUntilDelimiterOrEof('\n') catch unreachable;
    }
}


fn readExcludeFile(path: [:0]const u8) !void {
    const f = try std.fs.cwd().openFileZ(path, .{});
    defer f.close();

    var rd_ = std.io.bufferedReader(f.reader());
    const rd = rd_.reader();

    var line_buf: [4096]u8 = undefined;
    var line_fbs = std.io.fixedBufferStream(&line_buf);
    const line_writer = line_fbs.writer();

    while (true) : (line_fbs.reset()) {
        rd.streamUntilDelimiter(line_writer, '\n', line_buf.len) catch |err| switch (err) {
            error.EndOfStream => if (line_fbs.getPos() catch unreachable == 0) break,
            else => |e| return e,
        };
        const line = line_fbs.getWritten();
        if (line.len > 0)
            exclude.addPattern(line);
    }
}

pub fn main() void {
    // Grab thousands_sep from the current C locale.
    _ = c.setlocale(c.LC_ALL, "");
    if (c.localeconv()) |locale| {
        if (locale.*.thousands_sep) |sep| {
            const span = std.mem.sliceTo(sep, 0);
            if (span.len > 0)
                config.thousands_sep = span;
        }
    }
    if (std.os.getenvZ("NO_COLOR") == null) config.ui_color = .darkbg;

    const loadConf = blk: {
        var args = std.process.ArgIteratorPosix.init();
        while (args.next()) |a|
            if (std.mem.eql(u8, a, "--ignore-config"))
                break :blk false;
        break :blk true;
    };

    if (loadConf) {
        tryReadArgsFile("/etc/ncdu.conf");

        if (std.os.getenvZ("XDG_CONFIG_HOME")) |p| {
            var path = std.fs.path.joinZ(allocator, &.{p, "ncdu", "config"}) catch unreachable;
            defer allocator.free(path);
            tryReadArgsFile(path);
        } else if (std.os.getenvZ("HOME")) |p| {
            var path = std.fs.path.joinZ(allocator, &.{p, ".config", "ncdu", "config"}) catch unreachable;
            defer allocator.free(path);
            tryReadArgsFile(path);
        }
    }

    var scan_dir: ?[]const u8 = null;
    var import_file: ?[:0]const u8 = null;
    var export_file: ?[:0]const u8 = null;
    {
        var arglist = std.process.argsAlloc(allocator) catch unreachable;
        defer std.process.argsFree(allocator, arglist);
        var args = Args.init(arglist);
        _ = args.next(); // program name
        while (args.next()) |opt| {
            if (!opt.opt) {
                // XXX: ncdu 1.x doesn't error, it just silently ignores all but the last argument.
                if (scan_dir != null) ui.die("Multiple directories given, see ncdu -h for help.\n", .{});
                scan_dir = allocator.dupeZ(u8, opt.val) catch unreachable;
                continue;
            }
            if (opt.is("-h") or opt.is("-?") or opt.is("--help")) help()
            else if (opt.is("-v") or opt.is("-V") or opt.is("--version")) version()
            else if (opt.is("-o") and export_file != null) ui.die("The -o flag can only be given once.\n", .{})
            else if (opt.is("-o")) export_file = allocator.dupeZ(u8, args.arg()) catch unreachable
            else if (opt.is("-f") and import_file != null) ui.die("The -f flag can only be given once.\n", .{})
            else if (opt.is("-f")) import_file = allocator.dupeZ(u8, args.arg()) catch unreachable
            else if (opt.is("--ignore-config")) {}
            else if (argConfig(&args, opt)) {}
            else ui.die("Unrecognized option '{s}'.\n", .{opt.val});
        }
    }

    if (@import("builtin").os.tag != .linux and config.exclude_kernfs)
        ui.die("The --exclude-kernfs flag is currently only supported on Linux.\n", .{});

    const stdin = std.io.getStdIn();
    const stdout = std.io.getStdOut();
    const out_tty = stdout.isTty();
    const in_tty = stdin.isTty();
    if (config.scan_ui == null) {
        if (export_file) |f| {
            if (!out_tty or std.mem.eql(u8, f, "-")) config.scan_ui = .none
            else config.scan_ui = .line;
        } else config.scan_ui = .full;
    }
    if (!in_tty and import_file == null and export_file == null)
        ui.die("Standard input is not a TTY. Did you mean to import a file using '-f -'?\n", .{});
    config.nc_tty = !in_tty or (if (export_file) |f| std.mem.eql(u8, f, "-") else false);

    event_delay_timer = std.time.Timer.start() catch unreachable;
    defer ui.deinit();

    var out_file = if (export_file) |f| (
        if (std.mem.eql(u8, f, "-")) stdout
        else std.fs.cwd().createFileZ(f, .{})
             catch |e| ui.die("Error opening export file: {s}.\n", .{ui.errorString(e)})
    ) else null;

    if (import_file) |f| {
        scan.importRoot(f, out_file);
        config.imported = true;
    } else scan.scanRoot(scan_dir orelse ".", out_file)
           catch |e| ui.die("Error opening directory: {s}.\n", .{ui.errorString(e)});
    if (out_file != null) return;

    config.can_shell = config.can_shell orelse !config.imported;
    config.can_delete = config.can_delete orelse !config.imported;
    config.can_refresh = config.can_refresh orelse !config.imported;

    config.scan_ui = .full; // in case we're refreshing from the UI, always in full mode.
    ui.init();
    state = .browse;
    browser.dir_parent = model.root;
    browser.loadDir(null);

    while (true) {
        switch (state) {
            .refresh => {
                scan.scan();
                state = .browse;
                browser.loadDir(null);
            },
            .shell => {
                spawnShell();
                state = .browse;
            },
            .delete => {
                const next = delete.delete();
                state = .browse;
                browser.loadDir(next);
            },
            else => handleEvent(true, false)
        }
    }
}

var event_delay_timer: std.time.Timer = undefined;

// Draw the screen and handle the next input event.
// In non-blocking mode, screen drawing is rate-limited to keep this function fast.
pub fn handleEvent(block: bool, force_draw: bool) void {
    if (block or force_draw or event_delay_timer.read() > config.update_delay) {
        if (ui.inited) _ = ui.c.erase();
        switch (state) {
            .scan, .refresh => scan.draw(),
            .browse => browser.draw(),
            .delete => delete.draw(),
            .shell => unreachable,
        }
        if (ui.inited) _ = ui.c.refresh();
        event_delay_timer.reset();
    }
    if (!ui.inited) {
        std.debug.assert(!block);
        return;
    }

    var firstblock = block;
    while (true) {
        var ch = ui.getch(firstblock);
        if (ch == 0) return;
        if (ch == -1) return handleEvent(firstblock, true);
        switch (state) {
            .scan, .refresh => scan.keyInput(ch),
            .browse => browser.keyInput(ch),
            .delete => delete.keyInput(ch),
            .shell => unreachable,
        }
        firstblock = false;
    }
}

test "argument parser" {
    const lst = [_][:0]const u8{ "a", "-abcd=e", "--opt1=arg1", "--opt2", "arg2", "-x", "foo", "", "--", "--arg", "", "-", };
    const T = struct {
        a: Args,
        fn opt(self: *@This(), isopt: bool, val: []const u8) !void {
            const o = self.a.next().?;
            try std.testing.expectEqual(isopt, o.opt);
            try std.testing.expectEqualStrings(val, o.val);
            try std.testing.expectEqual(o.is(val), isopt);
        }
        fn arg(self: *@This(), val: []const u8) !void {
            try std.testing.expectEqualStrings(val, self.a.arg());
        }
    };
    var t = T{ .a = Args.init(&lst) };
    try t.opt(false, "a");
    try t.opt(true, "-a");
    try t.opt(true, "-b");
    try t.arg("cd=e");
    try t.opt(true, "--opt1");
    try t.arg("arg1");
    try t.opt(true, "--opt2");
    try t.arg("arg2");
    try t.opt(true, "-x");
    try t.arg("foo");
    try t.opt(false, "");
    try t.opt(false, "--arg");
    try t.opt(false, "");
    try t.opt(false, "-");
    try std.testing.expectEqual(t.a.next(), null);
}
