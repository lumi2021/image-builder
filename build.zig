const std = @import("std");
const imageBuilder = @import("image-builder/main.zig");

const addBuildDiskImage = imageBuilder.addBuildDiskImage;

const KiB = imageBuilder.size_constants.KiB;
const MiB = imageBuilder.size_constants.MiB;
const GPTr = imageBuilder.size_constants.GPT_reserved_sectors;

pub fn build(b: *std.Build) void {
    
    const disk = addBuildDiskImage(b,
        .MBR,
        10*MiB + 1 + 164,
        null,
        "mydisk.img");

    disk.addGap(64);
    disk.addPartition(.vFAT, "BOOT", "disk-data/boot", 5*MiB);
    disk.addGap(100);
    disk.addPartition(.vFAT, "MAIN", "disk-data/main", 5*MiB);

    const build_step = b.step("Build", "Try to build this shit");
    build_step.dependOn(&disk.step);
    b.default_step = build_step;

}
