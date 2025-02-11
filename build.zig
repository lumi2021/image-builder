const std = @import("std");
const imageBuilder = @import("imageBuilder.zig");

const addBuildImage = imageBuilder.AddBuildImage;

pub fn build(b: *std.Build) void {
    
    const step = addBuildImage(b, "1k", ".disk-image");
    b.default_step.dependOn(step);

}
