// SPDX-FileCopyrightText: Yorhel <projects@yorhel.nl>
// SPDX-License-Identifier: MIT

const std = @import("std");
const main = @import("main.zig");
const model = @import("model.zig");
const sink = @import("sink.zig");
const util = @import("util.zig");
const ui = @import("ui.zig");

// JSON output is necessarily single-threaded and items MUST be added depth-first.

pub const global = struct {
    var writer: *Writer = undefined;
};

pub const Writer = struct {
    fd: std.fs.File,
    // Must be large enough to hold PATH_MAX*6 plus some overhead.
    // (The 6 is because, in the worst case, every byte expands to a "\u####"
    // escape, and we do pessimistic estimates here in order to avoid checking
    // buffer lengths for each and every write operation)
    buf: [64*1024]u8 = undefined,
    off: usize = 0,
    dir_entry_open: bool = false,

    fn flush(ctx: *Writer, bytes: usize) void {
        @setCold(true);
        // This can only really happen when the root path exceeds PATH_MAX,
        // in which case we would probably have error'ed out earlier anyway.
        if (bytes > ctx.buf.len) ui.die("Error writing JSON export: path too long.\n", .{});
        ctx.fd.writeAll(ctx.buf[0..ctx.off]) catch |e|
            ui.die("Error writing to file: {s}.\n", .{ ui.errorString(e) });
        ctx.off = 0;
    }

    fn ensureSpace(ctx: *Writer, bytes: usize) void {
        if (bytes > ctx.buf.len - ctx.off) ctx.flush(bytes);
    }

    fn write(ctx: *Writer, s: []const u8) void {
        @memcpy(ctx.buf[ctx.off..][0..s.len], s);
        ctx.off += s.len;
    }

    fn writeByte(ctx: *Writer, b: u8) void {
        ctx.buf[ctx.off] = b;
        ctx.off += 1;
    }

    // Write escaped string contents, excluding the quotes.
    fn writeStr(ctx: *Writer, s: []const u8) void {
        for (s) |b| {
            if (b >= 0x20 and b != '"' and b != '\\' and b != 127) ctx.writeByte(b)
            else switch (b) {
                '\n' => ctx.write("\\n"),
                '\r' => ctx.write("\\r"),
                0x8  => ctx.write("\\b"),
                '\t' => ctx.write("\\t"),
                0xC  => ctx.write("\\f"),
                '\\' => ctx.write("\\\\"),
                '"'  => ctx.write("\\\""),
                else => {
                    ctx.write("\\u00");
                    const hexdig = "0123456789abcdef";
                    ctx.writeByte(hexdig[b>>4]);
                    ctx.writeByte(hexdig[b&0xf]);
                },
            }
        }
    }

    fn writeUint(ctx: *Writer, n: u64) void {
        // Based on std.fmt.formatInt
        var a = n;
        var buf: [24]u8 = undefined;
        var index: usize = buf.len;
        while (a >= 100) : (a = @divTrunc(a, 100)) {
            index -= 2;
            buf[index..][0..2].* = std.fmt.digits2(@as(usize, @intCast(a % 100)));
        }
        if (a < 10) {
            index -= 1;
            buf[index] = '0' + @as(u8, @intCast(a));
        } else {
            index -= 2;
            buf[index..][0..2].* = std.fmt.digits2(@as(usize, @intCast(a)));
        }
        ctx.write(buf[index..]);
    }

    fn init(out: std.fs.File) *Writer {
        var ctx = main.allocator.create(Writer) catch unreachable;
        ctx.* = .{ .fd = out };
        ctx.write("[1,2,{\"progname\":\"ncdu\",\"progver\":\"" ++ main.program_version ++ "\",\"timestamp\":");
        ctx.writeUint(@intCast(@max(0, std.time.timestamp())));
        ctx.writeByte('}');
        return ctx;
    }

    // A newly written directory entry is left "open", i.e. the '}' to close
    // the item object is not written, to allow for a setReadError() to be
    // caught if one happens before the first sub entry.
    // Any read errors after the first sub entry are thrown away, but that's
    // just a limitation of the JSON format.
    fn closeDirEntry(ctx: *Writer, rderr: bool) void {
        if (ctx.dir_entry_open) {
            ctx.dir_entry_open = false;
            if (rderr) ctx.write(",\"read_error\":true");
            ctx.writeByte('}');
        }
    }

    fn writeSpecial(ctx: *Writer, name: []const u8, t: model.EType) void {
        ctx.closeDirEntry(false);
        ctx.ensureSpace(name.len*6 + 1000);
        ctx.write(if (t.isDirectory()) ",\n[{\"name\":\"" else ",\n{\"name\":\"");
        ctx.writeStr(name);
        ctx.write(switch (t) {
            .err => "\",\"read_error\":true}",
            .otherfs => "\",\"excluded\":\"otherfs\"}",
            .kernfs => "\",\"excluded\":\"kernfs\"}",
            .pattern => "\",\"excluded\":\"pattern\"}",
            else => unreachable,
        });
        if (t.isDirectory()) ctx.writeByte(']');
    }

    fn writeStat(ctx: *Writer, name: []const u8, stat: *const sink.Stat, parent_dev: u64) void {
        ctx.ensureSpace(name.len*6 + 1000);
        ctx.write(if (stat.etype == .dir) ",\n[{\"name\":\"" else ",\n{\"name\":\"");
        ctx.writeStr(name);
        ctx.writeByte('"');
        if (stat.size > 0) {
            ctx.write(",\"asize\":");
            ctx.writeUint(stat.size);
        }
        if (stat.blocks > 0) {
            ctx.write(",\"dsize\":");
            ctx.writeUint(util.blocksToSize(stat.blocks));
        }
        if (stat.etype == .dir and stat.dev != parent_dev) {
            ctx.write(",\"dev\":");
            ctx.writeUint(stat.dev);
        }
        if (stat.etype == .link) {
            ctx.write(",\"ino\":");
            ctx.writeUint(stat.ino);
            ctx.write(",\"hlnkc\":true,\"nlink\":");
            ctx.writeUint(stat.nlink);
        }
        if (stat.etype == .nonreg) ctx.write(",\"notreg\":true");
        if (main.config.extended) {
            if (stat.ext.pack.hasuid) {
                ctx.write(",\"uid\":");
                ctx.writeUint(stat.ext.uid);
            }
            if (stat.ext.pack.hasgid) {
                ctx.write(",\"gid\":");
                ctx.writeUint(stat.ext.gid);
            }
            if (stat.ext.pack.hasmode) {
                ctx.write(",\"mode\":");
                ctx.writeUint(stat.ext.mode);
            }
            if (stat.ext.pack.hasmtime) {
                ctx.write(",\"mtime\":");
                ctx.writeUint(stat.ext.mtime);
            }
        }
    }
};

