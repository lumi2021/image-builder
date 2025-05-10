const std = @import("std");
const Build = std.Build;
const fs = std.fs;

const datetime = @import("../deps/zig-datetime/main.zig");

const imageBuilder = @import("../imageBuilder.zig");
const Partition = imageBuilder.Partition;

const gotoSector = imageBuilder.gotoSector;
const gotoOffset = imageBuilder.gotoOffset;
const writeI = imageBuilder.writeI;
const SAlloc = imageBuilder.SectorAllocator;

pub fn writePartition(b: *Build, p: *std.Progress.Node, f: fs.File, partition: *Partition) void {
    var n = p.start("Detecting format", 1);

    const total_sectors = partition.size;
    const bytes_per_sector = 512;
    const sectors_per_cluster = 1;
    const num_fats = 2;
    var reserved_sectors: usize = 1;
    var max_root_dir_entries: usize = 512;

    var sectors_per_fat: usize = 1;
    var cluster_count: usize = undefined;
    var cluster_bit_size: usize = undefined;
    var fat_fs: FatFS = undefined;

    // FIXME refactor it, it uses too much process time
    // and i can't even say if it is mathematically right
    b: {
        cluster_bit_size = 12;
        {
            var iterations: usize = 0;
            var old_sectors_per_fat: usize = 0;

            while (iterations < 0xFFFFF and sectors_per_fat != old_sectors_per_fat) : (iterations += 1) {
                old_sectors_per_fat = sectors_per_fat;
                cluster_count = total_sectors - reserved_sectors - sectors_per_fat * num_fats;
                sectors_per_fat = std.math.divCeil(usize, cluster_count * cluster_bit_size, 8 * bytes_per_sector) catch unreachable;
            }
        }

        if (cluster_count <= 4084) break :b;
        // Not FAT12, updating parameters for FAT16 and trying again

        cluster_bit_size = 16;
        {
            var iterations: usize = 0;
            var old_sectors_per_fat: usize = 0;

            while (iterations < 0xFFFFF and sectors_per_fat != old_sectors_per_fat) : (iterations += 1) {
                old_sectors_per_fat = sectors_per_fat;
                cluster_count = total_sectors - reserved_sectors - sectors_per_fat * num_fats;
                sectors_per_fat = std.math.divCeil(usize, cluster_count * cluster_bit_size, 8 * bytes_per_sector) catch unreachable;
            }
        }

        if (cluster_count <= 65524) break :b;
        // Not FAT16, falling to FAT32

        cluster_bit_size = 32;
        max_root_dir_entries = 0;
        reserved_sectors = 32;
        break :b;
    }

    fat_fs = switch (cluster_bit_size) {
        12 => .FAT12,
        16 => .FAT16,
        32 => .FAT32,
        else => unreachable,
    };

    var w = f.writer();
    //const r = f.reader();

    n.end();
    n = p.start("Writing Boot Sector", 1);
    {
        gotoSector(f, @truncate(partition.start));

        const total_sectors_short: u16 = if (total_sectors > 0xFFFF) 0 else @truncate(total_sectors);
        const total_sectors_long: u32 = if (total_sectors_short == 0) @truncate(total_sectors) else 0;

        const fat_size_short: u16 = if (cluster_bit_size == 32) 0 else @truncate(sectors_per_fat);
        const fat_size_long: u32 = if (fat_size_short == 0) @truncate(sectors_per_fat) else 0;

        _ = w.write("\xEB\x3C\x90") // jump struction
            catch unreachable; // (must generate a page fault if executed)
        _ = w.write("LUMI\x20\x20\x20\x20") // OEM name
            catch unreachable;

        // BIOS Parameter Block:

        // DOS 2.0 (0x08 .. 0x18)
        gotoOffset(f, @truncate(partition.start), 0x0b);

        writeI(&w, u16, @truncate(bytes_per_sector)); // bytes per sector
        writeI(&w, u8, @truncate(sectors_per_cluster)); // sectors per cluster
        writeI(&w, u16, @truncate(reserved_sectors)); // reserved sectors count
        writeI(&w, u8, num_fats); // FAT tables count
        writeI(&w, u16, @truncate(max_root_dir_entries)); // Max root dir entries
        writeI(&w, u16, total_sectors_short); // Total logical sectors short
        writeI(&w, u8, 0xF8); // Media descriptor
        writeI(&w, u16, fat_size_short); // FAT sectors size short

        // DOS 3.31 (0x18 .. 0x24)
        writeI(&w, u16, 1); // legacy CHS
        writeI(&w, u16, 0); // legacy CHS
        writeI(&w, u32, 0); // hidden sectors before partition
        writeI(&w, u32, total_sectors_long); // Total logical sectors long

        // Extended BPB (0x24 ..)
        writeI(&w, u8, 0); // phys driver number
        writeI(&w, u8, 0); // reserved
        writeI(&w, u8, 0x29); // extended boot signature

        const timestamp: u32 = @truncate(@as(u64, @bitCast(std.time.timestamp())) & 0xFFFFFFFF);
        writeI(&w, u32, timestamp); // volume ID
        _ = w.write("NO NAME    ") catch unreachable; // Partition name
        _ = switch (cluster_bit_size) { // fs type
            12 => w.write("FAT12   "),
            16 => w.write("FAT16   "),
            32 => w.write("FAT32   "),
            else => unreachable,
        } catch unreachable;

        gotoOffset(f, @truncate(partition.start), 0x1FE);
        _ = w.write("\x55\xAA") catch unreachable; // boot signature

        _ = fat_size_long;
    }
    n.end();

    const first_fat_sector = partition.start + reserved_sectors;
    const fat_table_end = first_fat_sector + sectors_per_fat * num_fats;

    const first_root_entry = fat_table_end;
    const root_entry_end = first_root_entry + (max_root_dir_entries * 32) / 512;

    n = p.start("Writing Content", 1);
    {
        const first_data_sector = root_entry_end;
        const dsoff = first_data_sector - 2;

        var sec_alloc: SAlloc = .{ .first = @truncate(first_data_sector), .length = @truncate(total_sectors - first_data_sector) };

        const root_path = fs.realpathAlloc(b.allocator, partition.path) catch |err| switch (err) {
            else => @panic("Unexpected error!"),
        };
        defer b.allocator.free(root_path);

        const root_dir = fs.openDirAbsolute(root_path, .{ .iterate = true }) catch |err| switch (err) {
            error.NotDir => @panic("Path is not a valid directory!"),
            else => @panic("Unexpected error!"),
        };

        var root_walker = root_dir.walk(b.allocator) catch unreachable;
        var next_nullable = root_walker.next() catch unreachable;

        const DirEntryStruct = struct {
            const EntryDict = std.StringArrayHashMap(usize);

            allocator: std.mem.Allocator,
            path: []const u8,

            start_sector: u32,
            current_sector: u32,
            last_entry: u32,

            entries: EntryDict,

            pub fn init(alloc: std.mem.Allocator, path: []const u8, start_sector: u32) *@This() {
                const a = alloc.create(@This()) catch @panic("OOM");
                a.* = .{
                    .allocator = alloc,
                    .path = alloc.dupe(u8, path) catch unreachable,
                    .start_sector = start_sector,
                    .current_sector = start_sector,
                    .last_entry = 0,
                    .entries = EntryDict.init(alloc),
                };
                return a;
            }
            pub inline fn deinit(s: *@This()) void {
                s.allocator.free(s.path);
                s.entries.deinit();
                s.allocator.destroy(s);
            }
        };
        const DirEntryStack = std.ArrayList(*DirEntryStruct);

        var dir_stack = DirEntryStack.init(b.allocator);
        dir_stack.append(DirEntryStruct.init(b.allocator, "", @truncate(first_root_entry))) catch unreachable;

        while (next_nullable != null) : (next_nullable = root_walker.next() catch unreachable) {
            const next = next_nullable.?;

            var file_data: fs.File = undefined;
            var dir_data: fs.Dir = undefined;
            var entrymeta: fs.File.Metadata = undefined;

            if (next.kind == .file) {
                file_data = root_dir.openFile(next.path, .{ .mode = .read_only }) catch unreachable;
                entrymeta = file_data.metadata() catch unreachable;
            } else if (next.kind == .directory) {
                dir_data = root_dir.openDir(next.path, .{}) catch unreachable;
                entrymeta = dir_data.metadata() catch unreachable;
            } else std.debug.panic("Invalid entry of type \'{s}\'", .{@tagName(next.kind)});

            var current_dir_entry: *DirEntryStruct = dir_stack.getLast();

            const path_dir_length = std.mem.lastIndexOfLinear(u8, next.path, std.fs.path.sep_str) orelse 0;
            const path_dir = next.path[0..path_dir_length];

            while (!std.mem.eql(u8, current_dir_entry.path, path_dir)) {
                dir_stack.pop().?.deinit();
                current_dir_entry = dir_stack.getLast();
            }

            //const current_dir = current_dir_entry.path;
            const is_root = dir_stack.items.len <= 1;

            var name: []const u8 = undefined;
            var ext: ?[]const u8 = null;

            var name_8: [8]u8 = undefined;
            var ext_3: [3]u8 = undefined;

            var time1: WordTime = undefined;
            var time3: WordTime = undefined;
            var date1: WordDate = undefined;
            var date2: WordDate = undefined;
            var date3: WordDate = undefined;

            const size: u32 = @truncate(if (next.kind == .directory) 0 else entrymeta.size());

            const long_name_buf = b.allocator.alloc(u16, 256) catch unreachable;
            const long_name_ptr = @as([*]u8, @ptrCast(@alignCast(long_name_buf.ptr)))[0..512];
            defer b.allocator.free(long_name_buf);

            //
            //  Writing entry content
            //

            var entry_sector: u32 = 0;

            if (next.kind == .directory) {
                entry_sector = sec_alloc.getOne();

                dir_stack.append(DirEntryStruct.init(b.allocator, next.path, entry_sector)) catch unreachable;
                dir_stack.getLast().last_entry = 2;

                // entries . and ..
                gotoSector(f, entry_sector);

                const dot_cluster = entry_sector - dsoff;
                _ = w.write(".          ") catch unreachable; // name + extension
                writeI(&w, u8, 0x10); // attributes
                writeI(&w, u8, 0); // user attributes
                writeI(&w, u8, 0); // (???)
                writeI(&w, u16, 0);
                writeI(&w, u16, 0);
                writeI(&w, u16, 0);
                writeI(&w, u16, @truncate(dot_cluster >> 16)); // high cluster
                writeI(&w, u32, 0);
                writeI(&w, u16, @truncate(dot_cluster & 0xFFFF)); // low cluster
                writeI(&w, u32, 0); // size in bytes

                const dotdot_cluster = if (is_root) 0 else current_dir_entry.start_sector - dsoff;
                _ = w.write("..         ") catch unreachable; // name + extension
                writeI(&w, u8, 0x10); // attributes
                writeI(&w, u8, 0); // user attributes
                writeI(&w, u8, 0); // (???)
                writeI(&w, u16, 0);
                writeI(&w, u16, 0);
                writeI(&w, u16, 0);
                writeI(&w, u16, @truncate(dotdot_cluster >> 16)); // high cluster
                writeI(&w, u32, 0);
                writeI(&w, u16, @truncate(dotdot_cluster & 0xFFFF)); // low cluster
                writeI(&w, u32, 0); // size in bytes

                // TODO make directory cluster chains work
                writeFATEscape(f, first_fat_sector, fat_fs, entry_sector - dsoff, .end_of_chain);
            } else if (next.kind == .file) {
                entry_sector = sec_alloc.peek();

                var current_sector: u32 = undefined;
                var last_sector: ?u32 = null;

                const file_size_in_sectors = std.math.divCeil(usize, entrymeta.size(), 512) catch unreachable;

                const buf = b.allocator.alloc(u8, 512) catch unreachable;

                for (0..file_size_in_sectors) |_| {
                    current_sector = sec_alloc.getOne();
                    gotoSector(f, current_sector);

                    const len = file_data.read(buf) catch |err| switch (err) {
                        else => std.debug.panic("Unexpected error {s}!", .{@errorName(err)}),
                    };
                    _ = w.write(buf[0..len]) catch unreachable;

                    if (last_sector) |ls| {
                        writeFATEntry(f, first_fat_sector, fat_fs, ls - dsoff, current_sector - dsoff);
                    }

                    last_sector = current_sector;
                }
                writeFATEscape(f, first_fat_sector, fat_fs, current_sector - dsoff, .end_of_chain);
                b.allocator.free(buf);
            }

            //
            //  Writing entry table data
            //

            // jumping to entry
            gotoOffset(f, current_dir_entry.current_sector, current_dir_entry.last_entry * 32);

            // lots of name related things bruh
            {
                if (next.kind == .directory) name = next.basename else { // file extension must be separated here
                    const dot_pos = std.mem.lastIndexOfScalar(u8, next.basename, '.');
                    name = if (dot_pos) |d| next.basename[0..d] else next.basename;
                    ext = if (dot_pos) |d| next.basename[d + 1 ..] else "";
                }

                var use_long_name = false;

                if (name.len > 8) {
                    _ = std.ascii.upperString(&name_8, name[0..6]);
                    use_long_name = true;
                } else {
                    if (!isAllUppercase(name)) use_long_name = true;
                    _ = std.ascii.upperString(&name_8, name);
                    @memset(name_8[name.len..], ' ');
                }
                
                if (ext) |_ext| {
                    if (_ext.len > 3) {
                        _ = std.ascii.upperString(&ext_3, _ext[0..3]);
                        use_long_name = true;
                    } else {
                        if (!isAllUppercase(_ext)) use_long_name = true;
                        _ = std.ascii.upperString(&ext_3, _ext);
                        @memset(ext_3[_ext.len..], ' ');
                    }
                } else @memset(&ext_3, ' ');

                if (use_long_name) {
                    // format the short name
                    var rep: usize = 1;
                    var str_entry: [9]u8 = undefined;
                    @memcpy(str_entry[0..6], name_8[0..6]);
                    @memcpy(str_entry[6..9], &ext_3);

                    const res = current_dir_entry.entries.getOrPut(&str_entry) catch unreachable;
                    if (res.found_existing) {
                        res.value_ptr.* = res.value_ptr.* + 1;
                        rep = res.value_ptr.*;
                    } else res.value_ptr.* = rep;

                    name_8[6] = '~';
                    name_8[7] = '0' + @as(u8, @truncate(rep));

                    // convert the name to utf16LE and write it
                    const len = std.unicode.utf8ToUtf16Le(long_name_buf, next.basename) catch unreachable;
                    const entry_count = std.math.divCeil(usize, len, 13) catch unreachable;
                    @memset(long_name_buf[len..], 0);

                    var ri: usize = entry_count;
                    var i: usize = 0;

                    // write the name parts
                    while (ri > 0) : ({ ri -= 1; i += 1; }) {
                        const eslice = long_name_ptr[(ri - 1) * 26 ..];
                        const seqnum: u8 = @truncate(if (i == 0) (0x40 | ri) else ri);
                        const checksum = lfnChecksum(name_8, ext_3);

                        writeI(&w, u8, seqnum); // sequence num

                        _ = w.write(eslice[0..10]) catch unreachable; // 10-byte slice

                        writeI(&w, u8, 0x0F); // attributes (aways 0x0F)
                        writeI(&w, u8, 0x00); // type (aways 0)
                        writeI(&w, u8, checksum); // checksum

                        _ = w.write(eslice[10..22]) catch unreachable; // 12-byte slice

                        writeI(&w, u16, 0); // cluster (aways 0x0000);
                        _ = w.write(eslice[22..26]) catch unreachable; // 2-byte slice

                        current_dir_entry.last_entry += 1;
                    }
                }
            }

            // lots of time related things bruh
            {
                const created_timestamp: i64 = @truncate(@divTrunc((entrymeta.created() orelse 0), 1_000_000));
                const acessed_timestamp: i64 = @truncate(@divTrunc(entrymeta.accessed(), 1_000_000));
                const modifid_timestamp: i64 = @truncate(@divTrunc(entrymeta.modified(), 1_000_000));
                const dt1 = datetime.datetime.Datetime.fromTimestamp(created_timestamp);
                const dt2 = datetime.datetime.Datetime.fromTimestamp(acessed_timestamp);
                const dt3 = datetime.datetime.Datetime.fromTimestamp(modifid_timestamp);

                time1 = .{ .secconds = @truncate(dt1.time.second / 2), .minutes = @truncate(dt1.time.minute), .hours = @truncate(dt1.time.hour) };
                time3 = .{ .secconds = @truncate(dt3.time.second / 2), .minutes = @truncate(dt3.time.minute), .hours = @truncate(dt3.time.hour) };
                date1 = .{ .day = @truncate(dt1.date.day), .month = @truncate(dt1.date.month), .year = @truncate(dt1.date.year - 1980) };
                date2 = .{ .day = @truncate(dt2.date.day), .month = @truncate(dt2.date.month), .year = @truncate(dt2.date.year - 1980) };
                date3 = .{ .day = @truncate(dt3.date.day), .month = @truncate(dt3.date.month), .year = @truncate(dt3.date.year - 1980) };
            }

            // writing entry in table
            {
                const cluster = entry_sector - first_data_sector + 2;

                _ = w.write(&name_8) catch unreachable; // name
                _ = w.write(&ext_3) catch unreachable; // extension
                writeI(&w, u8, if (next.kind == .directory) 0x10 else 0x00); // attributes
                writeI(&w, u8, 0); // user attributes
                writeI(&w, u8, 0); // (???)
                writeI(&w, u16, @bitCast(time1)); // creation time
                writeI(&w, u16, @bitCast(date1)); // creation date
                writeI(&w, u16, @bitCast(date2)); // acessed date
                writeI(&w, u16, @truncate(cluster >> 16)); // high cluster
                writeI(&w, u16, @bitCast(time3)); // modified time
                writeI(&w, u16, @bitCast(date3)); // modified date
                writeI(&w, u16, @truncate(cluster & 0xFFFF)); // low cluster
                writeI(&w, u32, size); // size in bytes

                current_dir_entry.last_entry += 1;
            }

            if (next.kind == .directory) dir_data.close() else file_data.close();
        }

        while (dir_stack.items.len > 0) {
            dir_stack.pop().?.deinit();
        }
        dir_stack.deinit();
    }
    n.end();

    n = p.start("Copying FAT entry", 1);
    {
        // important configurations before
        // copy it
        writeFATEntry(f, first_fat_sector, fat_fs, 0,
        switch (fat_fs) { .FAT12 => 0xFF8, .FAT16 => 0xFFF8, .FAT32 => 0xFFFFFFF8});

        // TODO copying
    }
    n.end();
}

