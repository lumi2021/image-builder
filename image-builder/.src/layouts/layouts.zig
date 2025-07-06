const std = @import("std");
const imageBuilder = @import("../imageBuilder.zig");

const Gpt = @import("gpt.zig");
const Mbr = @import("mbr.zig");

pub const Limits = struct {
    limit_start: usize,
    limit_end: usize
};

pub fn writeHeaders(
    l: DiskLayout,
    img_file: std.fs.File,
    builder: *imageBuilder.DiskBuilder,
    b: *std.Build,
    progress: *const std.Progress.Node,
) !Limits {
    return switch (l) {
        .GPT => Gpt.write_headers(img_file, builder, b, progress),
        .MBR => Mbr.write_headers(img_file, builder, b, progress),
    };
}

pub const DiskLayout = enum {
    GPT,
    MBR,
};
