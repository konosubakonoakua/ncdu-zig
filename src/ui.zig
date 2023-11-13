// SPDX-FileCopyrightText: 2021-2023 Yoran Heling <projects@yorhel.nl>
// SPDX-License-Identifier: MIT

// Ncurses wrappers and TUI helper functions.

const std = @import("std");
const main = @import("main.zig");
const util = @import("util.zig");

pub const c = @cImport({
    @cDefine("_XOPEN_SOURCE", "1");
    @cInclude("stdio.h");
    @cInclude("string.h");
    @cInclude("curses.h");
    @cInclude("time.h");
    @cInclude("wchar.h");
    @cInclude("locale.h");
});

pub var inited: bool = false;

pub var rows: u32 = undefined;
pub var cols: u32 = undefined;

pub fn die(comptime fmt: []const u8, args: anytype) noreturn {
    deinit();
    const stderr = std.io.getStdErr();
    stderr.writer().print(fmt, args) catch {};
    std.process.exit(1);
}

pub fn quit() noreturn {
    deinit();
    std.process.exit(0);
}

// Should be called when malloc fails. Will show a message to the user, wait
// for a second and return to give it another try.
// Glitch: this function may be called while we're in the process of drawing
// the ncurses window, in which case the deinit/reinit will cause the already
// drawn part to be discarded. A redraw will fix that, but that tends to only
// happen after user input.
// Also, init() and other ncurses-related functions may have hidden allocation,
// no clue if ncurses will consistently report OOM, but we're not handling that
// right now.
pub fn oom() void {
    const haveui = inited;
    deinit();
    const stderr = std.io.getStdErr();
    stderr.writeAll("\x1b7\x1b[JOut of memory, trying again in 1 second. Hit Ctrl-C to abort.\x1b8") catch {};
    std.time.sleep(std.time.ns_per_s);
    if (haveui)
        init();
}

// Dumb strerror() alternative for Zig file I/O, not complete.
// (Would be nicer if Zig just exposed errno so I could call strerror() directly)
pub fn errorString(e: anyerror) [:0]const u8 {
    return switch (e) {
        error.AccessDenied => "Access denied",
        error.DirNotEmpty => "Directory not empty",
        error.DiskQuota => "Disk quota exceeded",
        error.FileBusy => "File is busy",
        error.FileNotFound => "No such file or directory",
        error.FileSystem => "I/O error", // This one is shit, Zig uses this for both EIO and ELOOP in execve().
        error.FileTooBig => "File too big",
        error.InputOutput => "I/O error",
        error.InvalidExe => "Invalid executable",
        error.IsDir => "Is a directory",
        error.NameTooLong => "Filename too long",
        error.NoSpaceLeft => "No space left on device",
        error.NotDir => "Not a directory",
        error.OutOfMemory, error.SystemResources => "Out of memory",
        error.ProcessFdQuotaExceeded => "Process file descriptor limit exceeded",
        error.ReadOnlyFilesystem => "Read-only filesystem",
        error.SymlinkLoop => "Symlink loop",
        error.SystemFdQuotaExceeded => "System file descriptor limit exceeded",
        else => @errorName(e),
    };
}

var to_utf8_buf = std.ArrayList(u8).init(main.allocator);

fn toUtf8BadChar(ch: u8) bool {
    return switch (ch) {
        0...0x1F, 0x7F => true,
        else => false
    };
}

