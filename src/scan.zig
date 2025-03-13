// SPDX-FileCopyrightText: Yorhel <projects@yorhel.nl>
// SPDX-License-Identifier: MIT

const std = @import("std");
const main = @import("main.zig");
const util = @import("util.zig");
const model = @import("model.zig");
const sink = @import("sink.zig");
const ui = @import("ui.zig");
const exclude = @import("exclude.zig");
const c = @import("c.zig").c;


// This function only works on Linux
fn isKernfs(dir: std.fs.Dir) bool {
    var buf: c.struct_statfs = undefined;
    if (c.fstatfs(dir.fd, &buf) != 0) return false; // silently ignoring errors isn't too nice.
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
    return iskern;
}


fn clamp(comptime T: type, comptime field: anytype, x: anytype) std.meta.fieldInfo(T, field).type {
    return util.castClamp(std.meta.fieldInfo(T, field).type, x);
}


fn truncate(comptime T: type, comptime field: anytype, x: anytype) std.meta.fieldInfo(T, field).type {
    return util.castTruncate(std.meta.fieldInfo(T, field).type, x);
}


fn statAt(parent: std.fs.Dir, name: [:0]const u8, follow: bool, symlink: *bool) !sink.Stat {
    const stat = try std.posix.fstatatZ(parent.fd, name, if (follow) 0 else std.posix.AT.SYMLINK_NOFOLLOW);
    symlink.* = std.posix.S.ISLNK(stat.mode);
    return sink.Stat{
        .etype =
            if (std.posix.S.ISDIR(stat.mode)) .dir
            else if (stat.nlink > 1) .link
            else if (!std.posix.S.ISREG(stat.mode)) .nonreg
            else .reg,
        .blocks = clamp(sink.Stat, .blocks, stat.blocks),
        .size = clamp(sink.Stat, .size, stat.size),
        .dev = truncate(sink.Stat, .dev, stat.dev),
        .ino = truncate(sink.Stat, .ino, stat.ino),
        .nlink = clamp(sink.Stat, .nlink, stat.nlink),
        .ext = .{
            .pack = .{
                .hasmtime = true,
                .hasuid = true,
                .hasgid = true,
                .hasmode = true,
            },
            .mtime = clamp(model.Ext, .mtime, stat.mtime().sec),
            .uid = truncate(model.Ext, .uid, stat.uid),
            .gid = truncate(model.Ext, .gid, stat.gid),
            .mode = truncate(model.Ext, .mode, stat.mode),
        },
    };
}


fn isCacheDir(dir: std.fs.Dir) bool {
    const sig = "Signature: 8a477f597d28d172789f06886806bc55";
    const f = dir.openFileZ("CACHEDIR.TAG", .{}) catch return false;
    defer f.close();
    var buf: [sig.len]u8 = undefined;
    const len = f.reader().readAll(&buf) catch return false;
    return len == sig.len and std.mem.eql(u8, &buf, sig);
}


const State = struct {
    // Simple LIFO queue. Threads attempt to fully scan their assigned
    // directory before consulting this queue for their next task, so there
    // shouldn't be too much contention here.
    // TODO: unless threads keep juggling around leaf nodes, need to measure
    // actual use.
    // There's no real reason for this to be LIFO other than that that was the
    // easiest to implement. Queue order has an effect on scheduling, but it's
    // impossible for me to predict how that ends up affecting performance.
    queue: [QUEUE_SIZE]*Dir = undefined,
    queue_len: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    queue_lock: std.Thread.Mutex = .{},
    queue_cond: std.Thread.Condition = .{},

    threads: []Thread,
    waiting: usize = 0,

    // No clue what this should be set to. Dir structs aren't small so we don't
    // want too have too many of them.
    const QUEUE_SIZE = 16;

    // Returns true if the given Dir has been queued, false if the queue is full.
    fn tryPush(self: *State, d: *Dir) bool {
        if (self.queue_len.load(.acquire) == QUEUE_SIZE) return false;
        {
            self.queue_lock.lock();
            defer self.queue_lock.unlock();
            if (self.queue_len.load(.monotonic) == QUEUE_SIZE) return false;
            const slot = self.queue_len.fetchAdd(1, .monotonic);
            self.queue[slot] = d;
        }
        self.queue_cond.signal();
        return true;
    }

    // Blocks while the queue is empty, returns null when all threads are blocking.
    fn waitPop(self: *State) ?*Dir {
        self.queue_lock.lock();
        defer self.queue_lock.unlock();

        self.waiting += 1;
        while (self.queue_len.load(.monotonic) == 0) {
            if (self.waiting == self.threads.len) {
                self.queue_cond.broadcast();
                return null;
            }
            self.queue_cond.wait(&self.queue_lock);
        }
        self.waiting -= 1;

        const slot = self.queue_len.fetchSub(1, .monotonic) - 1;
        defer self.queue[slot] = undefined;
        return self.queue[slot];
    }
};


