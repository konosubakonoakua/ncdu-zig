#!/usr/bin/perl
# SPDX-FileCopyrightText: Yorhel <projects@yorhel.nl>
# SPDX-License-Identifier: MIT


# Usage: ncdubinexp.pl [options] <export.ncdu
# Or: ncdu -O- | ncdubinexp.pl [options]
#
# Reads and validates a binary ncdu export file and optionally prints out
# various diagnostic data and statistics.
#
# Options:
#   blocks    - print a listing of all blocks as they are read
#   items     - print a listing of all items as they are read
#   dirs      - print out dir listing stats
#   stats     - print some overview stats
#
# This script is highly inefficient in both RAM and CPU, not suitable for large
# exports.
# This script does not permit unknown blocks or item keys, although that is
# technically valid.


use v5.36;
use autodie;
use bytes;
no warnings 'portable';
use List::Util 'min', 'max';
use CBOR::XS;  # Does not officially support recent perl versions, but it's the only CPAN module that supports streaming.
use Compress::Zstd;

my $printblocks = grep $_ eq 'blocks', @ARGV;
my $printitems = grep $_ eq 'items', @ARGV;
my $printdirs = grep $_ eq 'dirs', @ARGV;
my $printstats = grep $_ eq 'stats', @ARGV;

my %datablocks;
my %items;
my $root_itemref;
my $datablock_len = 0;
my $rawdata_len = 0;
my $minitemsperblock = 1e10;
my $maxitemsperblock = 0;

{
    die "Input too short\n" if 8 != read STDIN, my $sig, 8;
    die "Invalid file signature\n" if $sig ne "\xbfncduEX1";
}

my @itemkeys = qw/
    type
    name
    prev
    asize
    dsize
    dev
    rderr
    cumasize
    cumdsize
    shrasize
    shrdsize
    items
    sub
    ino
    nlink
    uid
    gid
    mode
    mtime
/;


sub datablock($prefix, $off, $blklen, $content) {
    die "$prefix: Data block too small\n" if length $content < 8;
    die "$prefix: Data block too large\n" if length $content >= (1<<24);

    my $num = unpack 'N', $content;
    die sprintf "%s: Duplicate block id %d (first at %010x)", $prefix, $num, $datablocks{$num}>>24 if $datablocks{$num};
    $datablocks{$num} = ($off << 24) | $blklen;

    my $compressed = substr $content, 4;
    my $rawdata = decompress($compressed);
    die "$prefix: Block id $num failed decompression\n" if !defined $rawdata;
    die "$prefix: Uncompressed data block size too large\n" if length $rawdata >= (1<<24);

    $printblocks && printf "%s: data block %d  rawlen %d (%.2f)\n", $prefix, $num, length($rawdata), length($compressed)/length($rawdata)*100;

    $datablock_len += length($compressed);
    $rawdata_len += length($rawdata);

    cbordata($num, $rawdata);
}


sub fmtitem($val) {
    join '  ', map "$_:$val->{$_}", grep exists $val->{$_}, @itemkeys;
}


sub cbordata($blknum, $data) {
    my $cbor = CBOR::XS->new_safe;
    my $off = 0;
    my $nitems = 0;
    while ($off < length $data) { # This substr madness is prolly quite slow
        my($val, $len) = $cbor->decode_prefix(substr $data, $off);
        my $itemref = ($blknum << 24) | $off;
        $off += $len;
        $nitems++;

        # Basic validation of the CBOR data. Doesn't validate that every value
        # has the correct CBOR type or that integers are within range.
        $val = { _itemref => $itemref, map {
            die sprintf "#%010x: Invalid CBOR key '%s'\n", $itemref, $_ if !/^[0-9]+$/ || !$itemkeys[$_];
            my($k, $v) = ($itemkeys[$_], $val->{$_});
            die sprintf "#%010x: Invalid value for key '%s': '%s'\n", $itemref, $k, $v
                if ref $v eq 'ARRAY' || ref $v eq 'HASH' || !defined $v || !(
                    $k eq 'type' ? ($v =~ /^(-[1-4]|[0-3])$/) :
                    $k eq 'prev' || $k eq 'sub' || $k eq 'prevlnk' ? 1 : # itemrefs are validated separately
                    $k eq 'name' ? length $v :
                    $k eq 'rderr' ? Types::Serialiser::is_bool($v) :
                    /^[0-9]+$/
                );
            ($k,$v)
        } keys %$val };

        $printitems && printf "#%010x: %s\n", $itemref, fmtitem $val;
        $items{$itemref} = $val;
    }
    $minitemsperblock = $nitems if $minitemsperblock > $nitems;
    $maxitemsperblock = $nitems if $maxitemsperblock < $nitems;
}