// Utility function to convert a string to valid (mostly) printable UTF-8.
// Invalid codepoints will be encoded as '\x##' strings.
// Returns the given string if it's already valid, otherwise points to an
// internal buffer that will be invalidated on the next call.
// (Doesn't check for non-printable Unicode characters)
// (This program assumes that the console locale is UTF-8, but file names may not be)
pub fn toUtf8(in: [:0]const u8) [:0]const u8 {
    const hasBadChar = blk: {
        for (in) |ch| if (toUtf8BadChar(ch)) break :blk true;
        break :blk false;
    };
    if (!hasBadChar and std.unicode.utf8ValidateSlice(in)) return in;
    var i: usize = 0;
    to_utf8_buf.shrinkRetainingCapacity(0);
    while (i < in.len) {
        if (std.unicode.utf8ByteSequenceLength(in[i])) |cp_len| {
            if (!toUtf8BadChar(in[i]) and i + cp_len <= in.len) {
                if (std.unicode.utf8Decode(in[i .. i + cp_len])) |_| {
                    to_utf8_buf.appendSlice(in[i .. i + cp_len]) catch unreachable;
                    i += cp_len;
                    continue;
                } else |_| {}
            }
        } else |_| {}
        to_utf8_buf.writer().print("\\x{X:0>2}", .{in[i]}) catch unreachable;
        i += 1;
    }
    return util.arrayListBufZ(&to_utf8_buf);
}

var shorten_buf = std.ArrayList(u8).init(main.allocator);

// Shorten the given string to fit in the given number of columns.
// If the string is too long, only the prefix and suffix will be printed, with '...' in between.
// Input is assumed to be valid UTF-8.
// Return value points to the input string or to an internal buffer that is
// invalidated on a subsequent call.
pub fn shorten(in: [:0]const u8, max_width: u32) [:0] const u8 {
    if (max_width < 4) return "...";
    var total_width: u32 = 0;
    var prefix_width: u32 = 0;
    var prefix_end: u32 = 0;
    var prefix_done = false;
    var it = std.unicode.Utf8View.initUnchecked(in).iterator();
    while (it.nextCodepoint()) |cp| {
        // XXX: libc assumption: wchar_t is a Unicode point. True for most modern libcs?
        // (The "proper" way is to use mbtowc(), but I'd rather port the musl wcwidth implementation to Zig so that I *know* it'll be Unicode.
        // On the other hand, ncurses also use wcwidth() so that would cause duplicated code. Ugh)
        const cp_width_ = c.wcwidth(cp);
        const cp_width: u32 = @intCast(if (cp_width_ < 0) 0 else cp_width_);
        const cp_len = std.unicode.utf8CodepointSequenceLength(cp) catch unreachable;
        total_width += cp_width;
        if (!prefix_done and prefix_width + cp_width <= @divFloor(max_width-1, 2)-1) {
            prefix_width += cp_width;
            prefix_end += cp_len;
        } else
            prefix_done = true;
    }
    if (total_width <= max_width) return in;

    shorten_buf.shrinkRetainingCapacity(0);
    shorten_buf.appendSlice(in[0..prefix_end]) catch unreachable;
    shorten_buf.appendSlice("...") catch unreachable;

    var start_width: u32 = prefix_width;
    var start_len: u32 = prefix_end;
    it = std.unicode.Utf8View.initUnchecked(in[prefix_end..]).iterator();
    while (it.nextCodepoint()) |cp| {
        const cp_width_ = c.wcwidth(cp);
        const cp_width: u32 = @intCast(if (cp_width_ < 0) 0 else cp_width_);
        const cp_len = std.unicode.utf8CodepointSequenceLength(cp) catch unreachable;
        start_width += cp_width;
        start_len += cp_len;
        if (total_width - start_width <= max_width - prefix_width - 3) {
            shorten_buf.appendSlice(in[start_len..]) catch unreachable;
            break;
        }
    }
    return util.arrayListBufZ(&shorten_buf);
}

fn shortenTest(in: [:0]const u8, max_width: u32, out: [:0]const u8) !void {
    try std.testing.expectEqualStrings(out, shorten(in, max_width));
}

