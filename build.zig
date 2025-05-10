const std = @import("std");
const imageBuilder = @import("src/imageBuilder.zig");

const addBuildGPTDiskImage = imageBuilder.addBuildGPTDiskImage;

const MiB = imageBuilder.size_constants.MiB;

pub fn build(b: *std.Build) void {
    
    const disk = addBuildGPTDiskImage(b, 20*MiB, "lumiOS.img");

    disk.addPartitionBySize(
        .FAT,
        "Main",
        "disk-data",
        19*MiB
    );

    const build_step = b.step("Build", "Try to build this shit");
    build_step.dependOn(&disk.step);
    b.default_step = build_step;

}
