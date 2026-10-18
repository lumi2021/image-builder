const std = @import("std");
const disklib = @import("./root.zig");
const Io = std.Io;

const PartitionTable = disklib.PartitionTable;
const FileSystem = disklib.FileSystem;
const DiskBuilder = disklib.DiskBuilder;
const Partition = disklib.Partition;
const PartitionList = std.ArrayList(*Partition);

pub const Options = struct {
    layout: PartitionTable,
    output_path: []const u8,
    size_sectors: ?usize = null,
    identifier: ?[]const u8 = null,
    label: ?[]const u8 = null,
};

pub const GapOptions = struct {
    size_sectors: usize,
};

allocator: std.mem.Allocator,
io: Io,
options: Options,
partitions: PartitionList,

__gaps: usize = 0,

pub fn create(alloc: std.mem.Allocator, io: Io, options: Options) *@This() {
    const self = alloc.create(@This()) catch unreachable;
    self.* = .{
        .allocator = alloc,
        .io = io,
        .options = options,
        .partitions = .empty,
    };

    return self;
}

/// Add a partition to the disk, using `path` as the content source (relative to the root). \
/// Make sure `length` is big enough to fit all the content!
pub fn addPartition(disk: *DiskBuilder, options: Partition.PartitionOptions) void {
    const new_partition = disk.allocator.create(Partition) catch unreachable;
    disk.partitions.append(disk.allocator, new_partition) catch unreachable;

    new_partition.* = .{
        .disk = disk,
        .options = options,
    };
}

/// Add an gap after the last partition
pub fn addGap(disk: *DiskBuilder, options: GapOptions) void {
    const gap = disk.allocator.create(Partition) catch unreachable;
    disk.partitions.append(disk.allocator, gap) catch unreachable;

    const name = disk.allocator.alloc(u8, 5) catch @panic("OOM");
    _ = std.fmt.bufPrint(name, "gap{:0>2}", .{disk.__gaps}) catch unreachable;

    gap.* = .{
        .disk = disk,
        .options = .{
            .filesystem = ._unused,
            .name = name,
            .path = "",
            .size_sectors = options.size_sectors,
        },
    };

    disk.__gaps += 1;
}

/// Total disk size in sectors; `size=` is required to write an image.
pub fn sizeSectors(disk: *const DiskBuilder) !usize {
    return disk.options.size_sectors orelse {
        std.log.err("disk size is required (size=...)", .{});
        return error.MissingDiskSize;
    };
}