test "shorten" {
    _ = c.setlocale(c.LC_ALL, ""); // libc wcwidth() may not recognize Unicode without this
    const t = shortenTest;
    try t("abcde", 3, "...");
    try t("abcde", 5, "abcde");
    try t("abcde", 4, "...e");
    try t("abcdefgh", 6, "a...gh");
    try t("abcdefgh", 7, "ab...gh");
    try t("ＡＢＣＤＥＦＧＨ", 16, "ＡＢＣＤＥＦＧＨ");
    try t("ＡＢＣＤＥＦＧＨ", 7, "Ａ...Ｈ");
    try t("ＡＢＣＤＥＦＧＨ", 8, "Ａ...Ｈ");
    try t("ＡＢＣＤＥＦＧＨ", 9, "Ａ...ＧＨ");
    try t("ＡaＢＣＤＥＦＧＨ", 8, "Ａ...Ｈ"); // could optimize this, but w/e
    try t("ＡＢＣＤＥＦＧaＨ", 8, "Ａ...aＨ");
    try t("ＡＢＣＤＥＦＧＨ", 15, "ＡＢＣ...ＦＧＨ");
    try t("❤︎a❤︎a❤︎a", 5, "❤︎...︎a"); // Variation selectors; not great, there's an additional U+FE0E before 'a'.
    try t("ą́ą́ą́ą́ą́ą́", 5, "ą́...̨́ą́"); // Combining marks, similarly bad.
}

// ncurses_refs.c
extern fn ncdu_acs_ulcorner() c.chtype;
extern fn ncdu_acs_llcorner() c.chtype;
extern fn ncdu_acs_urcorner() c.chtype;
extern fn ncdu_acs_lrcorner() c.chtype;
extern fn ncdu_acs_hline()    c.chtype;
extern fn ncdu_acs_vline()    c.chtype;

const StyleAttr = struct { fg: i16, bg: i16, attr: u32 };
const StyleDef = struct {
    name: []const u8,
    off: StyleAttr,
    dark: StyleAttr,
    darkbg: StyleAttr,
    fn style(self: *const @This()) StyleAttr {
        return switch (main.config.ui_color) {
            .off => self.off,
            .dark => self.dark,
            .darkbg => self.darkbg,
        };
    }
};

