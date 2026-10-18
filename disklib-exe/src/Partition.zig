const std = @import("std");
const disklib = @import("./root.zig");

const FileSystem = disklib.FileSystem;
const DiskBuilder = disklib.DiskBuilder;

pub const PartitionOptions = struct {
    filesystem: FileSystem,
    name: []const u8,
    path: []const u8,
    size_sectors: usize,
    identifier: ?[]const u8 = null,
};

disk: *DiskBuilder,
options: PartitionOptions,
start: usize = 0,
