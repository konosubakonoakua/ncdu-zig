// SPDX-FileCopyrightText: 2021-2023 Yoran Heling <projects@yorhel.nl>
// SPDX-License-Identifier: MIT

const std = @import("std");
const main = @import("main.zig");
const model = @import("model.zig");
const ui = @import("ui.zig");
const util = @import("util.zig");
const exclude = @import("exclude.zig");
const c_statfs = @cImport(@cInclude("sys/vfs.h"));


// Concise stat struct for fields we're interested in, with the types used by the model.
const Stat = struct {
    blocks: model.Blocks = 0,
    size: u64 = 0,
    dev: u64 = 0,
    ino: u64 = 0,
    nlink: u31 = 0,
    hlinkc: bool = false,
    dir: bool = false,
    reg: bool = true,
    symlink: bool = false,
    ext: model.Ext = .{},

    fn clamp(comptime T: type, comptime field: anytype, x: anytype) std.meta.fieldInfo(T, field).type {
        return util.castClamp(std.meta.fieldInfo(T, field).type, x);
    }

    fn truncate(comptime T: type, comptime field: anytype, x: anytype) std.meta.fieldInfo(T, field).type {
        return util.castTruncate(std.meta.fieldInfo(T, field).type, x);
    }

    fn read(parent: std.fs.Dir, name: [:0]const u8, follow: bool) !Stat {
        const stat = try std.os.fstatatZ(parent.fd, name, if (follow) 0 else std.os.AT.SYMLINK_NOFOLLOW);
        return Stat{
            .blocks = clamp(Stat, .blocks, stat.blocks),
            .size = clamp(Stat, .size, stat.size),
            .dev = truncate(Stat, .dev, stat.dev),
            .ino = truncate(Stat, .ino, stat.ino),
            .nlink = clamp(Stat, .nlink, stat.nlink),
            .hlinkc = stat.nlink > 1 and !std.os.system.S.ISDIR(stat.mode),
            .dir = std.os.system.S.ISDIR(stat.mode),
            .reg = std.os.system.S.ISREG(stat.mode),
            .symlink = std.os.system.S.ISLNK(stat.mode),
            .ext = .{
                .mtime = clamp(model.Ext, .mtime, stat.mtime().tv_sec),
                .uid = truncate(model.Ext, .uid, stat.uid),
                .gid = truncate(model.Ext, .gid, stat.gid),
                .mode = truncate(model.Ext, .mode, stat.mode),
            },
        };
    }
};

var kernfs_cache: std.AutoHashMap(u64,bool) = std.AutoHashMap(u64,bool).init(main.allocator);

// This function only works on Linux
fn isKernfs(dir: std.fs.Dir, dev: u64) bool {
    if (kernfs_cache.get(dev)) |e| return e;
    var buf: c_statfs.struct_statfs = undefined;
    if (c_statfs.fstatfs(dir.fd, &buf) != 0) return false; // silently ignoring errors isn't too nice.
    const iskern = switch (util.castTruncate(u32, buf.f_type)) {
        // These numbers are documented in the Linux 'statfs(2)' man page, so I assume they're stable.
        0x42494e4d, // BINFMTFS_MAGIC
        0xcafe4a11, // BPF_FS_MAGIC
        0x27e0eb, // CGROUP_SUPER_MAGIC
        0x63677270, // CGROUP2_SUPER_MAGIC
        0x64626720, // DEBUGFS_MAGIC
        0x1cd1, // DEVPTS_SUPER_MAGIC
        0x9fa0, // PROC_SUPER_MAGIC
        0x6165676c, // PSTOREFS_MAGIC
        0x73636673, // SECURITYFS_MAGIC
        0xf97cff8c, // SELINUX_MAGIC
        0x62656572, // SYSFS_MAGIC
        0x74726163 // TRACEFS_MAGIC
        => true,
        else => false,
    };
    kernfs_cache.put(dev, iskern) catch {};
    return iskern;
}

// Output a JSON string.
// Could use std.json.stringify(), but that implementation is "correct" in that
// it refuses to encode non-UTF8 slices as strings. Ncdu dumps aren't valid
// JSON if we have non-UTF8 filenames, such is life...
fn writeJsonString(wr: anytype, s: []const u8) !void {
    try wr.writeByte('"');
    for (s) |ch| {
        switch (ch) {
            '\n' => try wr.writeAll("\\n"),
            '\r' => try wr.writeAll("\\r"),
            0x8  => try wr.writeAll("\\b"),
            '\t' => try wr.writeAll("\\t"),
            0xC  => try wr.writeAll("\\f"),
            '\\' => try wr.writeAll("\\\\"),
            '"'  => try wr.writeAll("\\\""),
            0...7, 0xB, 0xE...0x1F, 127 => try wr.print("\\u00{x:0>2}", .{ch}),
            else => try wr.writeByte(ch)
        }
    }
    try wr.writeByte('"');
}

