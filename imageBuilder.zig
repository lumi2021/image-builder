const std = @import("std");
const Build = std.Build;
const Step = Build.Step;
const fs = std.fs;
const Crc32 = std.hash.Crc32;

pub fn AddBuildImage(b: *Build, comptime size: []const u8, out_path: []const u8) *ImageBuilder {
    comptime var str_size: []const u8 = undefined;
    var multiplier: usize = 1;

    if (comptime std.ascii.isAlphabetic(size[size.len - 1])) {
        str_size = comptime size[0..(size.len - 1)];

        switch (size[size.len - 1]) {
            'k' => multiplier = 1024,
            'm' => multiplier = 1024 * 1024,
            'g' => multiplier = 1024 * 1024 * 1024,
            else => @compileError("unexpected size indicator '" ++ size[size.len - 1 .. size.len] ++ "'"),
        }
    } else str_size = size;

    const int_size = comptime std.fmt.parseInt(usize, str_size, 16) catch @compileError("\"" ++ str_size ++ "\" is a not valid hexadecimal unsigned number!");

    return ImageBuilder.create(b, int_size * multiplier, out_path);
}

pub const ImageBuilder = struct {
    build: *Build,
    step: Step,
    size_bytes: usize,
    output_path: []const u8,

    pub fn create(b: *Build, size_bytes: usize, output_path: []const u8) *@This() {
        const self = b.allocator.create(@This()) catch unreachable;
        self.* = .{ .build = b, .step = Build.Step.init(.{ .id = .custom, .name = "Build Image", .owner = b, .makeFn = make }), .output_path = output_path, .size_bytes = size_bytes };

        return self;
    }
};

fn make(step: *Step, progress: std.Progress.Node) anyerror!void {
    const builder: *ImageBuilder = @fieldParentPtr("step", step);
    const b = builder.build;

    var n = progress.start("creating image file", 1);

    const paths = [_][]const u8{ b.install_path, builder.output_path };
    const img_out_file = std.fs.path.joinZ(b.allocator, &paths) catch unreachable;
    defer b.allocator.free(img_out_file);
    const img_out_path = std.fs.path.dirname(img_out_file).?;

    // Create the out directory if it do not exists
    _ = fs.accessAbsolute(img_out_path, .{ .mode = .read_write })
        catch fs.cwd().makeDir(img_out_path) catch unreachable;
    
    // Create the file
    const img_file = fs.cwd().createFile(img_out_file, .{ .read = true }) catch unreachable;
    defer img_file.close();

    // Set the file the requested disk size
    img_file.setEndPos(builder.size_bytes) catch unreachable;

    const w = img_file.writer();
    const r = img_file.reader();

    n.end();
    n = progress.start("writing sectors", 1);
    {
        
        var n2 = n.start("MBR", 1);
        img_file.seekTo(0x1FE) catch unreachable;
        _ = img_file.write("\x55\xAA") catch unreachable;
        n2.end();

        n2 = n.start("GPT", 1);
        img_file.seekTo(0x200) catch unreachable;
        
        _ = w.write("EFI PART") catch unreachable;                              // Signature
        _ = w.write("\x00\x01\x00\x00") catch unreachable;                      // Revision
        _ = w.writeInt(u64, 96, .little) catch unreachable;    // Header size
        _ = w.writeInt(u32, 0 , .little) catch unreachable;    // header CRC32 (temp)

        _ = w.writeInt(u64, 1, .little) catch unreachable;      // Primary LBA Header
        _ = w.writeInt(u64, 1, .little) catch unreachable;      // Secondary LBA Header

        // TODO lots of more data

        // back a little to calculate header CRC32
        img_file.seekTo(0x200) catch unreachable;
        var header: [96]u8 = undefined;
        _ = r.read(&header) catch unreachable;
        const hash = Crc32.hash(&header);
        img_file.seekTo(0x200 + 0x10) catch unreachable;
        _ = w.writeInt(u32, hash, .little) catch unreachable;

        n2.end();
        n2 = undefined;
    }
    n.end();
}
