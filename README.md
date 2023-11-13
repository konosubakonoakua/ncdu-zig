<!--
SPDX-FileCopyrightText: 2021-2023 Yoran Heling <projects@yorhel.nl>
SPDX-License-Identifier: MIT
-->

# ncdu-zig

## Description

Ncdu is a disk usage analyzer with an ncurses interface. It is designed to find
space hogs on a remote server where you don't have an entire graphical setup
available, but it is a useful tool even on regular desktop systems. Ncdu aims
to be fast, simple and easy to use, and should be able to run in any minimal
POSIX-like environment with ncurses installed.

See the [ncdu 2 release announcement](https://dev.yorhel.nl/doc/ncdu2) for
information about the differences between this Zig implementation (2.x) and the
C version (1.x).

## Requirements

- Zig 0.11.0
- Some sort of POSIX-like OS
- ncurses libraries and header files

## Install

You can use the Zig build system if you're familiar with that.

There's also a handy Makefile that supports the typical targets, e.g.:

```
make
sudo make install PREFIX=/usr
```