const styles = [_]StyleDef{
    .{  .name   = "default",
        .off    = .{ .fg = -1,              .bg = -1,             .attr = 0 },
        .dark   = .{ .fg = -1,              .bg = -1,             .attr = 0 },
        .darkbg = .{ .fg = c.COLOR_WHITE,   .bg = c.COLOR_BLACK,  .attr = 0 } },
    .{  .name   = "bold",
        .off    = .{ .fg = -1,              .bg = -1,             .attr = c.A_BOLD },
        .dark   = .{ .fg = -1,              .bg = -1,             .attr = c.A_BOLD },
        .darkbg = .{ .fg = c.COLOR_WHITE,   .bg = c.COLOR_BLACK,  .attr = c.A_BOLD } },
    .{  .name   = "bold_hd",
        .off    = .{ .fg = -1,              .bg = -1,             .attr = c.A_BOLD|c.A_REVERSE },
        .dark   = .{ .fg = c.COLOR_BLACK,   .bg = c.COLOR_CYAN,   .attr = c.A_BOLD },
        .darkbg = .{ .fg = c.COLOR_BLACK,   .bg = c.COLOR_CYAN,   .attr = c.A_BOLD } },
    .{  .name   = "box_title",
        .off    = .{ .fg = -1,              .bg = -1,             .attr = c.A_BOLD },
        .dark   = .{ .fg = c.COLOR_BLUE,    .bg = -1,             .attr = c.A_BOLD },
        .darkbg = .{ .fg = c.COLOR_BLUE,    .bg = c.COLOR_BLACK,  .attr = c.A_BOLD } },
    .{  .name   = "hd", // header + footer
        .off    = .{ .fg = -1,              .bg = -1,             .attr = c.A_REVERSE },
        .dark   = .{ .fg = c.COLOR_BLACK,   .bg = c.COLOR_CYAN,   .attr = 0 },
        .darkbg = .{ .fg = c.COLOR_BLACK,   .bg = c.COLOR_CYAN,   .attr = 0 } },
    .{  .name   = "sel",
        .off    = .{ .fg = -1,              .bg = -1,             .attr = c.A_REVERSE },
        .dark   = .{ .fg = c.COLOR_WHITE,   .bg = c.COLOR_GREEN,  .attr = c.A_BOLD },
        .darkbg = .{ .fg = c.COLOR_WHITE,   .bg = c.COLOR_GREEN,  .attr = c.A_BOLD } },
    .{  .name   = "num",
        .off    = .{ .fg = -1,              .bg = -1,             .attr = 0 },
        .dark   = .{ .fg = c.COLOR_YELLOW,  .bg = -1,             .attr = c.A_BOLD },
        .darkbg = .{ .fg = c.COLOR_YELLOW,  .bg = c.COLOR_BLACK,  .attr = c.A_BOLD } },
    .{  .name   = "num_hd",
        .off    = .{ .fg = -1,              .bg = -1,             .attr = c.A_REVERSE },
        .dark   = .{ .fg = c.COLOR_YELLOW,  .bg = c.COLOR_CYAN,   .attr = c.A_BOLD },
        .darkbg = .{ .fg = c.COLOR_YELLOW,  .bg = c.COLOR_CYAN,   .attr = c.A_BOLD } },
    .{  .name   = "num_sel",
        .off    = .{ .fg = -1,              .bg = -1,             .attr = c.A_REVERSE },
        .dark   = .{ .fg = c.COLOR_YELLOW,  .bg = c.COLOR_GREEN,  .attr = c.A_BOLD },
        .darkbg = .{ .fg = c.COLOR_YELLOW,  .bg = c.COLOR_GREEN,  .attr = c.A_BOLD } },
    .{  .name   = "key",
        .off    = .{ .fg = -1,              .bg = -1,             .attr = c.A_BOLD },
        .dark   = .{ .fg = c.COLOR_YELLOW,  .bg = -1,             .attr = c.A_BOLD },
        .darkbg = .{ .fg = c.COLOR_YELLOW,  .bg = c.COLOR_BLACK,  .attr = c.A_BOLD } },
    .{  .name   = "key_hd",
        .off    = .{ .fg = -1,              .bg = -1,             .attr = c.A_BOLD|c.A_REVERSE },
        .dark   = .{ .fg = c.COLOR_YELLOW,  .bg = c.COLOR_CYAN,   .attr = c.A_BOLD },
        .darkbg = .{ .fg = c.COLOR_YELLOW,  .bg = c.COLOR_CYAN,   .attr = c.A_BOLD } },
    .{  .name   = "dir",
        .off    = .{ .fg = -1,              .bg = -1,             .attr = 0 },
        .dark   = .{ .fg = c.COLOR_BLUE,    .bg = -1,             .attr = c.A_BOLD },
        .darkbg = .{ .fg = c.COLOR_BLUE,    .bg = c.COLOR_BLACK,  .attr = c.A_BOLD } },
    .{  .name   = "dir_sel",
        .off    = .{ .fg = -1,              .bg = -1,             .attr = c.A_REVERSE },
        .dark   = .{ .fg = c.COLOR_BLUE,    .bg = c.COLOR_GREEN,  .attr = c.A_BOLD },
        .darkbg = .{ .fg = c.COLOR_BLUE,    .bg = c.COLOR_GREEN,  .attr = c.A_BOLD } },
    .{  .name   = "flag",
        .off    = .{ .fg = -1,              .bg = -1,             .attr = 0 },
        .dark   = .{ .fg = c.COLOR_RED,     .bg = -1,             .attr = 0 },
        .darkbg = .{ .fg = c.COLOR_RED,     .bg = c.COLOR_BLACK,  .attr = 0 } },
    .{  .name   = "flag_sel",
        .off    = .{ .fg = -1,              .bg = -1,             .attr = c.A_REVERSE },
        .dark   = .{ .fg = c.COLOR_RED,     .bg = c.COLOR_GREEN,  .attr = 0 },
        .darkbg = .{ .fg = c.COLOR_RED,     .bg = c.COLOR_GREEN,  .attr = 0 } },
    .{  .name   = "graph",
        .off    = .{ .fg = -1,              .bg = -1,             .attr = 0 },
        .dark   = .{ .fg = c.COLOR_MAGENTA, .bg = -1,             .attr = 0 },
        .darkbg = .{ .fg = c.COLOR_MAGENTA, .bg = c.COLOR_BLACK,  .attr = 0 } },
    .{  .name   = "graph_sel",
        .off    = .{ .fg = -1,              .bg = -1,             .attr = c.A_REVERSE },
        .dark   = .{ .fg = c.COLOR_MAGENTA, .bg = c.COLOR_GREEN,  .attr = 0 },
        .darkbg = .{ .fg = c.COLOR_MAGENTA, .bg = c.COLOR_GREEN,  .attr = 0 } },
};

