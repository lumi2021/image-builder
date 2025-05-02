const std = @import("std");
const imageBuilder = @import("imageBuilder.zig");

const addBuildGPTDiskImage = imageBuilder.addBuildGPTDiskImage;

pub fn build(b: *std.Build) void {
    
    const disk = addBuildGPTDiskImage(b, "1M", "lumiOS.img");

    disk.addPartitionBySectors(
        .FAT,
        "Data",
        "disk-data",
        2014 - 35
    );

    const build_step = b.step("Build", "Try to build this shit");
    build_step.dependOn(&disk.step);
    b.default_step = build_step;

}
