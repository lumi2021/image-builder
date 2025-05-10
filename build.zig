const std = @import("std");
const imageBuilder = @import("src/imageBuilder.zig");

const addBuildGPTDiskImage = imageBuilder.addBuildGPTDiskImage;

const KiB = imageBuilder.size_constants.KiB;
const MiB = imageBuilder.size_constants.MiB;
const GPTr = imageBuilder.size_constants.GPT_reserved_sectors;

pub fn build(b: *std.Build) void {
    
    const disk = addBuildGPTDiskImage(b, 20*MiB, "lumiOS.img");

    disk.addPartition(
        .FAT,
        "Main",
        "disk-data",
        19*MiB
    );

    const build_step = b.step("Build", "Try to build this shit");
    build_step.dependOn(&disk.step);
    b.default_step = build_step;

}