pub const Style = lbl: {
    comptime var fields: [styles.len]std.builtin.Type.EnumField = undefined;
    inline for (&fields, styles, 0..) |*field, s, i| {
        field.* = .{
            .name = s.name,
            .value = i,
        };
    }
    break :lbl @Type(.{
        .Enum = .{
            .tag_type = u8,
            .fields = &fields,
            .decls = &[_]std.builtin.Type.Declaration{},
            .is_exhaustive = true,
        }
    });
};

const ui = @This();

pub const Bg = enum {
    default, hd, sel,

    // Set the style to the selected bg combined with the given fg.
    pub fn fg(self: @This(), s: Style) void {
        ui.style(switch (self) {
            .default => s,
            .hd =>
                switch (s) {
                    .default => Style.hd,
                    .key => Style.key_hd,
                    .num => Style.num_hd,
                    else => unreachable,
                },
            .sel =>
                switch (s) {
                    .default => Style.sel,
                    .num => Style.num_sel,
                    .dir => Style.dir_sel,
                    .flag => Style.flag_sel,
                    .graph => Style.graph_sel,
                    else => unreachable,
                }
        });
    }
};

fn updateSize() void {
    // getmax[yx] macros are marked as "legacy", but Zig can't deal with the "proper" getmaxyx macro.
    rows = @intCast(c.getmaxy(c.stdscr));
    cols = @intCast(c.getmaxx(c.stdscr));
}

fn clearScr() void {
    // Send a "clear from cursor to end of screen" instruction, to clear a
    // potential line left behind from scanning in -1 mode.
    const stderr = std.io.getStdErr();
    stderr.writeAll("\x1b[J") catch {};
}

pub fn init() void {
    if (inited) return;
    clearScr();
    if (main.config.nc_tty) {
        var tty = c.fopen("/dev/tty", "r+");
        if (tty == null) die("Error opening /dev/tty: {s}.\n", .{ c.strerror(@intFromEnum(std.c.getErrno(-1))) });
        var term = c.newterm(null, tty, tty);
        if (term == null) die("Error initializing ncurses.\n", .{});
        _ = c.set_term(term);
    } else {
        if (c.initscr() == null) die("Error initializing ncurses.\n", .{});
    }
    updateSize();
    _ = c.cbreak();
    _ = c.noecho();
    _ = c.curs_set(0);
    _ = c.keypad(c.stdscr, true);

    _ = c.start_color();
    _ = c.use_default_colors();
    for (styles, 0..) |s, i| _ = c.init_pair(@as(i16, @intCast(i+1)), s.style().fg, s.style().bg);
    _ = c.bkgd(@intCast(c.COLOR_PAIR(@intFromEnum(Style.default)+1)));
    inited = true;
}

pub fn deinit() void {
    if (!inited) {
        clearScr();
        return;
    }
    _ = c.erase();
    _ = c.refresh();
    _ = c.endwin();
    inited = false;
}

pub fn style(s: Style) void {
    _ = c.attr_set(styles[@intFromEnum(s)].style().attr, @intFromEnum(s)+1, null);
}

pub fn move(y: u32, x: u32) void {
    _ = c.move(@as(i32, @intCast(y)), @as(i32, @intCast(x)));
}

// Wraps to the next line if the text overflows, not sure how to disable that.
// (Well, addchstr() does that, but not entirely sure I want to go that way.
// Does that even work with UTF-8? Or do I really need to go wchar madness?)
pub fn addstr(s: [:0]const u8) void {
    _ = c.addstr(s.ptr);
}