// A ScanDir represents an in-memory directory listing (i.e. model.Dir) where
// entries read from disk can be merged into, without doing an O(1) lookup for
// each entry.
const ScanDir = struct {
    dir: *model.Dir,

    // Lookup table for name -> *entry.
    // null is never stored in the table, but instead used pass a name string
    // as out-of-band argument for lookups.
    entries: Map,
    const Map = std.HashMap(?*model.Entry, void, HashContext, 80);

    const HashContext = struct {
        cmp: []const u8 = "",

        pub fn hash(self: @This(), v: ?*model.Entry) u64 {
            return std.hash.Wyhash.hash(0, if (v) |e| @as([]const u8, e.name()) else self.cmp);
        }

        pub fn eql(self: @This(), ap: ?*model.Entry, bp: ?*model.Entry) bool {
            if (ap == bp) return true;
            const a = if (ap) |e| @as([]const u8, e.name()) else self.cmp;
            const b = if (bp) |e| @as([]const u8, e.name()) else self.cmp;
            return std.mem.eql(u8, a, b);
        }
    };

    const Self = @This();

    fn init(dir: *model.Dir) Self {
        var self = Self{
            .dir = dir,
            .entries = Map.initContext(main.allocator, HashContext{}),
        };

        var count: Map.Size = 0;
        var it = dir.sub;
        while (it) |e| : (it = e.next) count += 1;
        self.entries.ensureUnusedCapacity(count) catch unreachable;

        it = dir.sub;
        while (it) |e| : (it = e.next)
            self.entries.putAssumeCapacity(e, @as(void,undefined));
        return self;
    }

    fn addSpecial(self: *Self, name: []const u8, t: Context.Special) void {
        var e = blk: {
            if (self.entries.getEntryAdapted(@as(?*model.Entry,null), HashContext{ .cmp = name })) |entry| {
                // XXX: If the type doesn't match, we could always do an
                // in-place conversion to a File entry. That's more efficient,
                // but also more code. I don't expect this to happen often.
                var e = entry.key_ptr.*.?;
                if (e.pack.etype == .file) {
                    if (e.size > 0 or e.pack.blocks > 0) {
                        e.delStats(self.dir);
                        e.size = 0;
                        e.pack.blocks = 0;
                        e.addStats(self.dir, 0);
                    }
                    e.file().?.pack = .{};
                    _ = self.entries.removeAdapted(@as(?*model.Entry,null), HashContext{ .cmp = name });
                    break :blk e;
                } else e.delStatsRec(self.dir);
            }
            var e = model.Entry.create(.file, false, name);
            e.next = self.dir.sub;
            self.dir.sub = e;
            e.addStats(self.dir, 0);
            break :blk e;
        };
        var f = e.file().?;
        switch (t) {
            .err => e.setErr(self.dir),
            .other_fs => f.pack.other_fs = true,
            .kernfs => f.pack.kernfs = true,
            .excluded => f.pack.excluded = true,
        }
    }

    fn addStat(self: *Self, name: []const u8, stat: *Stat) *model.Entry {
        const etype = if (stat.dir) model.EType.dir
                      else if (stat.hlinkc) model.EType.link
                      else model.EType.file;
        var e = blk: {
            if (self.entries.getEntryAdapted(@as(?*model.Entry,null), HashContext{ .cmp = name })) |entry| {
                // XXX: In-place conversion may also be possible here.
                var e = entry.key_ptr.*.?;
                // changes of dev/ino affect hard link counting in a way we can't simply merge.
                const samedev = if (e.dir()) |d| d.pack.dev == model.devices.getId(stat.dev) else true;
                const sameino = if (e.link()) |l| l.ino == stat.ino else true;
                if (e.pack.etype == etype and samedev and sameino) {
                    _ = self.entries.removeAdapted(@as(?*model.Entry,null), HashContext{ .cmp = name });
                    break :blk e;
                } else e.delStatsRec(self.dir);
            }
            var e = model.Entry.create(etype, main.config.extended, name);
            e.next = self.dir.sub;
            self.dir.sub = e;
            break :blk e;
        };
        // Ignore the new size/blocks field for directories, as we don't know
        // what the original values were without calling delStats() on the
        // entire subtree, which, in turn, would break all shared hardlink
        // sizes. The current approach may result in incorrect sizes after
        // refresh, but I expect the difference to be fairly minor.
        if (!(e.pack.etype == .dir and e.pack.counted) and (e.pack.blocks != stat.blocks or e.size != stat.size)) {
            e.delStats(self.dir);
            e.pack.blocks = stat.blocks;
            e.size = stat.size;
        }
        if (e.dir()) |d| {
            d.parent = self.dir;
            d.pack.dev = model.devices.getId(stat.dev);
        }
        if (e.file()) |f| f.pack = .{ .notreg = !stat.dir and !stat.reg };
        if (e.link()) |l| l.ino = stat.ino;
        if (e.ext()) |ext| {
            if (ext.mtime > stat.ext.mtime)
                stat.ext.mtime = ext.mtime;
            ext.* = stat.ext;
        }

        e.addStats(self.dir, stat.nlink);
        return e;
    }

    fn final(self: *Self) void {
        if (self.entries.count() == 0) // optimization for the common case
            return;
        var it = &self.dir.sub;
        while (it.*) |e| {
            if (self.entries.contains(e)) {
                e.delStatsRec(self.dir);
                it.* = e.next;
            } else
                it = &e.next;
        }
    }

    fn deinit(self: *Self) void {
        self.entries.deinit();
    }
};

