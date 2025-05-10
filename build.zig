const std = @import("std");
const imageBuilder = @import("image-builder/main.zig");

const addBuildGPTDiskImage = imageBuilder.addBuildGPTDiskImage;

const KiB = imageBuilder.size_constants.KiB;
const MiB = imageBuilder.size_constants.MiB;
const GPTr = imageBuilder.size_constants.GPT_reserved_sectors;

pub fn build(b: *std.Build) void {
    
    const disk = addBuildGPTDiskImage(b, 20*MiB, "mydisk.img");

    disk.addPartition(
        .vFAT,
        "Main",
        "disk-data",
        20*MiB - GPTr
    );

    const build_step = b.step("Build", "Try to build this shit");
    build_step.dependOn(&disk.step);
    b.default_step = build_step;

}
