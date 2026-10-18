const std = @import("std");
const disklib = @import("../root.zig");
const Io = std.Io;
const Build = std.Build;

const datetime = disklib.datetime;
const Partition = disklib.Partition;

const gotoSector = disklib.utils.gotoSector;
const gotoOffset = disklib.utils.gotoOffset;
const gotoSectorR = disklib.utils.gotoSectorR;
const gotoOffsetR = disklib.utils.gotoOffsetR;
const writeI = disklib.utils.writeI;
const SAlloc = disklib.utils.SectorAllocator;

const log = std.log.scoped(.FAT);

pub fn writePartition(
    gpa: std.mem.Allocator,
    io: Io,
    writer: *Io.File.Writer,
    reader: *Io.File.Reader,
    partition: *Partition,
) !void {
    const total_sectors = partition.options.size_sectors;
    const bytes_per_sector = 512;
    const sectors_per_cluster = 1;
    const num_fats = 2;

    var reserved_sectors: usize = 1;
    var max_root_dir_entries: usize = 512;

    var sectors_per_fat: usize = 0;
    var cluster_count: usize = undefined;
    var cluster_bit_size: usize = undefined;
    var fat_fs: FatFS = undefined;

    log.info("Detecting format", .{});

    b: {
        // Primeiro, tenta FAT12 e depois FAT16.
        cluster_bit_size = 12;

        while (true) {
            const root_dir_sectors = @divCeil(max_root_dir_entries * 32, bytes_per_sector);

            const overhead = reserved_sectors + root_dir_sectors;
            if (overhead >= total_sectors) @panic("Volume too small");

            const max_clusters = (total_sectors - overhead) / sectors_per_cluster;

            sectors_per_fat = @divCeil((max_clusters + 2) * cluster_bit_size, 8 * bytes_per_sector);

            const fat_sectors = sectors_per_fat * num_fats;

            if (overhead + fat_sectors >= total_sectors) @panic("FAT tables exceed volume size");

            const data_sectors = total_sectors - overhead - fat_sectors;
            cluster_count = data_sectors / sectors_per_cluster;

            if (cluster_bit_size == 12 and cluster_count <= 4084) {
                fat_fs = .fat12;
                break :b;
            }

            if (cluster_bit_size == 12) {
                cluster_bit_size = 16;
                continue;
            }

            if (cluster_count <= 65524) {
                fat_fs = .fat16;
                break :b;
            }

            cluster_bit_size = 32;
            reserved_sectors = 32;
            max_root_dir_entries = 0;

            const fat32_max_clusters = (total_sectors - reserved_sectors) / sectors_per_cluster;

            sectors_per_fat = @divCeil((fat32_max_clusters + 2) * 32, 8 * bytes_per_sector);

            const fat32_overhead = reserved_sectors + sectors_per_fat * num_fats;
            if (fat32_overhead >= total_sectors) @panic("Volume too small for FAT32");

            cluster_count = (total_sectors - fat32_overhead) / sectors_per_cluster;
            if (cluster_count < 65525) @panic("Volume is too small for FAT32");

            fat_fs = .fat32;
            break :b;
        }
    }

    fat_fs = switch (cluster_bit_size) {
        12 => .fat12,
        16 => .fat16,
        32 => .fat32,
        else => unreachable,
    };

    log.info("Writing Boot Sector", .{});
    {
        gotoSector(writer, @truncate(partition.start));

        const total_sectors_short: u16 = if (total_sectors > 0xFFFF) 0 else @truncate(total_sectors);
        const total_sectors_long: u32 = if (total_sectors_short == 0) @truncate(total_sectors) else 0;

        const fat_size_short: u16 = if (cluster_bit_size == 32) 0 else @truncate(sectors_per_fat);
        const fat_size_long: u32 = if (fat_size_short == 0) @truncate(sectors_per_fat) else 0;

        _ = writer.interface.write("\xEB\x3C\x90") // jump struction
            catch unreachable; // (must generate a page fault if executed)
        _ = writer.interface.write("LUMI\x20\x20\x20\x20") // OEM name
            catch unreachable;

        // BIOS Parameter Block:

        // DOS 2.0 (0x08 .. 0x18)
        gotoOffset(writer, @truncate(partition.start), 0x0b);

        writeI(writer, u16, @truncate(bytes_per_sector)); // bytes per sector
        writeI(writer, u8, @truncate(sectors_per_cluster)); // sectors per cluster
        writeI(writer, u16, @truncate(reserved_sectors)); // reserved sectors count
        writeI(writer, u8, num_fats); // FAT tables count
        writeI(writer, u16, @truncate(max_root_dir_entries)); // Max root dir entries
        writeI(writer, u16, total_sectors_short); // Total logical sectors short
        writeI(writer, u8, 0xF8); // Media descriptor
        writeI(writer, u16, fat_size_short); // FAT sectors size short

        // DOS 3.31 (0x18 .. 0x24)
        writeI(writer, u16, 1); // legacy CHS
        writeI(writer, u16, 0); // legacy CHS
        writeI(writer, u32, 0); // hidden sectors before partition
        writeI(writer, u32, total_sectors_long); // Total logical sectors long

        const volume_id: u32 = @truncate(@as(u64, @bitCast(Io.Clock.real.now(io).toSeconds())) & 0xFFFFFFFF);

        switch (cluster_bit_size) {
            12, 16 => {
                // Extended BPB FAT12/16 - 0x24
                writeI(writer, u8, 0);
                writeI(writer, u8, 0);
                writeI(writer, u8, 0x29);
                writeI(writer, u32, volume_id);
                _ = writer.interface.write("NO NAME    ") catch unreachable;
                _ = writer.interface.write(
                    if (cluster_bit_size == 12) "FAT12   " else "FAT16   ",
                ) catch unreachable;
            },
            32 => {
                // FAT32 specific - 0x24
                writeI(writer, u32, fat_size_long);
                writeI(writer, u16, 0); // ExtFlags
                writeI(writer, u16, 0); // FSVer
                writeI(writer, u32, 2); // RootClus
                writeI(writer, u16, 1); // FSInfo sector
                writeI(writer, u16, 6); // Backup boot sector

                // Reserved untill 0x40
                writeI(writer, u8, 0);
                writeI(writer, u8, 0);
                writeI(writer, u8, 0);
                writeI(writer, u8, 0);
                writeI(writer, u8, 0);
                writeI(writer, u8, 0);
                writeI(writer, u8, 0);
                writeI(writer, u8, 0);
                writeI(writer, u8, 0);
                writeI(writer, u8, 0);
                writeI(writer, u8, 0);
                writeI(writer, u8, 0);

                // Extended BPB FAT32 - 0x40
                writeI(writer, u8, 0);
                writeI(writer, u8, 0);
                writeI(writer, u8, 0x29);
                writeI(writer, u32, volume_id);
                _ = writer.interface.write("NO NAME    ") catch unreachable;
                _ = writer.interface.write("FAT32   ") catch unreachable;
            },
            else => unreachable,
        }

        // Boot signature
        gotoOffset(writer, @truncate(partition.start), 510);
        writer.interface.writeByte(0x55) catch unreachable;
        writer.interface.writeByte(0xAA) catch unreachable;
    }

    if (cluster_bit_size == 32) {
        log.info("Writing FSInfo and Backup Boot Sector", .{});

        gotoSector(writer, partition.start + 1);
        writeI(writer, u32, 0x41615252); // Lead signature
        for (0..120) |_| writeI(writer, u32, 0); // 480 bytes de zeros
        writeI(writer, u32, 0x61417272); // Struct signature
        writeI(writer, u32, @truncate(cluster_count - 1)); // Free cluster count
        writeI(writer, u32, 0xFFFFFFFF); // Next free cluster[cite: 1]
        for (0..3) |_| writeI(writer, u32, 0); // Reserved[cite: 1]
        writeI(writer, u32, 0xaa550000); // Trail signature[cite: 1]

        // Copy sector to backup
        gotoSector(writer, partition.start);
        var boot_sec_buf: [512]u8 = undefined;
        try reader.interface.readSliceAll(&boot_sec_buf);

        gotoSector(writer, partition.start + 6);
        try writer.interface.writeAll(&boot_sec_buf);
    }

    const first_fat_sector = partition.start + reserved_sectors;
    const fat_table_end = first_fat_sector + sectors_per_fat * num_fats;

    const first_root_entry = fat_table_end;
    const root_entry_end = first_root_entry + (max_root_dir_entries * 32) / 512;

    log.info("Writing Content", .{});
    {
        const first_data_sector = root_entry_end;
        const dsoff = first_data_sector - 2;

        var sec_alloc: SAlloc = .{
            .first = @truncate(first_data_sector),
            .length = @truncate(partition.start + total_sectors - first_data_sector),
        };

        if (fat_fs == .fat32) {
            const root_cluster_sec = sec_alloc.getOne();
            writeFATEscape(writer, reader, first_fat_sector, fat_fs, root_cluster_sec - dsoff, .end_of_chain);
        }

        const root_path = Io.Dir.cwd().realPathFileAlloc(io, partition.options.path, gpa) catch |err| switch (err) {
            error.FileNotFound => std.debug.panic("Directory in path \"{s}\" not found!", .{partition.options.path}),
            else => std.debug.panic("Unexpected error: {s}", .{@errorName(err)}),
        };

        defer gpa.free(root_path);

        const root_dir = Io.Dir.openDirAbsolute(io, root_path, .{ .iterate = true }) catch |err| switch (err) {
            error.NotDir => @panic("Path is not a valid directory!"),
            else => std.debug.panic("Unexpected error: {s}", .{@errorName(err)}),
        };

        defer root_dir.close(io);

        var root_walker = try root_dir.walk(gpa);
        defer root_walker.deinit();
        var next_nullable = try root_walker.next(io);

        const DirEntryStruct = struct {
            const EntryDict = std.array_hash_map.String(usize);

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
                    .entries = .empty,
                };
                return a;
            }
            pub inline fn deinit(s: *@This(), alloc: std.mem.Allocator) void {
                s.allocator.free(s.path);
                s.entries.deinit(alloc);
                s.allocator.destroy(s);
            }
        };
        const DirEntryStack = std.ArrayList(*DirEntryStruct);

        var dir_stack = DirEntryStack.empty;
        defer dir_stack.deinit(gpa);
        dir_stack.append(gpa, DirEntryStruct.init(gpa, "", @truncate(first_root_entry))) catch unreachable;

        while (next_nullable != null) : (next_nullable = root_walker.next(io) catch unreachable) {
            const next = next_nullable.?;

            log.debug("Writing entry for '{s}'", .{next.path});

            var file_data: Io.File = undefined;
            var dir_data: Io.Dir = undefined;
            var entrymeta: Io.File.Stat = undefined;

            if (next.kind == .file) {
                file_data = root_dir.openFile(io, next.path, .{ .mode = .read_only }) catch unreachable;
                entrymeta = file_data.stat(io) catch unreachable;
            } else if (next.kind == .directory) {
                dir_data = root_dir.openDir(io, next.path, .{}) catch unreachable;
                entrymeta = dir_data.stat(io) catch unreachable;
            } else {
                std.debug.panic("Invalid entry of type '{s}'", .{@tagName(next.kind)});
            }

            var current_dir_entry: *DirEntryStruct = dir_stack.getLast();

            const path_dir_length = std.mem.lastIndexOfLinear(u8, next.path, std.fs.path.sep_str) orelse 0;
            const path_dir = next.path[0..path_dir_length];

            while (!std.mem.eql(u8, current_dir_entry.path, path_dir)) {
                dir_stack.pop().?.deinit(gpa);
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

            const size: u32 = @truncate(if (next.kind == .directory) 0 else entrymeta.size);

            const long_name_buf = gpa.alloc(u16, 256) catch unreachable;
            const long_name_ptr = @as([*]u8, @ptrCast(@alignCast(long_name_buf.ptr)))[0..512];
            defer gpa.free(long_name_buf);

            //
            //  Writing entry content
            //

            var entry_sector: u32 = 0;

            if (next.kind == .directory) {
                entry_sector = sec_alloc.getOne();

                dir_stack.append(gpa, DirEntryStruct.init(gpa, next.path, entry_sector)) catch unreachable;
                dir_stack.getLast().last_entry = 2;

                // entries . and ..
                gotoSector(writer, entry_sector);

                const dot_cluster = entry_sector - dsoff;
                _ = writer.interface.write(".          ") catch unreachable; // name + extension
                writeI(writer, u8, 0x10); // attributes
                writeI(writer, u8, 0); // user attributes
                writeI(writer, u8, 0); // (???)
                writeI(writer, u16, 0); // creation time
                writeI(writer, u16, 0); // creation date
                writeI(writer, u16, 0); // accessed date
                writeI(writer, u16, @truncate(dot_cluster >> 16)); // high cluster
                writeI(writer, u16, 0); // modified time
                writeI(writer, u16, 0); // modified date
                writeI(writer, u16, @truncate(dot_cluster & 0xFFFF)); // low cluster
                writeI(writer, u32, 0); // size in bytes

                const dotdot_cluster = if (is_root) 0 else current_dir_entry.start_sector - dsoff;
                _ = writer.interface.write("..         ") catch unreachable; // name + extension
                writeI(writer, u8, 0x10); // attributes
                writeI(writer, u8, 0); // user attributes
                writeI(writer, u8, 0); // (???)
                writeI(writer, u16, 0); // creation time
                writeI(writer, u16, 0); // creation date
                writeI(writer, u16, 0); // accessed date
                writeI(writer, u16, @truncate(dotdot_cluster >> 16)); // high cluster
                writeI(writer, u16, 0); // modified time
                writeI(writer, u16, 0); // modified date
                writeI(writer, u16, @truncate(dotdot_cluster & 0xFFFF)); // low cluster
                writeI(writer, u32, 0); // size in bytes

                // TODO make directory cluster chains work
                writeFATEscape(writer, reader, first_fat_sector, fat_fs, entry_sector - dsoff, .end_of_chain);
            } else if (next.kind == .file) {
                entry_sector = sec_alloc.peek();

                var current_sector: u32 = undefined;
                var last_sector: ?u32 = null;

                const file_size_in_sectors = std.math.divCeil(usize, entrymeta.size, 512) catch unreachable;

                const buf = gpa.alloc(u8, 512) catch unreachable;

                for (0..file_size_in_sectors) |_| {
                    current_sector = sec_alloc.getOne();
                    gotoSector(writer, current_sector);

                    const len = file_data.readStreaming(io, &.{buf[0..]}) catch |err| switch (err) {
                        else => std.debug.panic("Unexpected error {s}!", .{@errorName(err)}),
                    };

                    _ = writer.interface.write(buf[0..len]) catch unreachable;

                    if (last_sector) |ls| {
                        writeFATEntry(writer, reader, first_fat_sector, fat_fs, ls - dsoff, current_sector - dsoff);
                    }

                    last_sector = current_sector;
                }
                writeFATEscape(writer, reader, first_fat_sector, fat_fs, current_sector - dsoff, .end_of_chain);
                gpa.free(buf);
            }

            //
            //  Writing entry table data
            //

            // jumping to entry
            gotoOffset(writer, current_dir_entry.current_sector, current_dir_entry.last_entry * 32);

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

                    const res = current_dir_entry.entries.getOrPut(gpa, &str_entry) catch unreachable;
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
                    while (ri > 0) : ({
                        ri -= 1;
                        i += 1;
                    }) {
                        const eslice = long_name_ptr[(ri - 1) * 26 ..];
                        const seqnum: u8 = @truncate(if (i == 0) (0x40 | ri) else ri);
                        const checksum = lfnChecksum(name_8, ext_3);

                        writeI(writer, u8, seqnum); // sequence num

                        _ = writer.interface.write(eslice[0..10]) catch unreachable; // 10-byte slice

                        writeI(writer, u8, 0x0F); // attributes (aways 0x0F)
                        writeI(writer, u8, 0x00); // type (aways 0)
                        writeI(writer, u8, checksum); // checksum

                        _ = writer.interface.write(eslice[10..22]) catch unreachable; // 12-byte slice

                        writeI(writer, u16, 0); // cluster (aways 0x0000);
                        _ = writer.interface.write(eslice[22..26]) catch unreachable; // 2-byte slice

                        current_dir_entry.last_entry += 1;
                    }
                }
            }

            // lots of time related things bruh
            {
                const created_timestamp: i64 = @truncate(@divTrunc(entrymeta.ctime.nanoseconds, 1_000_000));
                const accessed_timestamp: i64 = if (entrymeta.atime) |ts| @truncate(@divTrunc(ts.nanoseconds, 1_000_000)) else 0;
                const modified_timestamp: i64 = @truncate(@divTrunc(entrymeta.mtime.nanoseconds, 1_000_000));
                const dt1 = datetime.Datetime.fromTimestamp(created_timestamp);
                const dt2 = datetime.Datetime.fromTimestamp(accessed_timestamp);
                const dt3 = datetime.Datetime.fromTimestamp(modified_timestamp);

                time1 = .{ .secconds = @truncate(dt1.time.second / 2), .minutes = @truncate(dt1.time.minute), .hours = @truncate(dt1.time.hour) };
                time3 = .{ .secconds = @truncate(dt3.time.second / 2), .minutes = @truncate(dt3.time.minute), .hours = @truncate(dt3.time.hour) };
                date1 = .{ .day = @truncate(dt1.date.day), .month = @truncate(dt1.date.month), .year = @truncate(dt1.date.year - 1980) };
                date2 = .{ .day = @truncate(dt2.date.day), .month = @truncate(dt2.date.month), .year = @truncate(dt2.date.year - 1980) };
                date3 = .{ .day = @truncate(dt3.date.day), .month = @truncate(dt3.date.month), .year = @truncate(dt3.date.year - 1980) };
            }

            // writing entry in table
            {
                const cluster = entry_sector - first_data_sector + 2;

                _ = writer.interface.write(&name_8) catch unreachable; // name
                _ = writer.interface.write(&ext_3) catch unreachable; // extension
                writeI(writer, u8, if (next.kind == .directory) 0x10 else 0x00); // attributes
                writeI(writer, u8, 0); // user attributes
                writeI(writer, u8, 0); // (???)
                writeI(writer, u16, @bitCast(time1)); // creation time
                writeI(writer, u16, @bitCast(date1)); // creation date
                writeI(writer, u16, @bitCast(date2)); // acessed date
                writeI(writer, u16, @truncate(cluster >> 16)); // high cluster
                writeI(writer, u16, @bitCast(time3)); // modified time
                writeI(writer, u16, @bitCast(date3)); // modified date
                writeI(writer, u16, @truncate(cluster & 0xFFFF)); // low cluster
                writeI(writer, u32, size); // size in bytes

                current_dir_entry.last_entry += 1;
            }

            if (next.kind == .directory) dir_data.close(io) else file_data.close(io);
        }

        while (dir_stack.items.len > 0) dir_stack.pop().?.deinit(gpa);
    }

    log.info("Copying FAT entry", .{});
    {
        // important configurations before
        // copy it
        writeFATEntry(writer, reader, first_fat_sector, fat_fs, 0, switch (fat_fs) {
            .fat12 => 0xFF8,
            .fat16 => 0xFFF8,
            .fat32 => 0xFFFFFFF8,
        });

        if (num_fats > 1) {
            const fat_bytes = sectors_per_fat * 512;
            const fat_buf = try gpa.alloc(u8, fat_bytes);
            defer gpa.free(fat_buf);

            gotoOffsetR(reader, first_fat_sector, 0);
            try reader.interface.readSliceAll(fat_buf);

            const second_fat_sector = first_fat_sector + sectors_per_fat;
            gotoOffset(writer, second_fat_sector, 0);
            try writer.interface.writeAll(fat_buf);
        }
    }
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

