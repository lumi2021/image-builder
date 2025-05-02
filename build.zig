const std = @import("std");
const imageBuilder = @import("imageBuilder.zig");

const addBuildGPTDiskImage = imageBuilder.addBuildGPTDiskImage;

pub fn build(b: *std.Build) void {
    
    const disk = addBuildGPTDiskImage(b, "1M", "lumiOS.img");

    var boot_partition = disk.addPartitionBySectors(.FAT, "Boot", 10);
    var data_partition = disk.addPartitionBySectors(.FAT, "Data", 2014 - 45);

    boot_partition = undefined;
    data_partition = undefined;

    const build_step = b.step("Build", "Try to build this shit");
    build_step.dependOn(&disk.step);
    b.default_step = build_step;

}
