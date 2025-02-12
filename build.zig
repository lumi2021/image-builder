const std = @import("std");
const imageBuilder = @import("imageBuilder.zig");

const addBuildImage = imageBuilder.AddBuildImage;

pub fn build(b: *std.Build) void {
    
    const step = addBuildImage(b, "5k", ".disk-image");

    const build_step = b.step("b", "Ty build this shit");
    build_step.dependOn(&step.step);
    b.default_step = build_step;

}
