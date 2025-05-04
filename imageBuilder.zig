const std = @import("std");
const Build = std.Build;
const Step = Build.Step;
const fs = std.fs;
const Crc32 = std.hash.Crc32;
const PartitionList = std.ArrayList(*Partition);

pub fn addBuildGPTDiskImage(b: *Build, comptime size: []const u8, out_path: []const u8) *DiskBuilder {
    comptime var str_size: []const u8 = undefined;
    var multiplier: usize = 1;

    if (comptime std.ascii.isAlphabetic(size[size.len - 1])) {
        str_size = comptime size[0..(size.len - 1)];

        switch (size[size.len - 1]) {
            'k', 'K' => multiplier = 1024,
            'm', 'M' => multiplier = 1024 * 1024,
            'g', 'G' => multiplier = 1024 * 1024 * 1024,
            else => @compileError("unexpected size indicator '" ++ size[size.len - 1 .. size.len] ++ "'"),
        }
    } else str_size = size;

    const int_size = comptime std.fmt.parseInt(usize, str_size, 16) catch @compileError("\"" ++ str_size ++ "\" is a not valid hexadecimal unsigned number!");

    return DiskBuilder.create(b, int_size * multiplier, out_path);
}

pub const DiskBuilder = struct {
    owner: *Build,
    step: Step,

    size_sectors: usize,
    output_path: []const u8,
    partitions: PartitionList,

    pub fn create(b: *Build, size_bytes: usize, output_path: []const u8) *@This() {
        const self = b.allocator.create(@This()) catch unreachable;
        self.* = .{
            .owner = b,
            .step = Build.Step.init(.{ .id = .custom, .name = "Build Image", .owner = b, .makeFn = make }),
            .output_path = output_path,
            .size_sectors = size_bytes / 512,

            .partitions = PartitionList.init(b.allocator),
        };

        return self;
    }

    pub inline fn addPartitionBySize(
        d: *DiskBuilder,
        fsys: FileSystem,
        name: []const u8,
        path: []const u8,
        size: usize,
    ) void {
        addPartitionBySectors(d, fsys, name, path, std.math.divCeil(usize, size, 512) catch unreachable);
    }
    pub fn addPartitionBySectors(d: *DiskBuilder, fsys: FileSystem, name: []const u8, path: []const u8, length: usize) void {
        const b = d.owner;

        const new_partition = b.allocator.create(Partition) catch unreachable;
        d.partitions.append(new_partition) catch unreachable;

        new_partition.* = .{
            .name = name,
            .path = path,
            .size = length,
            .filesystem = fsys,
            .owner = b,
        };
    }
};

const Partition = struct {
    name: []const u8,
    path: []const u8,
    filesystem: FileSystem,

    start: usize = undefined,
    size: usize,

    owner: *Build,
};

pub const FileSystem = enum {
    FAT,
    // TODO add more file systems
};