// Scan/import context. Entries are added in roughly the following way:
//
//   ctx.pushPath(name)
//   ctx.stat = ..;
//   ctx.addSpecial() or ctx.addStat()
//   if (ctx.stat.dir) {
//      // repeat top-level steps for files in dir, recursively.
//   }
//   ctx.popPath();
//
const Context = struct {
    // When scanning to RAM
    parents: ?std.ArrayList(ScanDir) = null,
    // When scanning to a file
    wr: ?*Writer = null,

    path: std.ArrayList(u8) = std.ArrayList(u8).init(main.allocator),
    path_indices: std.ArrayList(usize) = std.ArrayList(usize).init(main.allocator),
    items_seen: u32 = 0,

    // 0-terminated name of the top entry, points into 'path', invalid after popPath().
    // This is a workaround to Zig's directory iterator not returning a [:0]const u8.
    name: [:0]const u8 = undefined,

    last_error: ?[:0]u8 = null,
    fatal_error: ?anyerror = null,

    stat: Stat = undefined,

    const Writer = std.io.BufferedWriter(4096, std.fs.File.Writer);
    const Self = @This();

    fn writeErr(e: anyerror) noreturn {
        ui.die("Error writing to file: {s}.\n", .{ ui.errorString(e) });
    }

    fn initFile(out: std.fs.File) *Self {
        var buf = main.allocator.create(Writer) catch unreachable;
        errdefer main.allocator.destroy(buf);
        buf.* = std.io.bufferedWriter(out.writer());
        var wr = buf.writer();
        wr.writeAll("[1,2,{\"progname\":\"ncdu\",\"progver\":\"" ++ main.program_version ++ "\",\"timestamp\":") catch |e| writeErr(e);
        wr.print("{d}", .{std.time.timestamp()}) catch |e| writeErr(e);
        wr.writeByte('}') catch |e| writeErr(e);

        var self = main.allocator.create(Self) catch unreachable;
        self.* = .{ .wr = buf };
        return self;
    }

    fn initMem(dir: ?*model.Dir) *Self {
        var self = main.allocator.create(Self) catch unreachable;
        self.* = .{ .parents = std.ArrayList(ScanDir).init(main.allocator) };
        if (dir) |d| self.parents.?.append(ScanDir.init(d)) catch unreachable;
        return self;
    }

    fn final(self: *Self) void {
        if (self.parents) |_| {
            counting_hardlinks = true;
            defer counting_hardlinks = false;
            main.handleEvent(false, true);
            model.inodes.addAllStats();
        }
        if (self.wr) |wr| {
            wr.writer().writeByte(']') catch |e| writeErr(e);
            wr.flush() catch |e| writeErr(e);
        }
    }

    // Add the name of the file/dir entry we're currently inspecting
    fn pushPath(self: *Self, name: []const u8) void {
        self.path_indices.append(self.path.items.len) catch unreachable;
        if (self.path.items.len > 1) self.path.append('/') catch unreachable;
        const start = self.path.items.len;
        self.path.appendSlice(name) catch unreachable;

        self.path.append(0) catch unreachable;
        self.name = self.path.items[start..self.path.items.len-1:0];
        self.path.items.len -= 1;
    }

    fn popPath(self: *Self) void {
        self.path.items.len = self.path_indices.pop();

        if (self.stat.dir) {
            if (self.parents) |*p| {
                if (p.items.len > 0) {
                    var d = p.pop();
                    d.final();
                    d.deinit();
                }
            }
            if (self.wr) |w| w.writer().writeByte(']') catch |e| writeErr(e);
        } else
            self.stat.dir = true; // repeated popPath()s mean we're closing parent dirs.
    }

    fn pathZ(self: *Self) [:0]const u8 {
        return util.arrayListBufZ(&self.path);
    }

    // Set a flag to indicate that there was an error listing file entries in the current directory.
    // (Such errors are silently ignored when exporting to a file, as the directory metadata has already been written)
    fn setDirlistError(self: *Self) void {
        if (self.parents) |*p| p.items[p.items.len-1].dir.entry.setErr(p.items[p.items.len-1].dir);
    }

    const Special = enum { err, other_fs, kernfs, excluded };

    fn writeSpecial(self: *Self, w: anytype, t: Special) !void {
        try w.writeAll(",\n");
        if (self.stat.dir) try w.writeByte('[');
        try w.writeAll("{\"name\":");
        try writeJsonString(w, self.name);
        switch (t) {
            .err => try w.writeAll(",\"read_error\":true"),
            .other_fs => try w.writeAll(",\"excluded\":\"othfs\""),
            .kernfs => try w.writeAll(",\"excluded\":\"kernfs\""),
            .excluded => try w.writeAll(",\"excluded\":\"pattern\""),
        }
        try w.writeByte('}');
        if (self.stat.dir) try w.writeByte(']');
    }

    // Insert the current path as a special entry (i.e. a file/dir that is not counted)
    // Ignores self.stat except for the 'dir' option.
    fn addSpecial(self: *Self, t: Special) void {
        if (t == .err) {
            if (self.last_error) |p| main.allocator.free(p);
            self.last_error = main.allocator.dupeZ(u8, self.path.items) catch unreachable;
        }

        if (self.parents) |*p|
            p.items[p.items.len-1].addSpecial(self.name, t)
        else if (self.wr) |wr|
            self.writeSpecial(wr.writer(), t) catch |e| writeErr(e);

        self.stat.dir = false; // So that popPath() doesn't consider this as leaving a dir.
        self.items_seen += 1;
    }

    fn writeStat(self: *Self, w: anytype, dir_dev: u64) !void {
        try w.writeAll(",\n");
        if (self.stat.dir) try w.writeByte('[');
        try w.writeAll("{\"name\":");
        try writeJsonString(w, self.name);
        if (self.stat.size > 0) try w.print(",\"asize\":{d}", .{ self.stat.size });
        if (self.stat.blocks > 0) try w.print(",\"dsize\":{d}", .{ util.blocksToSize(self.stat.blocks) });
        if (self.stat.dir and self.stat.dev != dir_dev) try w.print(",\"dev\":{d}", .{ self.stat.dev });
        if (self.stat.hlinkc) try w.print(",\"ino\":{d},\"hlnkc\":true,\"nlink\":{d}", .{ self.stat.ino, self.stat.nlink });
        if (!self.stat.dir and !self.stat.reg) try w.writeAll(",\"notreg\":true");
        if (main.config.extended)
            try w.print(",\"uid\":{d},\"gid\":{d},\"mode\":{d},\"mtime\":{d}",
                .{ self.stat.ext.uid, self.stat.ext.gid, self.stat.ext.mode, self.stat.ext.mtime });
        try w.writeByte('}');
    }

    // Insert current path as a counted file/dir/hardlink, with information from self.stat
    fn addStat(self: *Self, dir_dev: u64) void {
        if (self.parents) |*p| {
            var e = if (p.items.len == 0) blk: {
                // Root entry
                var e = model.Entry.create(.dir, main.config.extended, self.name);
                e.pack.blocks = self.stat.blocks;
                e.size = self.stat.size;
                if (e.ext()) |ext| ext.* = self.stat.ext;
                model.root = e.dir().?;
                model.root.pack.dev = model.devices.getId(self.stat.dev);
                break :blk e;
            } else
                p.items[p.items.len-1].addStat(self.name, &self.stat);

            if (e.dir()) |d| // Enter the directory
                p.append(ScanDir.init(d)) catch unreachable;

        } else if (self.wr) |wr|
            self.writeStat(wr.writer(), dir_dev) catch |e| writeErr(e);

        self.items_seen += 1;
    }

    fn deinit(self: *Self) void {
        if (self.last_error) |p| main.allocator.free(p);
        if (self.parents) |*p| {
            for (p.items) |*i| i.deinit();
            p.deinit();
        }
        if (self.wr) |p| main.allocator.destroy(p);
        self.path.deinit();
        self.path_indices.deinit();
        main.allocator.destroy(self);
    }
};

