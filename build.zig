const std = @import("std");
const imageBuilder = @import("image-builder/main.zig");

const addBuildDiskImage = imageBuilder.addBuildDiskImage;

const KiB = imageBuilder.size_constants.KiB;
const MiB = imageBuilder.size_constants.MiB;
const GPTr = imageBuilder.size_constants.GPT_reserved_sectors;

pub fn build(b: *std.Build) void {
    
    const disk = addBuildDiskImage(b, .MBR, 15*MiB + GPTr, "mydisk.img");

    disk.addPartition(.vFAT, "BOOT", "disk-data/boot", 5*MiB);
    disk.addPartition(.vFAT, "MAIN", "disk-data/main", 5*MiB);

    const build_step = b.step("Build", "Try to build this shit");
    build_step.dependOn(&disk.step);
    b.default_step = build_step;

}