pub const Dir = struct {
    dev: u64,

    pub fn addSpecial(_: *Dir, name: []const u8, sp: model.EType) void {
        global.writer.writeSpecial(name, sp);
    }

    pub fn addStat(_: *Dir, name: []const u8, stat: *const sink.Stat) void {
        global.writer.closeDirEntry(false);
        global.writer.writeStat(name, stat, undefined);
        global.writer.writeByte('}');
    }

    pub fn addDir(d: *Dir, name: []const u8, stat: *const sink.Stat) Dir {
        global.writer.closeDirEntry(false);
        global.writer.writeStat(name, stat, d.dev);
        global.writer.dir_entry_open = true;
        return .{ .dev = stat.dev };
    }

    pub fn setReadError(_: *Dir) void {
        global.writer.closeDirEntry(true);
    }

    pub fn final(_: *Dir) void {
        global.writer.ensureSpace(1000);
        global.writer.closeDirEntry(false);
        global.writer.writeByte(']');
    }
};

pub fn createRoot(path: []const u8, stat: *const sink.Stat) Dir {
    var root = Dir{.dev=0};
    return root.addDir(path, stat);
}

pub fn done() void {
    global.writer.write("]\n");
    global.writer.flush(0);
    global.writer.fd.close();
    main.allocator.destroy(global.writer);
}

pub fn setupOutput(out: std.fs.File) void {
    global.writer = Writer.init(out);
}