// Context that is currently being used for scanning.
var active_context: *Context = undefined;

// Read and index entries of the given dir.
fn scanDir(ctx: *Context, pat: *const exclude.Patterns, dir: std.fs.IterableDir, dir_dev: u64) void {
    var it = main.allocator.create(std.fs.IterableDir.Iterator) catch unreachable;
    defer main.allocator.destroy(it);
    it.* = dir.iterate();
    while(true) {
        const entry = it.next() catch {
            ctx.setDirlistError();
            return;
        } orelse break;

        ctx.stat.dir = false;
        ctx.pushPath(entry.name);
        defer ctx.popPath();
        main.handleEvent(false, false);

        const excluded = pat.match(ctx.name);
        if (excluded == false) { // matched either a file or directory, so we can exclude this before stat()ing.
            ctx.addSpecial(.excluded);
            continue;
        }

        ctx.stat = Stat.read(dir.dir, ctx.name, false) catch {
            ctx.addSpecial(.err);
            continue;
        };
        if (main.config.same_fs and ctx.stat.dev != dir_dev) {
            ctx.addSpecial(.other_fs);
            continue;
        }

        if (main.config.follow_symlinks and ctx.stat.symlink) {
            if (Stat.read(dir.dir, ctx.name, true)) |nstat| {
                if (!nstat.dir) {
                    ctx.stat = nstat;
                    // Symlink targets may reside on different filesystems,
                    // this will break hardlink detection and counting so let's disable it.
                    if (ctx.stat.hlinkc and ctx.stat.dev != dir_dev)
                        ctx.stat.hlinkc = false;
                }
            } else |_| {}
        }
        if (excluded) |e| if (e and ctx.stat.dir) {
            ctx.addSpecial(.excluded);
            continue;
        };

        var edir =
            if (!ctx.stat.dir) null
            else if (dir.dir.openDirZ(ctx.name, .{ .no_follow = true }, true)) |d| std.fs.IterableDir{.dir = d}
            else |_| {
                ctx.addSpecial(.err);
                continue;
            };
        defer if (edir != null) edir.?.close();

        if (@import("builtin").os.tag == .linux and main.config.exclude_kernfs and ctx.stat.dir and isKernfs(edir.?.dir, ctx.stat.dev)) {
            ctx.addSpecial(.kernfs);
            continue;
        }

        if (main.config.exclude_caches and ctx.stat.dir) {
            if (edir.?.dir.openFileZ("CACHEDIR.TAG", .{})) |f| {
                const sig = "Signature: 8a477f597d28d172789f06886806bc55";
                var buf: [sig.len]u8 = undefined;
                if (f.reader().readAll(&buf)) |len| {
                    if (len == sig.len and std.mem.eql(u8, &buf, sig)) {
                        ctx.addSpecial(.excluded);
                        continue;
                    }
                } else |_| {}
            } else |_| {}
        }

        ctx.addStat(dir_dev);
        if (ctx.stat.dir) {
            var subpat = pat.enter(ctx.name);
            defer subpat.deinit();
            scanDir(ctx, &subpat, edir.?, ctx.stat.dev);
        }
    }
}

