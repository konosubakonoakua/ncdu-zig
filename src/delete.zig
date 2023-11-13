// SPDX-FileCopyrightText: 2021-2023 Yoran Heling <projects@yorhel.nl>
// SPDX-License-Identifier: MIT

const std = @import("std");
const main = @import("main.zig");
const model = @import("model.zig");
const ui = @import("ui.zig");
const browser = @import("browser.zig");
const util = @import("util.zig");

var parent: *model.Dir = undefined;
var entry: *model.Entry = undefined;
var next_sel: ?*model.Entry = undefined; // Which item to select if deletion succeeds
var state: enum { confirm, busy, err } = .confirm;
var confirm: enum { yes, no, ignore } = .no;
var error_option: enum { abort, ignore, all } = .abort;
var error_code: anyerror = undefined;

pub fn setup(p: *model.Dir, e: *model.Entry, n: ?*model.Entry) void {
    parent = p;
    entry = e;
    next_sel = n;
    state = if (main.config.confirm_delete) .confirm else .busy;
    confirm = .no;
}


// Returns true to abort scanning.
fn err(e: anyerror) bool {
    if (main.config.ignore_delete_errors)
        return false;
    error_code = e;
    state = .err;

    while (main.state == .delete and state == .err)
        main.handleEvent(true, false);

    return main.state != .delete;
}

fn deleteItem(dir: std.fs.Dir, path: [:0]const u8, ptr: *align(1) ?*model.Entry) bool {
    entry = ptr.*.?;
    main.handleEvent(false, false);
    if (main.state != .delete)
        return true;

    if (entry.dir()) |d| {
        var fd = dir.openDirZ(path, .{.no_follow = true}, false) catch |e| return err(e);
        var it = &d.sub;
        parent = d;
        defer parent = parent.parent.?;
        while (it.*) |n| {
            if (deleteItem(fd, n.name(), it)) {
                fd.close();
                return true;
            }
            if (it.* == n) // item deletion failed, make sure to still advance to next
                it = &n.next;
        }
        fd.close();
        dir.deleteDirZ(path) catch |e|
            return if (e != error.DirNotEmpty or d.sub == null) err(e) else false;
    } else
        dir.deleteFileZ(path) catch |e| return err(e);
    ptr.*.?.delStats(parent);
    ptr.* = ptr.*.?.next;
    return false;
}

// Returns the item that should be selected in the browser.
pub fn delete() ?*model.Entry {
    while (main.state == .delete and state == .confirm)
        main.handleEvent(true, false);
    if (main.state != .delete)
        return entry;

    // Find the pointer to this entry
    const e = entry;
    var it = &parent.sub;
    while (it.*) |n| : (it = &n.next)
        if (it.* == entry)
            break;

    var path = std.ArrayList(u8).init(main.allocator);
    defer path.deinit();
    parent.fmtPath(true, &path);
    if (path.items.len == 0 or path.items[path.items.len-1] != '/')
        path.append('/') catch unreachable;
    path.appendSlice(entry.name()) catch unreachable;

    _ = deleteItem(std.fs.cwd(), util.arrayListBufZ(&path), it);
    model.inodes.addAllStats();
    return if (it.* == e) e else next_sel;
}

fn drawConfirm() void {
    browser.draw();
    const box = ui.Box.create(6, 60, "Confirm delete");
    box.move(1, 2);
    ui.addstr("Are you sure you want to delete \"");
    ui.addstr(ui.shorten(ui.toUtf8(entry.name()), 21));
    ui.addch('"');
    if (entry.pack.etype != .dir)
        ui.addch('?')
    else {
        box.move(2, 18);
        ui.addstr("and all of its contents?");
    }

    box.move(4, 15);
    ui.style(if (confirm == .yes) .sel else .default);
    ui.addstr("yes");

    box.move(4, 25);
    ui.style(if (confirm == .no) .sel else .default);
    ui.addstr("no");

    box.move(4, 31);
    ui.style(if (confirm == .ignore) .sel else .default);
    ui.addstr("don't ask me again");
}

fn drawProgress() void {
    var path = std.ArrayList(u8).init(main.allocator);
    defer path.deinit();
    parent.fmtPath(false, &path);
    path.append('/') catch unreachable;
    path.appendSlice(entry.name()) catch unreachable;

    // TODO: Item counts and progress bar would be nice.

    const box = ui.Box.create(6, 60, "Deleting...");
    box.move(2, 2);
    ui.addstr(ui.shorten(ui.toUtf8(util.arrayListBufZ(&path)), 56));
    box.move(4, 41);
    ui.addstr("Press ");
    ui.style(.key);
    ui.addch('q');
    ui.style(.default);
    ui.addstr(" to abort");
}

fn drawErr() void {
    var path = std.ArrayList(u8).init(main.allocator);
    defer path.deinit();
    parent.fmtPath(false, &path);
    path.append('/') catch unreachable;
    path.appendSlice(entry.name()) catch unreachable;

    const box = ui.Box.create(6, 60, "Error");
    box.move(1, 2);
    ui.addstr("Error deleting ");
    ui.addstr(ui.shorten(ui.toUtf8(util.arrayListBufZ(&path)), 41));
    box.move(2, 4);
    ui.addstr(ui.errorString(error_code));

    box.move(4, 14);
    ui.style(if (error_option == .abort) .sel else .default);
    ui.addstr("abort");

    box.move(4, 23);
    ui.style(if (error_option == .ignore) .sel else .default);
    ui.addstr("ignore");

    box.move(4, 33);
    ui.style(if (error_option == .all) .sel else .default);
    ui.addstr("ignore all");
}

pub fn draw() void {
    switch (state) {
        .confirm => drawConfirm(),
        .busy => drawProgress(),
        .err => drawErr(),
    }
}

pub fn keyInput(ch: i32) void {
    switch (state) {
        .confirm => switch (ch) {
            'h', ui.c.KEY_LEFT => confirm = switch (confirm) {
                .ignore => .no,
                else => .yes,
            },
            'l', ui.c.KEY_RIGHT => confirm = switch (confirm) {
                .yes => .no,
                else => .ignore,
            },
            'q' => main.state = .browse,
            '\n' => switch (confirm) {
                .yes => state = .busy,
                .no => main.state = .browse,
                .ignore => {
                    main.config.confirm_delete = false;
                    state = .busy;
                },
            },
            else => {}
        },
        .busy => {
            if (ch == 'q')
                main.state = .browse;
        },
        .err => switch (ch) {
            'h', ui.c.KEY_LEFT => error_option = switch (error_option) {
                .all => .ignore,
                else => .abort,
            },
            'l', ui.c.KEY_RIGHT => error_option = switch (error_option) {
                .abort => .ignore,
                else => .all,
            },
            'q' => main.state = .browse,
            '\n' => switch (error_option) {
                .abort => main.state = .browse,
                .ignore => state = .busy,
                .all => {
                    main.config.ignore_delete_errors = true;
                    state = .busy;
                },
            },
            else => {}
        },
    }
}
