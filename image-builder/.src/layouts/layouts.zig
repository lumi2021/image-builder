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
    file_writer: *std.fs.File.Writer,
    file_reader: *std.fs.File.Reader,
    builder: *imageBuilder.DiskBuilder,
    b: *std.Build,
    progress: *const std.Progress.Node,
) !Limits {
    return switch (l) {
        .GPT => Gpt.write_headers(file_writer, file_reader, builder, b, progress),
        .MBR => Mbr.write_headers(file_writer, file_reader, builder, b, progress),
    };
}

pub const DiskLayout = enum {
    GPT,
    MBR,
};