// Not to be used for strings that may end up >256 bytes.
pub fn addprint(comptime fmt: []const u8, args: anytype) void {
    var buf: [256:0]u8 = undefined;
    const s = std.fmt.bufPrintZ(&buf, fmt, args) catch unreachable;
    addstr(s);
}

pub fn addch(ch: c.chtype) void {
    _ = c.addch(ch);
}

// Format an integer to a human-readable size string.
//   num() = "###.#"
//   unit = " XB" or " XiB"
// Concatenated, these take 8 columns in SI mode or 9 otherwise.
pub const FmtSize = struct {
    buf: [8:0]u8,
    unit: [:0]const u8,

    pub fn fmt(v: u64) @This() {
        var r: @This() = undefined;
        var f: f32 = @floatFromInt(v);
        if (main.config.si) {
            if(f < 1000.0)    { r.unit = "  B"; }
            else if(f < 1e6)  { r.unit = " KB"; f /= 1e3;  }
            else if(f < 1e9)  { r.unit = " MB"; f /= 1e6;  }
            else if(f < 1e12) { r.unit = " GB"; f /= 1e9;  }
            else if(f < 1e15) { r.unit = " TB"; f /= 1e12; }
            else if(f < 1e18) { r.unit = " PB"; f /= 1e15; }
            else              { r.unit = " EB"; f /= 1e18; }
        }
        else {
            if(f < 1000.0)       { r.unit = "   B"; }
            else if(f < 1023e3)  { r.unit = " KiB"; f /= 1024.0; }
            else if(f < 1023e6)  { r.unit = " MiB"; f /= 1048576.0; }
            else if(f < 1023e9)  { r.unit = " GiB"; f /= 1073741824.0; }
            else if(f < 1023e12) { r.unit = " TiB"; f /= 1099511627776.0; }
            else if(f < 1023e15) { r.unit = " PiB"; f /= 1125899906842624.0; }
            else                 { r.unit = " EiB"; f /= 1152921504606846976.0; }
        }
        _ = std.fmt.bufPrintZ(&r.buf, "{d:>5.1}", .{f}) catch unreachable;
        return r;
    }

    pub fn num(self: *const @This()) [:0]const u8 {
        return std.mem.sliceTo(&self.buf, 0);
    }
};

// Print a formatted human-readable size string onto the given background.
pub fn addsize(bg: Bg, v: u64) void {
    const r = FmtSize.fmt(v);
    bg.fg(.num);
    addstr(r.num());
    bg.fg(.default);
    addstr(r.unit);
}

// Print a full decimal number with thousand separators.
// Max: 18,446,744,073,709,551,615 -> 26 columns
// (Assuming thousands_sep takes a single column)
pub fn addnum(bg: Bg, v: u64) void {
    var buf: [32]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}", .{v}) catch unreachable;
    var f: [64:0]u8 = undefined;
    var i: usize = 0;
    for (s, 0..) |digit, n| {
        if (n != 0 and (s.len - n) % 3 == 0) {
            for (main.config.thousands_sep) |ch| {
                f[i] = ch;
                i += 1;
            }
        }
        f[i] = digit;
        i += 1;
    }
    f[i] = 0;
    bg.fg(.num);
    addstr(&f);
    bg.fg(.default);
}

// Print a file mode, takes 10 columns
pub fn addmode(mode: u32) void {
    addch(switch (mode & std.os.S.IFMT) {
        std.os.S.IFDIR  => 'd',
        std.os.S.IFREG  => '-',
        std.os.S.IFLNK  => 'l',
        std.os.S.IFIFO  => 'p',
        std.os.S.IFSOCK => 's',
        std.os.S.IFCHR  => 'c',
        std.os.S.IFBLK  => 'b',
        else => '?'
    });
    addch(if (mode &  0o400 > 0) 'r' else '-');
    addch(if (mode &  0o200 > 0) 'w' else '-');
    addch(if (mode & 0o4000 > 0) 's' else if (mode & 0o100 > 0) @as(u7, 'x') else '-');
    addch(if (mode &  0o040 > 0) 'r' else '-');
    addch(if (mode &  0o020 > 0) 'w' else '-');
    addch(if (mode & 0o2000 > 0) 's' else if (mode & 0o010 > 0) @as(u7, 'x') else '-');
    addch(if (mode &  0o004 > 0) 'r' else '-');
    addch(if (mode &  0o002 > 0) 'w' else '-');
    addch(if (mode & 0o1000 > 0) (if (std.os.S.ISDIR(mode)) @as(u7, 't') else 'T') else if (mode & 0o001 > 0) @as(u7, 'x') else '-');
}