pub fn scanRoot(path: []const u8, out: ?std.fs.File) !void {
    active_context = if (out) |f| Context.initFile(f) else Context.initMem(null);

    const full_path = std.fs.realpathAlloc(main.allocator, path) catch null;
    defer if (full_path) |p| main.allocator.free(p);
    active_context.pushPath(full_path orelse path);

    active_context.stat = try Stat.read(std.fs.cwd(), active_context.pathZ(), true);
    if (!active_context.stat.dir) return error.NotDir;
    active_context.addStat(0);
    scan();
}

pub fn setupRefresh(parent: *model.Dir) void {
    active_context = Context.initMem(parent);
    var full_path = std.ArrayList(u8).init(main.allocator);
    defer full_path.deinit();
    parent.fmtPath(true, &full_path);
    active_context.pushPath(full_path.items);
    active_context.stat.dir = true;
    active_context.stat.dev = model.devices.list.items[parent.pack.dev];
}

// To be called after setupRefresh() (or from scanRoot())
pub fn scan() void {
    defer active_context.deinit();
    var dir_ = std.fs.cwd().openDirZ(active_context.pathZ(), .{}, true) catch |e| {
        active_context.last_error = main.allocator.dupeZ(u8, active_context.path.items) catch unreachable;
        active_context.fatal_error = e;
        while (main.state == .refresh or main.state == .scan)
            main.handleEvent(true, true);
        return;
    };
    var dir = std.fs.IterableDir{.dir = dir_};
    defer dir.close();
    var pat = exclude.getPatterns(active_context.pathZ());
    defer pat.deinit();
    scanDir(active_context, &pat, dir, active_context.stat.dev);
    active_context.popPath();
    active_context.final();
}

