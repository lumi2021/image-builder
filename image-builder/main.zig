const std = @import("std");
const Build = std.Build;

const main = @import(".src/imageBuilder.zig");
const constants = @import(".src/constants.zig");

/// Usefull general constants for sizes, padding, etc
pub const size_constants = constants.size_constants;

/// Creates a `.img` file relative to `.zig-out`. \
/// Make sure `size_sectors` is big enough to fit all the content!
pub inline fn addBuildGPTDiskImage(b: *Build, size_sectors: usize, out_path: []const u8) *main.DiskBuilder {
    return main.addBuildGPTDiskImage(b, size_sectors, out_path);
}

/// File systems supported by this tool
pub const FileSystem = main.FileSystem;
