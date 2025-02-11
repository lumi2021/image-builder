const std = @import("std");
const Build = std.Build;
const Step = Build.Step;

pub fn AddBuildImage(b: *Build, comptime size: []const u8, out_path: []const u8) *Step {

    comptime var str_size: []const u8 = undefined;
    var multiplier: usize = 1;

    if (comptime std.ascii.isAlphabetic(size[size.len-1])) {
        str_size = comptime size[0..(size.len-1)];
        
        switch (size[size.len-1]) {
            'k' => multiplier = 1024,
            'm' => multiplier = 1024 * 1024,
            'g' => multiplier = 1024 * 1024 * 1024,
            else => @compileError("unexpected size indicator " ++ size[size.len - 1])
        }
    } else str_size = size;

    const int_size = std.fmt.parseUnsigned(usize, str_size, 16)
    catch @panic("\"" ++ str_size ++ "\" is a not valid number!");

    var newStep = BuildImageStep.create(b, int_size * multiplier, out_path);
    return &newStep.step;

}

const BuildImageStep = struct {
    step: Step,
    size_bytes: usize,
    output_path: []const u8,

    pub fn create(b: *Build, size_bytes: usize, output_path: []const u8) *@This() {

        const self = b.allocator.create(@This()) catch unreachable;

        self.* = .{
            .step = Build.Step.init(.{
                .id = .custom,
                .name = "Build Image",
                .owner = b
            }),
            .output_path = output_path,
            .size_bytes = size_bytes
        };

        return self;

    }

    pub fn make(self: *@This(), progress: *std.Progress.Node) !void {
        
        progress.start("help me", 500);
        _ = self;
        while (true) {}

    }
};