// Using a custom recursive descent JSON parser here. std.json is great, but
// has two major downsides:
// - It does strict UTF-8 validation. Which is great in general, but not so
//   much for ncdu dumps that may contain non-UTF-8 paths encoded as strings.
// - The streaming parser requires complex and overly large buffering in order
//   to read strings, which doesn't work so well in our case.
//
// TODO: This code isn't very elegant and is likely contains bugs. It may be
// worth factoring out the JSON parts into a separate abstraction for which
// tests can be written.
const Import = struct {
    ctx: *Context,

    rd: std.fs.File,
    rdoff: usize = 0,
    rdsize: usize = 0,
    rdbuf: [8*1024]u8 = undefined,

    ch: u8 = 0, // last read character, 0 = EOF (or invalid null byte, who cares)
    byte: u64 = 1,
    line: u64 = 1,
    namebuf: [32*1024]u8 = undefined,

    const Self = @This();

    fn die(self: *Self, str: []const u8) noreturn {
        ui.die("Error importing file on line {}:{}: {s}.\n", .{ self.line, self.byte, str });
    }

    // Advance to the next byte, sets ch.
    fn con(self: *Self) void {
        if (self.rdoff >= self.rdsize) {
            self.rdoff = 0;
            self.rdsize = self.rd.read(&self.rdbuf) catch |e| switch (e) {
                error.InputOutput => self.die("I/O error"),
                error.IsDir => self.die("not a file"), // should be detected at open() time, but no flag for that...
                error.SystemResources => self.die("out of memory"),
                else => unreachable,
            };
            if (self.rdsize == 0) {
                self.ch = 0;
                return;
            }
        }
        // Zig 0.10 copies the entire array to the stack in ReleaseSafe mode,
        // work around that bug by indexing into a pointer to the array
        // instead.
        self.ch = (&self.rdbuf)[self.rdoff];
        self.rdoff += 1;
        self.byte += 1;
    }

    // Advance to the next non-whitespace byte.
    fn conws(self: *Self) void {
        while (true) {
            switch (self.ch) {
                '\n' => {
                    self.line += 1;
                    self.byte = 1;
                },
                ' ', '\t', '\r' => {},
                else => break,
            }
            self.con();
        }
    }

    // Returns the current byte and advances to the next.
    fn next(self: *Self) u8 {
        defer self.con();
        return self.ch;
    }

    fn hexdig(self: *Self) u16 {
        return switch (self.ch) {
            '0'...'9' => self.next() - '0',
            'a'...'f' => self.next() - 'a' + 10,
            'A'...'F' => self.next() - 'A' + 10,
            else => self.die("invalid hex digit"),
        };
    }

    // Read a string into buf.
    // Any characters beyond the size of the buffer are consumed but otherwise discarded.
    // (May store fewer characters in the case of \u escapes, it's not super precise)
    fn string(self: *Self, buf: []u8) []u8 {
        if (self.next() != '"') self.die("expected '\"'");
        var n: usize = 0;
        while (true) {
            const ch = self.next();
            switch (ch) {
                '"' => break,
                '\\' => switch (self.next()) {
                    '"' => if (n < buf.len) { buf[n] = '"'; n += 1; },
                    '\\'=> if (n < buf.len) { buf[n] = '\\';n += 1; },
                    '/' => if (n < buf.len) { buf[n] = '/'; n += 1; },
                    'b' => if (n < buf.len) { buf[n] = 0x8; n += 1; },
                    'f' => if (n < buf.len) { buf[n] = 0xc; n += 1; },
                    'n' => if (n < buf.len) { buf[n] = 0xa; n += 1; },
                    'r' => if (n < buf.len) { buf[n] = 0xd; n += 1; },
                    't' => if (n < buf.len) { buf[n] = 0x9; n += 1; },
                    'u' => {
                        const char = (self.hexdig()<<12) + (self.hexdig()<<8) + (self.hexdig()<<4) + self.hexdig();
                        if (n + 6 < buf.len)
                            n += std.unicode.utf8Encode(char, buf[n..n+5]) catch unreachable;
                    },
                    else => self.die("invalid escape sequence"),
                },
                0x20, 0x21, 0x23...0x5b, 0x5d...0xff => if (n < buf.len) { buf[n] = ch; n += 1; },
                else => self.die("invalid character in string"),
            }
        }
        return buf[0..n];
    }

    fn uint(self: *Self, T: anytype) T {
        if (self.ch == '0') {
            self.con();
            return 0;
        }
        var v: T = 0;
        while (self.ch >= '0' and self.ch <= '9') {
            const newv = v *% 10 +% (self.ch - '0');
            if (newv < v) self.die("integer out of range");
            v = newv;
            self.con();
        }
        if (v == 0) self.die("expected number");
        return v;
    }

    fn boolean(self: *Self) bool {
        switch (self.next()) {
            't' => {
                if (self.next() == 'r' and self.next() == 'u' and self.next() == 'e')
                    return true;
            },
            'f' => {
                if (self.next() == 'a' and self.next() == 'l' and self.next() == 's' and self.next() == 'e')
                    return false;
            },
            else => {}
        }
        self.die("expected boolean");
    }

    // Consume and discard any JSON value.
    fn conval(self: *Self) void {
        switch (self.ch) {
            't' => _ = self.boolean(),
            'f' => _ = self.boolean(),
            'n' => {
                self.con();
                if (!(self.next() == 'u' and self.next() == 'l' and self.next() == 'l'))
                    self.die("invalid JSON value");
            },
            '"' => _ = self.string(&[0]u8{}),
            '{' => {
                self.con();
                self.conws();
                if (self.ch == '}') { self.con(); return; }
                while (true) {
                    self.conws();
                    _ = self.string(&[0]u8{});
                    self.conws();
                    if (self.next() != ':') self.die("expected ':'");
                    self.conws();
                    self.conval();
                    self.conws();
                    switch (self.next()) {
                        ',' => continue,
                        '}' => break,
                        else => self.die("expected ',' or '}'"),
                    }
                }
            },
            '[' => {
                self.con();
                self.conws();
                if (self.ch == ']') { self.con(); return; }
                while (true) {
                    self.conws();
                    self.conval();
                    self.conws();
                    switch (self.next()) {
                        ',' => continue,
                        ']' => break,
                        else => self.die("expected ',' or ']'"),
                    }
                }
            },
            '-', '0'...'9' => {
                self.con();
                // Numbers are kind of annoying, this "parsing" is invalid and ultra-lazy.
                while (true) {
                    switch (self.ch) {
                        '-', '+', 'e', 'E', '.', '0'...'9' => self.con(),
                        else => return,
                    }
                }
            },
            else => self.die("invalid JSON value"),
        }
    }

    fn itemkey(self: *Self, key: []const u8, name: *?[]u8, special: *?Context.Special) void {
        const eq = std.mem.eql;
        switch (if (key.len > 0) key[0] else @as(u8,0)) {
            'a' => {
                if (eq(u8, key, "asize")) {
                    self.ctx.stat.size = self.uint(u64);
                    return;
                }
            },
            'd' => {
                if (eq(u8, key, "dsize")) {
                    self.ctx.stat.blocks = @intCast(self.uint(u64)>>9);
                    return;
                }
                if (eq(u8, key, "dev")) {
                    self.ctx.stat.dev = self.uint(u64);
                    return;
                }
            },
            'e' => {
                if (eq(u8, key, "excluded")) {
                    var buf: [32]u8 = undefined;
                    const typ = self.string(&buf);
                    // "frmlnk" is also possible, but currently considered equivalent to "pattern".
                    if (eq(u8, typ, "otherfs")) special.* = .other_fs
                    else if (eq(u8, typ, "kernfs")) special.* = .kernfs
                    else special.* = .excluded;
                    return;
                }
            },
            'g' => {
                if (eq(u8, key, "gid")) {
                    self.ctx.stat.ext.gid = self.uint(u32);
                    return;
                }
            },
            'h' => {
                if (eq(u8, key, "hlnkc")) {
                    self.ctx.stat.hlinkc = self.boolean();
                    return;
                }
            },
            'i' => {
                if (eq(u8, key, "ino")) {
                    self.ctx.stat.ino = self.uint(u64);
                    return;
                }
            },
            'm' => {
                if (eq(u8, key, "mode")) {
                    self.ctx.stat.ext.mode = self.uint(u16);
                    return;
                }
                if (eq(u8, key, "mtime")) {
                    self.ctx.stat.ext.mtime = self.uint(u64);
                    // Accept decimal numbers, but discard the fractional part because our data model doesn't support it.
                    if (self.ch == '.') {
                        self.con();
                        while (self.ch >= '0' and self.ch <= '9')
                            self.con();
                    }
                    return;
                }
            },
            'n' => {
                if (eq(u8, key, "name")) {
                    if (name.* != null) self.die("duplicate key");
                    name.* = self.string(&self.namebuf);
                    if (name.*.?.len > self.namebuf.len-5) self.die("too long file name");
                    return;
                }
                if (eq(u8, key, "nlink")) {
                    self.ctx.stat.nlink = self.uint(u31);
                    if (!self.ctx.stat.dir and self.ctx.stat.nlink > 1)
                        self.ctx.stat.hlinkc = true;
                    return;
                }
                if (eq(u8, key, "notreg")) {
                    self.ctx.stat.reg = !self.boolean();
                    return;
                }
            },
            'r' => {
                if (eq(u8, key, "read_error")) {
                    if (self.boolean())
                        special.* = .err;
                    return;
                }
            },
            'u' => {
                if (eq(u8, key, "uid")) {
                    self.ctx.stat.ext.uid = self.uint(u32);
                    return;
                }
            },
            else => {},
        }
        self.conval();
    }

    fn iteminfo(self: *Self, dir_dev: u64) void {
        if (self.next() != '{') self.die("expected '{'");
        self.ctx.stat.dev = dir_dev;
        var name: ?[]u8 = null;
        var special: ?Context.Special = null;
        while (true) {
            self.conws();
            var keybuf: [32]u8 = undefined;
            const key = self.string(&keybuf);
            self.conws();
            if (self.next() != ':') self.die("expected ':'");
            self.conws();
            self.itemkey(key, &name, &special);
            self.conws();
            switch (self.next()) {
                ',' => continue,
                '}' => break,
                else => self.die("expected ',' or '}'"),
            }
        }
        if (name) |n| self.ctx.pushPath(n)
        else self.die("missing \"name\" field");
        if (special) |s| self.ctx.addSpecial(s)
        else self.ctx.addStat(dir_dev);
    }

    fn item(self: *Self, dev: u64) void {
        self.ctx.stat = .{};
        var isdir = false;
        if (self.ch == '[') {
            isdir = true;
            self.ctx.stat.dir = true;
            self.con();
            self.conws();
        }

        self.iteminfo(dev);

        self.conws();
        if (isdir) {
            const ndev = self.ctx.stat.dev;
            while (self.ch == ',') {
                self.con();
                self.conws();
                self.item(ndev);
                self.conws();
            }
            if (self.next() != ']') self.die("expected ',' or ']'");
        }
        self.ctx.popPath();

        if ((self.ctx.items_seen & 1023) == 0)
            main.handleEvent(false, false);
    }

    fn root(self: *Self) void {
        self.con();
        self.conws();
        if (self.next() != '[') self.die("expected '['");
        self.conws();
        if (self.uint(u16) != 1) self.die("incompatible major format version");
        self.conws();
        if (self.next() != ',') self.die("expected ','");
        self.conws();
        _ = self.uint(u16); // minor version, ignored for now
        self.conws();
        if (self.next() != ',') self.die("expected ','");
        self.conws();
        // metadata object
        if (self.ch != '{') self.die("expected '{'");
        self.conval(); // completely discarded
        self.conws();
        if (self.next() != ',') self.die("expected ','");
        self.conws();
        // root element
        if (self.ch != '[') self.die("expected '['"); // top-level entry must be a dir
        self.item(0);
        self.conws();
        // any trailing elements
        while (self.ch == ',') {
            self.con();
            self.conws();
            self.conval();
            self.conws();
        }
        if (self.next() != ']') self.die("expected ',' or ']'");
        self.conws();
        if (self.ch != 0) self.die("trailing garbage");
    }
};