fn lfnChecksum(name: [8]u8, extension: [3]u8) u8 {
    var shortName: [11]u8 = undefined;
    @memcpy(shortName[0..8], &name);
    @memcpy(shortName[8..11], &extension);

    var sum: u8 = 0;

    for (shortName) |c| {
        sum = @addWithOverflow(@addWithOverflow((sum & 1) << 7, sum >> 1)[0], c)[0];
    }

    return sum;
}

fn writeFATEntry(f: fs.File, ffats: usize, fat_fs: FatFS, cluster: usize, value: usize) void {
    var w = f.writer();
    const r = f.reader();

    if (fat_fs == .FAT12) {
        const fat_cluster_offset: u32 = @truncate((cluster * 3) / 2);
        gotoOffset(f, @truncate(ffats), fat_cluster_offset);
        var cluster_value1 = r.readByte() catch unreachable;
        var cluster_value2 = r.readByte() catch unreachable;

        if (cluster % 2 == 0) {
            cluster_value1 = @truncate(value & 0xFF);
            cluster_value2 = (cluster_value2 & 0xF0) | @as(u8, @truncate((value >> 8 | 0x0F)));
        } else {
            cluster_value1 = (cluster_value2 & 0x0F) | @as(u8, @truncate((value << 4 | 0xF0)));
            cluster_value2 = @truncate((value >> 4) & 0xFF);
        }

        gotoOffset(f, @truncate(ffats), fat_cluster_offset);
        w.writeByte(cluster_value1) catch unreachable;
        w.writeByte(cluster_value2) catch unreachable;
    } else if (fat_fs == .FAT16) {
        const fat_cluster_offset: usize = @as(usize, @intCast(cluster)) * 2;
        gotoOffset(f, @truncate(ffats), fat_cluster_offset);
        writeI(&w, u16, @truncate(value));
    } else {
        const fat_cluster_offset: u32 = @truncate(cluster * 4);
        gotoOffset(f, @truncate(ffats), fat_cluster_offset);
        writeI(&w, u32, @truncate(value));
    }
}
fn writeFATEscape(f: fs.File, ffats: usize, fat_fs: FatFS, cluster: usize, value: FatEscape) void {
    const escape_value: u32 = switch (value) {
        .free => switch (fat_fs) {
            .FAT12 => 0x000,
            .FAT16 => 0x0000,
            .FAT32 => 0x00000000,
        },
        .reserved => switch (fat_fs) {
            .FAT12 => 0x001,
            .FAT16 => 0x0001,
            .FAT32 => 0x00000001,
        },
        .bad_cluster => switch (fat_fs) {
            .FAT12 => 0xFF7,
            .FAT16 => 0xFFF7,
            .FAT32 => 0xFFFFFFF7,
        },
        .end_of_chain => switch (fat_fs) {
            .FAT12 => 0xFF8,
            .FAT16 => 0xFFF8,
            .FAT32 => 0xFFFFFFF8,
        },
    };
    writeFATEntry(f, ffats, fat_fs, cluster, escape_value);
}

const FatFS = enum {
    FAT12,
    FAT16,
    FAT32,
};
const FatEscape = enum { free, reserved, bad_cluster, end_of_chain };

const WordTime = packed struct(u16) {
    secconds: u5,
    minutes: u6,
    hours: u5,
};
const WordDate = packed struct(u16) {
    day: u5,
    month: u4,
    year: u7,
};

fn isAllUppercase(s: []const u8) bool {
    for (s) |c| if (std.ascii.isAlphabetic(c) and !std.ascii.isUpper(c)) return false;
    return true;
}
