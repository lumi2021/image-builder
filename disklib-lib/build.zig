const std = @import("std");

pub fn build(b: *std.Build) void {
    
    const module = b.createModule(.{
        .root_source_file = b.path("src/build_lib.zig"),
        .target = b.standardTargetOptions(.{}),
        .optimize = .Debug,
    });

    const lib = b.addLibrary(.{
        .name = "my-build-lib",
        .root_module = module,
    });

    b.installArtifact(lib);
}