fn make(step: *Step, options: Step.MakeOptions) anyerror!void {
    const builder: *DiskBuilder = @fieldParentPtr("step", step);
    const b = builder.owner;
    const progress = &options.progress_node;

    var n = progress.start("Creating Image File", 1);

    const paths = [_][]const u8{ b.install_path, builder.output_path };
    const img_out_file = std.fs.path.joinZ(b.allocator, &paths) catch unreachable;
    defer b.allocator.free(img_out_file);
    const img_out_path = std.fs.path.dirname(img_out_file).?;

    // Create the out directory if it do not exists
    _ = fs.accessAbsolute(img_out_path, .{ .mode = .read_write }) catch fs.cwd().makeDir(img_out_path) catch unreachable;

    // Create the file
    const img_file = fs.cwd().createFile(img_out_file, .{ .read = true }) catch unreachable;
    defer img_file.close();

    // Set the file the requested disk size
    img_file.setEndPos(builder.size_sectors * 512) catch unreachable;

    var w = img_file.writer();
    const r = img_file.reader();

    // random data
    var sectors_count: usize = builder.size_sectors;
    const last_sector: u32 = @intCast(sectors_count - 1);

    const table_sectors = 32;
    sectors_count -= 1 + table_sectors * 2;

    const first_useable = 2 + table_sectors;
    const last_useable = last_sector - table_sectors - 1;

    n.end();

    n = progress.start("Writing Headers", 1);
    {
        var n2 = n.start("Creating Protective MBR", 1);
        {
            // partition entry #1
            gotoOffset(img_file, 0, 0x1BE);
            writeI(&w, u8, 0x00); // bootable partition

            const cylinder_0 = 2 / (255 * 63);
            const temp_0 = 2 % (255 * 63);
            const head_0: u8 = @truncate(temp_0 / 63);
            const sector_0 = (temp_0 % 63) + 1;
            const addr_0: u16 = @truncate((sector_0 & 0x3F) | ((cylinder_0 >> 2) & 0xC0));

            writeI(&w, u8, head_0); // start CHS head (legacy)
            writeI(&w, u16, addr_0); // start CHS addr (legacy)

            writeI(&w, u8, 0xEE); // partition type: GPT protective

            const cylinder_1 = last_sector / (255 * 63);
            const temp_1 = last_sector % (255 * 63);
            const head_1: u8 = @truncate(temp_1 / 63);
            const sector_1 = (temp_1 % 63) + 1;
            const addr_1: u16 = @truncate((sector_1 & 0x3F) | ((cylinder_1 >> 2) & 0xC0));

            writeI(&w, u8, head_1); // end CHS head (legacy)
            writeI(&w, u16, addr_1); // end CHS (legacy)

            writeI(&w, u32, 1); // first sector
            writeI(&w, u32, last_sector); // last sector

            // BOOT sector signature
            gotoOffset(img_file, 0, 0x1FE);
            _ = img_file.write("\x55\xAA") catch unreachable;
            n2.end();
        }

        n2 = n.start("Creating GPT Table", 1);
        {
            gotoSector(img_file, 1);

            _ = w.write("EFI PART") catch unreachable; // Signature
            _ = w.write("\x00\x00\x01\x00") catch unreachable; // Revision

            writeI(&w, u32, 92); // Header size
            writeI(&w, u32, 0); // header CRC32 (temp)
            writeI(&w, u32, 0); // Reserved

            writeI(&w, u64, 1); // Current LBA Header
            writeI(&w, u64, last_sector); // Backup LBA Header

            writeI(&w, u64, first_useable); // First usable LBA
            writeI(&w, u64, last_useable); // Last usable LBA

            writeI(&w, u128, genGuid()); // Disk GUID

            writeI(&w, u64, 2); // Partition table LBA
            writeI(&w, u32, 128); // Partition entry count
            writeI(&w, u32, 128); // Partition entry size
            writeI(&w, u32, 0); // partition table CRC32 (temp)
            n2.end();
        }

        n2 = n.start("Creating Partitions Table", 1);
        {
            const partitions = builder.partitions.items;
            var offset: usize = 2 + table_sectors;

            var utf16_buf: [72]u16 = undefined;

            for (partitions, 0..) |i, index| {
                gotoOffset(img_file, 2, @truncate(index * 128));

                switch (i.filesystem) { // paartition type GUID
                    .FAT => {
                        _ = w.write("\x28\x73\x2a\xc1\x1f\xf8\xd2\x11") catch unreachable;
                        _ = w.write("\xba\x4b\x00\xa0\xc9\x3e\xc9\x3b") catch unreachable;
                    },
                }
                writeI(&w, u128, genGuid()); // partition unique GUID

                writeI(&w, u64, offset); // first LBA
                writeI(&w, u64, offset + i.size); // last LBA

                writeI(&w, u64, 0); // attributes

                // partition name
                @memset(&utf16_buf, 0);
                _ = std.unicode.utf8ToUtf16Le(&utf16_buf, i.name) catch unreachable;
                _ = w.write(@as([*]u8, @ptrCast(&utf16_buf))[0 .. 72 * 2]) catch unreachable;

                i.start = offset;
                offset += i.size + 1;
            }

            n2.end();
        }

        n2 = n.start("Calculating GPT Table's CRC32", 3);
        {
            var buf = b.allocator.alloc(u8, 128 * 128) catch unreachable;
            const buf_2: []u8 = buf[0..92];

            // back a little
            gotoSector(img_file, 2);

            // calculate partition table's CRC32
            _ = r.read(buf) catch unreachable;
            const hash1 = Crc32.hash(buf);
            n2.completeOne();

            gotoOffset(img_file, 1, 0x58);
            writeI(&w, u32, hash1);

            // calculate header's CRC32
            gotoSector(img_file, 1);
            _ = r.read(buf_2) catch unreachable;
            std.mem.writeInt(u32, buf_2[0x10..0x14], 0, .little);
            const hash2 = Crc32.hash(buf_2);
            n2.completeOne();

            gotoOffset(img_file, 1, 0x10);
            writeI(&w, u32, hash2);

            b.allocator.free(buf);

            n2.end();
        }

        n2 = n.start("Creating Backup Sectors", 1);
        {
            var buf: [512]u8 = undefined;

            gotoSector(img_file, 1);
            _ = r.read(&buf) catch unreachable;
            gotoSector(img_file, last_sector);
            _ = w.write(&buf) catch unreachable;

            for (0..32) |i| {
                gotoSector(img_file, @truncate(2 + i));
                _ = r.read(&buf) catch unreachable;
                gotoSector(img_file, @truncate(last_sector - 33 + i));
                _ = w.write(&buf) catch unreachable;
            }
        }

        n2 = undefined;
    }
    n.end();

    // After here,
    // Writing all the partitions

    const partitions = builder.partitions.items;

    n = progress.start("Writing Partitions", partitions.len);
    {
        for (partitions) |i| {
            writePartition(b, &n, img_file, i);
            n.completeOne();
        }
    }
    n.end();
}