fn writeFATEntry(
    writer: *Io.File.Writer,
    reader: *Io.File.Reader,
    ffats: usize,
    fat_fs: FatFS,
    cluster: usize,
    value: usize,
) void {
    switch (fat_fs) {
        .fat12 => {
            const fat_cluster_offset: u32 = @truncate((cluster * 3) / 2);
            gotoOffset(writer, @truncate(ffats), fat_cluster_offset);
            var cluster_value1 = reader.interface.takeByte() catch unreachable;
            var cluster_value2 = reader.interface.takeByte() catch unreachable;

            if (cluster % 2 == 0) {
                cluster_value1 = @truncate(value & 0xFF);
                cluster_value2 = (cluster_value2 & 0xF0) | @as(u8, @truncate((value >> 8) & 0x0F));
            } else {
                cluster_value1 = (cluster_value1 & 0x0F) | @as(u8, @truncate((value << 4) & 0xF0));
                cluster_value2 = @truncate((value >> 4) & 0xFF);
            }

            gotoOffset(writer, @truncate(ffats), fat_cluster_offset);
            writer.interface.writeByte(cluster_value1) catch unreachable;
            writer.interface.writeByte(cluster_value2) catch unreachable;
        },
        .fat16 => {
            const fat_cluster_offset: usize = @as(usize, @intCast(cluster)) * 2;
            gotoOffset(writer, @truncate(ffats), fat_cluster_offset);
            writeI(writer, u16, @truncate(value));
        },
        else => {
            const fat_cluster_offset: u32 = @truncate(cluster * 4);
            gotoOffset(writer, @truncate(ffats), fat_cluster_offset);
            writeI(writer, u32, @truncate(value));
        },
    }
}
fn writeFATEscape(
    writer: *Io.File.Writer,
    reader: *Io.File.Reader,
    ffats: usize,
    fat_fs: FatFS,
    cluster: usize,
    value: FatEscape,
) void {
    const escape_value: u32 = switch (value) {
        .free => switch (fat_fs) {
            .fat12 => 0x000,
            .fat16 => 0x0000,
            .fat32 => 0x00000000,
        },
        .reserved => switch (fat_fs) {
            .fat12 => 0x001,
            .fat16 => 0x0001,
            .fat32 => 0x00000001,
        },
        .bad_cluster => switch (fat_fs) {
            .fat12 => 0xFF7,
            .fat16 => 0xFFF7,
            .fat32 => 0xFFFFFFF7,
        },
        .end_of_chain => switch (fat_fs) {
            .fat12 => 0xFF8,
            .fat16 => 0xFFF8,
            .fat32 => 0xFFFFFFF8,
        },
    };
    writeFATEntry(writer, reader, ffats, fat_fs, cluster, escape_value);
}

const FatFS = enum {
    fat12,
    fat16,
    fat32,
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