sub indexblock($prefix, $content) {
    $printblocks && print "$prefix: index block\n";

    my $maxnum = max keys %datablocks;
    die "$prefix: index block size incorrect for $maxnum+1 data blocks\n" if length($content) != 8*($maxnum+1) + 8;

    my @ints = unpack 'Q>*', $content;
    $root_itemref = pop @ints;

    for my $i (0..$#ints-1) {
        if (!$datablocks{$i}) {
            die "$prefix: index entry for missing block (#$i) must be 0\n" if $ints[$i] != 0;
        } else {
            die sprintf "%s: invalid index entry for block #%d (got %016x expected %016x)\n",
                $prefix, $i, $ints[$i], $datablocks{$i}
                if $ints[$i] != $datablocks{$i};
        }
    }
}


while (1) {
    my $off = tell STDIN;
    my $prefix = sprintf '%010x', $off;
    die "$prefix Input too short, expected block header\n" if 4 != read STDIN, my $blkhead, 4;
    $blkhead = unpack 'N', $blkhead;
    my $blkid = $blkhead >> 28;
    my $blklen = $blkhead & 0x0fffffff;

    $prefix .= "[$blklen]";
    die "$prefix: Short read on block content\n" if $blklen - 8 != read STDIN, my $content, $blklen - 8;
    die "$prefix: Input too short, expected block footer\n" if 4 != read STDIN, my $blkfoot, 4;
    die "$prefix: Block footer does not match header\n" if $blkhead != unpack 'N', $blkfoot;

    if ($blkid == 0) {
        datablock($prefix, $off, $blklen, $content);
    } elsif ($blkid == 1) {
        indexblock($prefix, $content);
        last;
    } else {
        die "$prefix Unknown block id $blkid\n";
    }
}

{
    die sprintf "0x%08x: Data after index block\n", tell(STDIN) if 0 != read STDIN, my $x, 1;
}



# Each item must be referenced exactly once from either a 'prev' or 'sub' key,
# $nodup verifies the "at most once" part.
sub resolve($cur, $key, $nodup) {
    my $ref = exists $cur->{$key} ? $cur->{$key} : return;
    my $item = $ref < 0
        ? ($items{ $cur->{_itemref} + $ref } || die sprintf "#%010x: Invalid relative itemref %s: %d\n", $cur->{_itemref}, $key, $ref)
        : ($items{$ref} || die sprintf "#%010x: Invalid reference %s to #%010x\n", $cur->{_itemref}, $key, $ref);
    die sprintf "Item #%010x referenced more than once, from #%010x and #%010x\n", $item->{_itemref}, $item->{_lastseen}, $cur->{_itemref}
        if $nodup && defined $item->{_lastseen};
    $item->{_lastseen} = $cur->{_itemref} if $nodup;
    return $item;
}

my @dirblocks; # [ path, nitems, nblocks ]
my %dirblocks; # nblocks => ndirs

sub traverse($parent, $path) {
    my $sub = resolve($parent, 'sub', 1);
    my %blocks;
    my $items = 0;
    while ($sub) {
        $items++;
        $blocks{ $sub->{_itemref} >> 24 }++;
        traverse($sub, "$path/$sub->{name}") if $sub->{type} == 0;
        $sub = resolve($sub, 'prev', 1);
    }
    push @dirblocks, [ $path, $items, scalar keys %blocks ] if scalar keys %blocks > 1;
    $dirblocks{ keys %blocks }++ if $items > 0;
    $items && $printdirs && printf "#%010x: %d items in %d blocks (%d .. %d)  %s\n",
        $parent->{_itemref}, $items, scalar keys %blocks,
        min(values %blocks), max(values %blocks), $path;
}


{
    my $root = $items{$root_itemref} || die sprintf "Invalid root itemref: %010x\n", $root_itemref;
    $root->{_lastseen} = 0xffffffffff;
    traverse($root, $root->{name});

    my($noref) = grep !$_->{_lastseen}, values %items;
    die sprintf "No reference found to #%010x\n", $noref->{_itemref} if $noref;
}

if ($printstats) {
    my $nblocks = keys %datablocks;
    my $nitems = keys %items;
    printf "     Total items: %d\n", $nitems;
    printf "    Total blocks: %d\n", $nblocks;
    printf " Items per block: %.1f (%d .. %d)\n", $nitems / $nblocks, $minitemsperblock, $maxitemsperblock;
    printf "  Avg block size: %d compressed, %d raw (%.1f)\n", $datablock_len/$nblocks, $rawdata_len/$nblocks, $datablock_len/$rawdata_len*100;
    printf "   Avg item size: %.1f compressed, %.1f raw\n", $datablock_len/$nitems, $rawdata_len/$nitems;

    @dirblocks = sort { $b->[2] <=> $a->[2] } @dirblocks;
    print "\nBlocks per directory listing histogram\n";
    printf "  %5d %6d\n", $_, $dirblocks{$_} for sort { $a <=> $b } keys %dirblocks;
    print "\nMost blocks per directory listing\n";
    print "     items blks  path\n";
    printf "%10d %4d  %s\n", @{$dirblocks[$_]}[1,2,0] for (0..min 9, $#dirblocks);
}
