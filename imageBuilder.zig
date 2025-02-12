const std = @import("std");
const Build = std.Build;
const Step = Build.Step;
const fs = std.fs;

pub fn AddBuildImage(b: *Build, comptime size: []const u8, out_path: []const u8) *ImageBuilder {

    comptime var str_size: []const u8 = undefined;
    var multiplier: usize = 1;

    if (comptime std.ascii.isAlphabetic(size[size.len-1])) {
        str_size = comptime size[0..(size.len-1)];
        
        switch (size[size.len-1]) {
            'k' => multiplier = 1024,
            'm' => multiplier = 1024 * 1024,
            'g' => multiplier = 1024 * 1024 * 1024,
            else => @compileError("unexpected size indicator '" ++ size[size.len - 1..size.len] ++ "'")
        }
    } else str_size = size;

    const int_size = comptime std.fmt.parseInt(usize, str_size, 16)
    catch @compileError("\"" ++ str_size ++ "\" is a not valid hexadecimal unsigned number!");

    return ImageBuilder.create(b, int_size * multiplier, out_path);
}

pub const ImageBuilder = struct {
    step: Step,
    size_bytes: usize,
    output_path: []const u8,

    pub fn create(b: *Build, size_bytes: usize, output_path: []const u8) *@This() {

        const self = b.allocator.create(@This()) catch unreachable;
        self.* = .{
            .step = Build.Step.init(.{
                .id = .custom,
                .name = "Build Image",
                .owner = b,
                .makeFn = make
            }),
            .output_path = output_path,
            .size_bytes = size_bytes
        };

        return self;

    }
};

fn make(step: *Step, progress: std.Progress.Node) anyerror!void {
    
    const builder: *ImageBuilder = @fieldParentPtr("step", step);
    var n = progress.start("creating image file", 1);

    const img_file = fs.cwd().createFile(builder.output_path, .{}) catch unreachable;
    defer img_file.close();

    img_file.setEndPos(builder.size_bytes) catch unreachable;

    n.end();
    n = progress.start("writing directories", 1000);

    // TODO write this shit
    n.setCompletedItems(100);

    n.end();

}
