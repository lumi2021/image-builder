const std = @import("std");
const disklib = @import("../root.zig");
const Io = std.Io;

const PartitionTable = disklib.PartitionTable;
const Gpt = @import("gpt.zig");
const Mbr = @import("mbr.zig");

pub const Limits = struct { limit_start: usize, limit_end: usize };

pub fn writeHeaders(
    gpa: std.mem.Allocator,
    io: Io,
    layout: PartitionTable,
    file_writer: *Io.File.Writer,
    file_reader: *Io.File.Reader,
    builder: *disklib.DiskBuilder,
    //progress: *const std.Progress.Node,
) !Limits {
    return switch (layout) {
        .GPT => Gpt.write_headers(gpa, io, file_writer, file_reader, builder),
        .MBR => Mbr.write_headers(gpa, io, file_writer, file_reader, builder),
    };
}
