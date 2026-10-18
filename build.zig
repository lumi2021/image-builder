const std = @import("std");

pub fn build(b: *std.Build) void {
    const disklib_exe = b.dependency("disklib_exe", .{})
        .artifact("disklib");

    b.installDirectory(.{
        .source_dir = b.path("disk-data"),
        .install_dir = .prefix,
        .install_subdir = "disk-data",
    });

    // const run_disklib = b.addRunArtifact(disklib_exe);
    // run_disklib.addArgs(&.{
    //     "create",
    //     "disk.img",
    //     "size = 128M",
    //     "table = gpt",
    //     "label = Test",
    //     "part",
    //         "fs=vfat",
    //         "size=110M",
    //         "id=BOOT",
    //         "src=disk-data",
    //     "endpart",
    // });

    // const step = b.step("disk", "Generates the disk image");
    // step.dependOn(&run_disklib.step);

    const run_disklib = b.addRunArtifact(disklib_exe);
    run_disklib.step.dependOn(b.getInstallStep());

    run_disklib.addArgs(&.{
        "create",
        "disk.img",
        "size=128M",
        "table=gpt",
        "label=Test",
        "part",
        "fs=vfat",
        "size=110M",
        "id=BOOT",
        "src=disk-data",
        "endpart",
    });

    const disk_step = b.step("disk", "Generates the disk image");
    disk_step.dependOn(&run_disklib.step);
}
