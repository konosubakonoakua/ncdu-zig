<!--
SPDX-FileCopyrightText: Yorhel <projects@yorhel.nl>
SPDX-License-Identifier: MIT
-->

# ncdu-zig

## Description
![ncdu screenshot](https://github.com/konosubakonoakua/ncdu-zig/releases/download/screenshots/ncdu.png)

Ncdu is a disk usage analyzer with an ncurses interface. It is designed to find
space hogs on a remote server where you don't have an entire graphical setup
available, but it is a useful tool even on regular desktop systems. Ncdu aims
to be fast, simple and easy to use, and should be able to run in any minimal
POSIX-like environment with ncurses installed.

See the [ncdu 2 release announcement](https://dev.yorhel.nl/doc/ncdu2) for
information about the differences between this Zig implementation (2.x) and the
C version (1.x).

## Requirements

- Zig 0.12.0
- Some sort of POSIX-like OS
- ncurses libraries and header files

## Install

You can use the Zig build system if you're familiar with that.

There's also a handy Makefile that supports the typical targets, e.g.:

```
make
sudo make install PREFIX=/usr
```

## Caution
> [!IMPORTANT]
> This repo is upload from https://dev.yorhel.nl/ncdu, maybe diverged from the origin.

## Similar projects
- [Duc](http://duc.zevv.nl/) - Multiple user interfaces.
- [gt5](http://gt5.sourceforge.net/) - Quite similar to ncdu, but a different approach.
- [gdu](https://github.com/dundee/gdu) - Go disk usage analyzer inspired by ncdu.
- [dua](https://github.com/Byron/dua-cli) - Rust disk usage analyzer with a CLI.
- [diskonaut](https://github.com/imsnif/diskonaut) - Rust disk usage analyzer with a TUI.
- [godu](https://github.com/viktomas/godu) - Another Go disk usage analyzer, with a slightly different browser UI.
- [tdu](https://bitbucket.org/josephpaul0/tdu) - Go command-line tool with ncdu JSON export.
- [TreeSize](http://treesize.sourceforge.net/) - GTK, using a treeview.
- [Baobab](http://www.marzocca.net/linux/baobab.html) - GTK, using pie-charts, a treeview and a treemap. Comes with GNOME.
- [GdMap](http://gdmap.sourceforge.net/) - GTK, with a treemap display.
- [Filelight](https://apps.kde.org/filelight/) - KDE, using pie-charts.
- [QDirStat](https://github.com/shundhammer/qdirstat) - Qt, with a treemap display.
- [K4DirStat](https://github.com/jeromerobert/k4dirstat) - Qt, treemap.
- [xdiskusage](http://xdiskusage.sourceforge.net/) - FLTK, with a treemap display.
- [fsv](http://fsv.sourceforge.net/) - 3D visualization.
