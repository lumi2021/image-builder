const std = @import("std");
const Build = std.Build;
const Step = Build.Step;
const fs = std.fs;
const PartitionList = std.ArrayList(*Partition);

const formats = @import("formats/formats.zig");
const layouts = @import("layouts/layouts.zig");
pub const DiskLayout = layouts.DiskLayout;
pub const FileSystem = formats.FileSystem;

pub fn addBuildDiskImage(b: *Build, layout: DiskLayout, size_sectors: usize, out_path: []const u8) *DiskBuilder {
    return DiskBuilder.create(b, layout, size_sectors, out_path);
}

pub const DiskBuilder = struct {
    owner: *Build,
    step: Step,

    layout: DiskLayout,
    size_sectors: usize,
    output_path: []const u8,
    partitions: PartitionList,

    pub fn create(b: *Build, layout: DiskLayout, size_sectors: usize, output_path: []const u8) *@This() {
        const self = b.allocator.create(@This()) catch unreachable;
        self.* = .{
            .owner = b,
            .step = Build.Step.init(.{
                .id = .install_artifact,
                .name = "Build Image",
                .owner = b,
                .makeFn = make,
            }),
            .layout = layout,
            .size_sectors = size_sectors,
            .output_path = output_path,

            .partitions = PartitionList.init(b.allocator),
        };

        return self;
    }

    /// Add a partition to the disk, using `path` as the content source (relative to the root). \
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

    n.end();

    const data_limits = try layouts.writeHeaders(builder.layout, img_file, builder, b, progress);

    const partitions = builder.partitions.items;

    n = progress.start("Writing Partitions", partitions.len);
    {
        var start = data_limits.limit_start;
        for (partitions) |i| {
            i.start = start;
            start += i.size;

            if (start > data_limits.limit_end) @panic("Partition size is out of bounds!");

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
