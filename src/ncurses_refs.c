/* SPDX-FileCopyrightText: 2021-2023 Yoran Heling <projects@yorhel.nl>
 * SPDX-License-Identifier: MIT
 */

#include <curses.h>

/* Zig @cImport() has problems with the ACS_* macros. Two, in fact:
 *
 * 1. Naively using the ACS_* macros results in:
 *
 *      error: cannot store runtime value in compile time variable
 *      return acs_map[NCURSES_CAST(u8, c)];
 *                    ^
 *    That error doesn't make much sense to me, but it might be
 *    related to https://github.com/ziglang/zig/issues/5344?
 *
 * 2. The 'acs_map' extern variable isn't being linked correctly?
 *    Haven't investigated this one deeply enough yet, but attempting
 *    to dereference acs_map from within Zig leads to a segfault;
 *    its pointer value doesn't make any sense.
 */
chtype ncdu_acs_ulcorner() { return ACS_ULCORNER; }
chtype ncdu_acs_llcorner() { return ACS_LLCORNER; }
chtype ncdu_acs_urcorner() { return ACS_URCORNER; }
chtype ncdu_acs_lrcorner() { return ACS_LRCORNER; }
chtype ncdu_acs_hline()    { return ACS_VLINE   ; }
chtype ncdu_acs_vline()    { return ACS_HLINE   ; }