inline fn writePartition(b: *Build, p: *std.Progress.Node, f: fs.File, partition: *Partition) void {
    switch (partition.filesystem) {
        .FAT => writePartition_FAT(b, p, f, partition),
    }
}

fn writePartition_FAT(b: *Build, p: *std.Progress.Node, f: fs.File, partition: *Partition) void {
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
        writeI(&w, u8, 2); // FAT tables count
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
        writeI(&w, u8, 0); // extended boot signature FIXME

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

    n = p.start("Writing Content", 1);
    {
        const first_fat_sector = partition.start + reserved_sectors;
        var first_free_sector = first_fat_sector + sectors_per_fat * num_fats;
        var free_sectors_count = total_sectors - first_free_sector;
        
        const root_path = fs.realpathAlloc(b.allocator, partition.path)
        catch |err| switch (err) {
            else => @panic("Unexpected error!"),
        };
        defer b.allocator.free(root_path);

        const root_dir = fs.openDirAbsolute(root_path, .{ .iterate = true })
        catch |err| switch (err) {
            error.NotDir => @panic("Path is not a valid directory!"),
            else => @panic("Unexpected error!")
        };

        var root_walker = root_dir.walk(b.allocator) catch unreachable;
        var next_nullable = root_walker.next() catch unreachable;

        const StringList = std.ArrayList([]const u8);
        var dir_stack = StringList.init(b.allocator);
        dir_stack.append(b.allocator.dupe(u8, "") catch unreachable) catch unreachable;

        while (next_nullable != null) : (next_nullable = root_walker.next() catch unreachable) {
            const next = next_nullable.?;
            var current_dir: []const u8 = dir_stack.getLast();

            const path_dir_length = std.mem.lastIndexOfLinear(u8, next.path, std.fs.path.sep_str) orelse 0;
            const path_dir = next.path[0 .. path_dir_length];

            const data = std.fmt.allocPrint(b.allocator, "" ++
                "name: {s:\x00<26}" ++
                "kind: {s:\x00<26}" ++
                "path: {s:\x00<58}" ++
                "pdir: {s:\x00<58}",
            .{
                next.basename,
                @tagName(next.kind),
                next.path,
                path_dir
            }) catch unreachable;
            _ = w.write(data) catch unreachable;

            while (!std.mem.eql(u8, current_dir, path_dir)) {
                    b.allocator.free(dir_stack.pop().?);
                    current_dir = dir_stack.getLast();
            }

            _ = w.write(@as([]const u8, &.{0}) ** 32) catch unreachable;

            if (next.kind == .directory) {
                const dupe_path = b.allocator.dupe(u8, next.path) catch unreachable;
                dir_stack.append(dupe_path) catch unreachable;
            }
            else if (next.kind == .file) {

            }
            else std.debug.panic("Invalid entry of type \'{s}\'", .{@tagName(next.kind)});

            b.allocator.free(data);
        }

        while (dir_stack.items.len > 0) b.allocator.free(dir_stack.pop().?);
        dir_stack.deinit();
    }
    n.end();
}

inline fn gotoSector(f: fs.File, sector: u32) void {
    f.seekTo(sector * 0x200) catch unreachable;
}
inline fn gotoOffset(f: fs.File, sector: u32, offset: u32) void {
    f.seekTo(sector * 0x200 + offset) catch unreachable;
}

inline fn writeI(w: *fs.File.Writer, comptime T: type, value: T) void {
    w.writeInt(T, value, .little) catch unreachable;
}

inline fn genGuid() u128 {
    var uuid: [16]u8 = undefined;
    std.crypto.random.bytes(&uuid);

    uuid[6] = (uuid[6] & 0x0F) | 0x40;
    uuid[8] = (uuid[8] & 0x3F) | 0x80;

    return std.mem.readInt(u128, &uuid, @import("builtin").cpu.arch.endian());
}
