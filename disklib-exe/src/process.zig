const std = @import("std");
const disklib = @import("./root.zig");
const Io = std.Io;

const DiskBuilder = disklib.DiskBuilder;
const Partition = disklib.Partition;

const log = std.log.scoped(.disklib);

pub fn addBuildDiskImage(
    gpa: std.mem.Allocator,
    io: Io,
    options: DiskBuilder.Options,
) *DiskBuilder {
    return DiskBuilder.create(gpa, io, options);
}

pub fn make(gpa: std.mem.Allocator, io: Io, builder: *DiskBuilder) anyerror!void {
    log.info("Creating Image File", .{});

    const img_out_file = builder.options.output_path;
    const size_sectors = try builder.sizeSectors();

    // Create the out directory if it do not exists (a bare file name has no directory)
    if (std.fs.path.dirname(img_out_file)) |img_out_path| {
        _ = Io.Dir.cwd().access(io, img_out_path, .{}) catch
            Io.Dir.cwd().createDir(io, img_out_path, .default_dir) catch unreachable;
    }

    // Create the file
    const img_file = Io.Dir.cwd().createFile(io, img_out_file, .{ .read = true }) catch unreachable;
    defer img_file.close(io);

    // Set the file the requested disk size
    img_file.setLength(io, size_sectors * 512) catch unreachable;

    var file_writer = img_file.writer(io, &.{});
    var file_reader = img_file.reader(io, &.{});

    const data_limits = try disklib.layouts.writeHeaders(
        gpa,
        io,
        builder.options.layout,
        &file_writer,
        &file_reader,
        builder,
    );

    const partitions = builder.partitions.items;

    log.info("Writing Partitions", .{});
    {
        var start = data_limits.limit_start;
        for (0.., partitions) |i, part| {
            log.info("{} - {s}", .{ i, part.options.identifier orelse "unidentified" });

            part.start = start;
            start += part.options.size_sectors;

            if (start > data_limits.limit_end) @panic("Partition size is out of bounds!");

            try writePartition(gpa, io, &file_writer, &file_reader, part);
        }
    }
}

inline fn writePartition(
    gpa: std.mem.Allocator,
    io: Io,
    writer: *Io.File.Writer,
    reader: *Io.File.Reader,
    partition: *Partition,
) !void {
    switch (partition.options.filesystem) {
        ._unused => {},
        .empty => {},
        .vFAT => try disklib.formats.fat.writePartition(gpa, io, writer, reader, partition),
    }
}
