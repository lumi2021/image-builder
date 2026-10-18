const std = @import("std");
const Build = std.Build;

const constants = @import("constants.zig");

pub const size_constants = constants.size_constants;

pub const Image = struct {
    width: u32,
    height: u32,
};

pub fn addBuildDiskImage(
    b: *Build,
    layout: DiskLayout,
    size_sectors: usize,
    identifier: ?[]const u8,
    out_path: []const u8,
) *DiskBuilder {
    _ = b;
    _ = layout;
    _ = size_sectors;
    _ = identifier;
    _ = out_path;
}

fn make(step: *Step, options: Step.MakeOptions) anyerror!void {
    _ = step;
    _ = options;
}

inline fn writePartition(
    b: *Build,
    p: *std.Progress.Node,
    writer: *fs.File.Writer,
    reader: *fs.File.Reader,
    partition: *Partition,
) void {
    _ = b;
    _ = p;
    _ = writer;
    _ = reader;
    _ = partition;
}