const Dir = struct {
    fd: std.fs.Dir,
    dev: u64,
    pat: exclude.Patterns,
    it: std.fs.Dir.Iterator,
    sink: *sink.Dir,

    fn create(fd: std.fs.Dir, dev: u64, pat: exclude.Patterns, s: *sink.Dir) *Dir {
        const d = main.allocator.create(Dir) catch unreachable;
        d.* = .{
            .fd = fd,
            .dev = dev,
            .pat = pat,
            .sink = s,
            .it = fd.iterate(),
        };
        return d;
    }

    fn destroy(d: *Dir, t: *Thread) void {
        d.pat.deinit();
        d.fd.close();
        d.sink.unref(t.sink);
        main.allocator.destroy(d);
    }
};

const Thread = struct {
    thread_num: usize,
    sink: *sink.Thread,
    state: *State,
    stack: std.ArrayList(*Dir) = std.ArrayList(*Dir).init(main.allocator),
    thread: std.Thread = undefined,
    namebuf: [4096]u8 = undefined,

    fn scanOne(t: *Thread, dir: *Dir, name_: []const u8) void {
        if (name_.len > t.namebuf.len - 1) {
            dir.sink.addSpecial(t.sink, name_, .err);
            return;
        }

        @memcpy(t.namebuf[0..name_.len], name_);
        t.namebuf[name_.len] = 0;
        const name = t.namebuf[0..name_.len:0];

        const excluded = dir.pat.match(name);
        if (excluded == false) { // matched either a file or directory, so we can exclude this before stat()ing.
            dir.sink.addSpecial(t.sink, name, .pattern);
            return;
        }

        var symlink: bool = undefined;
        var stat = statAt(dir.fd, name, false, &symlink) catch {
            dir.sink.addSpecial(t.sink, name, .err);
            return;
        };

        if (main.config.follow_symlinks and symlink) {
            if (statAt(dir.fd, name, true, &symlink)) |nstat| {
                if (nstat.etype != .dir) {
                    stat = nstat;
                    // Symlink targets may reside on different filesystems,
                    // this will break hardlink detection and counting so let's disable it.
                    if (stat.etype == .link and stat.dev != dir.dev) {
                        stat.etype = .reg;
                        stat.nlink = 1;
                    }
                }
            } else |_| {}
        }

        if (main.config.same_fs and stat.dev != dir.dev) {
            dir.sink.addSpecial(t.sink, name, .otherfs);
            return;
        }

        if (stat.etype != .dir) {
            dir.sink.addStat(t.sink, name, &stat);
            return;
        }

        if (excluded == true) {
            dir.sink.addSpecial(t.sink, name, .pattern);
            return;
        }

        var edir = dir.fd.openDirZ(name, .{ .no_follow = true, .iterate = true }) catch {
            const s = dir.sink.addDir(t.sink, name, &stat);
            s.setReadError(t.sink);
            s.unref(t.sink);
            return;
        };

        if (@import("builtin").os.tag == .linux
            and main.config.exclude_kernfs
            and stat.dev != dir.dev
            and isKernfs(edir)
        ) {
            edir.close();
            dir.sink.addSpecial(t.sink, name, .kernfs);
            return;
        }

        if (main.config.exclude_caches and isCacheDir(edir)) {
            dir.sink.addSpecial(t.sink, name, .pattern);
            edir.close();
            return;
        }

        const s = dir.sink.addDir(t.sink, name, &stat);
        const ndir = Dir.create(edir, stat.dev, dir.pat.enter(name), s);
        if (main.config.threads == 1 or !t.state.tryPush(ndir))
            t.stack.append(ndir) catch unreachable;
    }

    fn run(t: *Thread) void {
        defer t.stack.deinit();
        while (t.state.waitPop()) |dir| {
            t.stack.append(dir) catch unreachable;

            while (t.stack.items.len > 0) {
                const d = t.stack.items[t.stack.items.len - 1];

                t.sink.setDir(d.sink);
                if (t.thread_num == 0) main.handleEvent(false, false);

                const entry = d.it.next() catch blk: {
                    dir.sink.setReadError(t.sink);
                    break :blk null;
                };
                if (entry) |e| t.scanOne(d, e.name)
                else {
                    t.sink.setDir(null);
                    t.stack.pop().?.destroy(t);
                }
            }
        }
    }
};


pub fn scan(path: [:0]const u8) !void {
    const sink_threads = sink.createThreads(main.config.threads);
    defer sink.done();

    var symlink: bool = undefined;
    const stat = try statAt(std.fs.cwd(), path, true, &symlink);
    const fd = try std.fs.cwd().openDirZ(path, .{ .iterate = true });

    var state = State{
        .threads = main.allocator.alloc(Thread, main.config.threads) catch unreachable,
    };
    defer main.allocator.free(state.threads);

    const root = sink.createRoot(path, &stat);
    const dir = Dir.create(fd, stat.dev, exclude.getPatterns(path), root);
    _ = state.tryPush(dir);

    for (sink_threads, state.threads, 0..) |*s, *t, n|
        t.* = .{ .sink = s, .state = &state, .thread_num = n };

    // XXX: Continue with fewer threads on error?
    for (state.threads[1..]) |*t| {
        t.thread = std.Thread.spawn(
            .{ .stack_size = 128 * 1024, .allocator = main.allocator }, Thread.run, .{t}
        ) catch |e| ui.die("Error spawning thread: {}\n", .{e});
    }
    state.threads[0].run();
    for (state.threads[1..]) |*t| t.thread.join();
}