pub fn importRoot(path: [:0]const u8, out: ?std.fs.File) void {
    const fd = if (std.mem.eql(u8, "-", path)) std.io.getStdIn()
             else std.fs.cwd().openFileZ(path, .{})
                  catch |e| ui.die("Error reading file: {s}.\n", .{ui.errorString(e)});
    defer fd.close();

    active_context = if (out) |f| Context.initFile(f) else Context.initMem(null);
    var imp = Import{ .ctx = active_context, .rd = fd };
    defer imp.ctx.deinit();
    imp.root();
    imp.ctx.final();
}

var animation_pos: u32 = 0;
var counting_hardlinks: bool = false;
var need_confirm_quit = false;

fn drawError(err: anyerror) void {
    const width = ui.cols -| 5;
    const box = ui.Box.create(7, width, "Scan error");

    box.move(2, 2);
    ui.addstr("Path: ");
    ui.addstr(ui.shorten(ui.toUtf8(active_context.last_error.?), width -| 10));

    box.move(3, 2);
    ui.addstr("Error: ");
    ui.addstr(ui.shorten(ui.errorString(err), width -| 6));

    box.move(5, width -| 27);
    ui.addstr("Press any key to continue");
}

fn drawCounting() void {
    const box = ui.Box.create(4, 25, "Finalizing");
    box.move(2, 2);
    ui.addstr("Counting hardlinks...");
}

