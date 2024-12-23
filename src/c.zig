// SPDX-FileCopyrightText: Yorhel <projects@yorhel.nl>
// SPDX-License-Identifier: MIT

pub const c = @cImport({
    @cDefine("_XOPEN_SOURCE", "1"); // for wcwidth()
    @cInclude("stdio.h"); // fopen(), used to initialize ncurses
    @cInclude("string.h"); // strerror()
    @cInclude("time.h"); // strftime()
    @cInclude("wchar.h"); // wcwidth()
    @cInclude("locale.h"); // setlocale() and localeconv()
    @cInclude("fnmatch.h"); // fnmatch()
    @cInclude("unistd.h"); // getuid()
    @cInclude("sys/types.h"); // struct passwd
    @cInclude("pwd.h"); // getpwnam(), getpwuid()
    if (@import("builtin").os.tag == .linux) {
        @cInclude("sys/vfs.h"); // statfs()
    }
    @cInclude("curses.h");
    @cInclude("zstd.h");
});
