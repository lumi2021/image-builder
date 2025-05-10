const std = @import("std");
const Build = std.Build;
const Step = Build.Step;
const fs = std.fs;
const Crc32 = std.hash.Crc32;
const PartitionList = std.ArrayList(*Partition);

const formats = @import("formats/formats.zig");
pub const FileSystem = formats.FileSystem;

pub fn addBuildGPTDiskImage(b: *Build, size_sectors: usize, out_path: []const u8) *DiskBuilder {
    return DiskBuilder.create(b, size_sectors, out_path);
}

pub const DiskBuilder = struct {
    owner: *Build,
    step: Step,

    size_sectors: usize,
    output_path: []const u8,
    partitions: PartitionList,

    pub fn create(b: *Build, size_sectors: usize, output_path: []const u8) *@This() {
        const self = b.allocator.create(@This()) catch unreachable;
        self.* = .{
            .owner = b,
            .step = Build.Step.init(.{
                .id = .custom,
                .name = "Build Image",
                .owner = b,
                .makeFn = make,
            }),
            .output_path = output_path,
            .size_sectors = size_sectors,

            .partitions = PartitionList.init(b.allocator),
        };

        return self;
    }

    /// Add a partition to the GPT disk, using `path` as the content source (relative to the root). \
    /// Make sure `length` is big enough to fit all the content!
    pub fn addPartition(d: *DiskBuilder, fsys: FileSystem, name: []const u8, path: []const u8, length: usize) void {
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

pub const Partition = struct {
    name: []const u8,
    path: []const u8,
    filesystem: FileSystem,

    start: usize = undefined,
    size: usize,

    owner: *Build,
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
                    .vFAT => {
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
        .vFAT => formats.fat.writePartition(b, p, f, partition),
    }
}


// utils
pub inline fn gotoSector(f: fs.File, sector: u32) void {
    f.seekTo(sector * 0x200) catch unreachable;
}
pub inline fn gotoOffset(f: fs.File, sector: u32, offset: usize) void {
    f.seekTo(sector * 0x200 + offset) catch unreachable;
}

pub inline fn writeI(w: *fs.File.Writer, comptime T: type, value: T) void {
    w.writeInt(T, value, .little) catch unreachable;
}

pub inline fn genGuid() u128 {
    var uuid: [16]u8 = undefined;
    std.crypto.random.bytes(&uuid);

    uuid[6] = (uuid[6] & 0x0F) | 0x40;
    uuid[8] = (uuid[8] & 0x3F) | 0x80;

    return std.mem.readInt(u128, &uuid, @import("builtin").cpu.arch.endian());
}

pub const SectorAllocator = struct {
    first: u32,
    length: u32,

    pub fn getOne(s: *@This()) u32 {
        if (s.length == 0) std.debug.panic("No more sectors left!", .{});
        s.first += 1;
        s.length -= 1;
        return s.first - 1;
    }
    pub fn peek(s: @This()) u32 {
        return s.first;
    }
    pub fn canFit(s: @This(), len: usize) bool {
        return s.length >= len;
    }
};