// Print a timestamp, takes 25 columns
pub fn addts(bg: Bg, ts: u64) void {
    const t = util.castClamp(c.time_t, ts);
    var buf: [32:0]u8 = undefined;
    const len = c.strftime(&buf, buf.len, "%Y-%m-%d %H:%M:%S %z", c.localtime(&t));
    if (len > 0) {
        bg.fg(.num);
        ui.addstr(buf[0..len:0]);
    } else {
        bg.fg(.default);
        ui.addstr("            invalid mtime");
    }
}

pub fn hline(ch: c.chtype, len: u32) void {
    _ = c.hline(ch, @as(i32, @intCast(len)));
}

// Draws a bordered box in the center of the screen.
pub const Box = struct {
    start_row: u32,
    start_col: u32,

    const Self = @This();

    pub fn create(height: u32, width: u32, title: [:0]const u8) Self {
        const s = Self{
            .start_row = (rows>>1) -| (height>>1),
            .start_col = (cols>>1) -| (width>>1),
        };
        style(.default);
        if (width < 6 or height < 3) return s;

        const ulcorner = ncdu_acs_ulcorner();
        const llcorner = ncdu_acs_llcorner();
        const urcorner = ncdu_acs_urcorner();
        const lrcorner = ncdu_acs_lrcorner();
        const acs_hline = ncdu_acs_hline();
        const acs_vline = ncdu_acs_vline();

        var i: u32 = 0;
        while (i < height) : (i += 1) {
            s.move(i, 0);
            addch(if (i == 0) ulcorner else if (i == height-1) llcorner else acs_hline);
            hline(if (i == 0 or i == height-1) acs_vline else ' ', width-2);
            s.move(i, width-1);
            addch(if (i == 0) urcorner else if (i == height-1) lrcorner else acs_hline);
        }

        s.move(0, 3);
        style(.box_title);
        addch(' ');
        addstr(title);
        addch(' ');
        style(.default);
        return s;
    }

    pub fn tab(s: Self, col: u32, sel: bool, num: u3, label: [:0]const u8) void {
        const bg: Bg = if (sel) .hd else .default;
        s.move(0, col);
        bg.fg(.key);
        addch('0' + @as(u8, num));
        bg.fg(.default);
        addch(':');
        addstr(label);
        style(.default);
    }

    // Move the global cursor to the given coordinates inside the box.
    pub fn move(s: Self, row: u32, col: u32) void {
        ui.move(s.start_row + row, s.start_col + col);
    }
};

// Returns 0 if no key was pressed in non-blocking mode.
// Returns -1 if it was KEY_RESIZE, requiring a redraw of the screen.
pub fn getch(block: bool) i32 {
    _ = c.nodelay(c.stdscr, !block);
    // getch() has a bad tendency to not set a sensible errno when it returns ERR.
    // In non-blocking mode, we can only assume that ERR means "no input yet".
    // In blocking mode, give it 100 tries with a 10ms delay in between,
    // then just give up and die to avoid an infinite loop and unresponsive program.
    for (0..100) |_| {
        const ch = c.getch();
        if (ch == c.KEY_RESIZE) {
            updateSize();
            return -1;
        }
        if (ch == c.ERR) {
            if (!block) return 0;
            std.time.sleep(10*std.time.ns_per_ms);
            continue;
        }
        return ch;
    }
    die("Error reading keyboard input, assuming TTY has been lost.\n(Potentially nonsensical error message: {s})\n",
        .{ c.strerror(@intFromEnum(std.c.getErrno(-1))) });
}
