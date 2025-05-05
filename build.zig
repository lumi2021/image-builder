const std = @import("std");
const imageBuilder = @import("src/imageBuilder.zig");

const addBuildGPTDiskImage = imageBuilder.addBuildGPTDiskImage;

pub fn build(b: *std.Build) void {
    
    const disk = addBuildGPTDiskImage(b, "20M", "lumiOS.img");

    disk.addPartitionBySize(
        .FAT,
        "Data",
        "disk-data",
        19 * 1024 * 1024
    );

    const build_step = b.step("Build", "Try to build this shit");
    build_step.dependOn(&disk.step);
    b.default_step = build_step;

}