fn drawBox() void {
    ui.init();
    const ctx = active_context;
    if (ctx.fatal_error) |err| return drawError(err);
    if (counting_hardlinks) return drawCounting();
    const width = ui.cols -| 5;
    const box = ui.Box.create(10, width, "Scanning...");
    box.move(2, 2);
    ui.addstr("Total items: ");
    ui.addnum(.default, ctx.items_seen);

    if (width > 48 and ctx.parents != null) {
        box.move(2, 30);
        ui.addstr("size: ");
        // TODO: Should display the size of the dir-to-be-refreshed on refreshing, not the root.
        ui.addsize(.default, util.blocksToSize(model.root.entry.pack.blocks +| model.inodes.total_blocks));
    }

    box.move(3, 2);
    ui.addstr("Current item: ");
    ui.addstr(ui.shorten(ui.toUtf8(ctx.pathZ()), width -| 18));

    if (ctx.last_error) |path| {
        box.move(5, 2);
        ui.style(.bold);
        ui.addstr("Warning: ");
        ui.style(.default);
        ui.addstr("error scanning ");
        ui.addstr(ui.shorten(ui.toUtf8(path), width -| 28));
        box.move(6, 3);
        ui.addstr("some directory sizes may not be correct.");
    }

    if (need_confirm_quit) {
        box.move(8, width -| 20);
        ui.addstr("Press ");
        ui.style(.key);
        ui.addch('y');
        ui.style(.default);
        ui.addstr(" to confirm");
    } else {
        box.move(8, width -| 18);
        ui.addstr("Press ");
        ui.style(.key);
        ui.addch('q');
        ui.style(.default);
        ui.addstr(" to abort");
    }

    if (main.config.update_delay < std.time.ns_per_s and width > 40) {
        const txt = "Scanning...";
        animation_pos += 1;
        if (animation_pos >= txt.len*2) animation_pos = 0;
        if (animation_pos < txt.len) {
            box.move(8, 2);
            for (txt[0..animation_pos + 1]) |t| ui.addch(t);
        } else {
            var i: u32 = txt.len-1;
            while (i > animation_pos-txt.len) : (i -= 1) {
                box.move(8, 2+i);
                ui.addch(txt[i]);
            }
        }
    }
}

pub fn draw() void {
    if (active_context.fatal_error != null and main.config.scan_ui.? != .full)
        ui.die("Error reading {s}: {s}\n", .{ active_context.last_error.?, ui.errorString(active_context.fatal_error.?) });
    switch (main.config.scan_ui.?) {
        .none => {},
        .line => {
            var buf: [256]u8 = undefined;
            var line: []const u8 = undefined;
            if (counting_hardlinks) {
                line = "\x1b7\x1b[JCounting hardlinks...\x1b8";
            } else if (active_context.parents == null) {
                line = std.fmt.bufPrint(&buf, "\x1b7\x1b[J{s: <63} {d:>9} files\x1b8",
                    .{ ui.shorten(active_context.pathZ(), 63), active_context.items_seen }
                ) catch return;
            } else {
                const r = ui.FmtSize.fmt(util.blocksToSize(model.root.entry.pack.blocks));
                line = std.fmt.bufPrint(&buf, "\x1b7\x1b[J{s: <51} {d:>9} files / {s}{s}\x1b8",
                    .{ ui.shorten(active_context.pathZ(), 51), active_context.items_seen, r.num(), r.unit }
                ) catch return;
            }
            const stderr = std.io.getStdErr();
            stderr.writeAll(line) catch {};
        },
        .full => drawBox(),
    }
}

pub fn keyInput(ch: i32) void {
    if (active_context.fatal_error != null) {
        if (main.state == .scan) ui.quit()
        else main.state = .browse;
        return;
    }
    if (need_confirm_quit) {
        switch (ch) {
            'y', 'Y' => if (need_confirm_quit) ui.quit(),
            else => need_confirm_quit = false,
        }
        return;
    }
    switch (ch) {
        'q' => if (main.config.confirm_quit) { need_confirm_quit = true; } else ui.quit(),
        else => need_confirm_quit = false,
    }
}
