const std = @import("std");
const imageBuilder = @import("../imageBuilder.zig");
const layouts = @import("layouts.zig");
const Crc32 = std.hash.Crc32;
const Guid = @import("../Guid.zig").Guid;

pub fn write_headers(
    writer: *std.fs.File.Writer,
    reader: *std.fs.File.Reader,
    builder: *imageBuilder.DiskBuilder,
    b: *std.Build,
    progress: *const std.Progress.Node,
) !layouts.Limits {

    // random data
    var sectors_count: usize = builder.size_sectors;
    const last_sector: u32 = @intCast(sectors_count - 1);

    const table_sectors = 32;
    sectors_count -= 1 + table_sectors * 2;

    const first_useable = 2 + table_sectors;
    const last_useable = last_sector - table_sectors - 1;

    var n = progress.start("Writing Headers", 1);
    {
        var n2 = n.start("Creating Protective MBR", 1);
        {
            // partition entry #1
            gotoOffset(writer, 0, 0x1BE);
            writeI(writer, u8, 0x00); // bootable partition

            const cylinder_0 = 2 / (255 * 63);
            const temp_0 = 2 % (255 * 63);
            const head_0: u8 = @truncate(temp_0 / 63);
            const sector_0 = (temp_0 % 63) + 1;
            const addr_0: u16 = @truncate((sector_0 & 0x3F) | ((cylinder_0 >> 2) & 0xC0));

            writeI(writer, u8, head_0); // start CHS head (legacy)
            writeI(writer, u16, addr_0); // start CHS addr (legacy)

            writeI(writer, u8, 0xEE); // partition type: GPT protective

            const cylinder_1 = last_sector / (255 * 63);
            const temp_1 = last_sector % (255 * 63);
            const head_1: u8 = @truncate(temp_1 / 63);
            const sector_1 = (temp_1 % 63) + 1;
            const addr_1: u16 = @truncate((sector_1 & 0x3F) | ((cylinder_1 >> 2) & 0xC0));

            writeI(writer, u8, head_1); // end CHS head (legacy)
            writeI(writer, u16, addr_1); // end CHS (legacy)

            writeI(writer, u32, 1); // first sector
            writeI(writer, u32, last_sector); // last sector

            // BOOT sector signature
            gotoOffset(writer, 0, 0x1FE);
            _ = writer.interface.write("\x55\xAA") catch unreachable;
            n2.end();
        }

        n2 = n.start("Creating GPT Table", 1);
        {
            gotoSector(writer, 1);

            _ = writer.interface.write("EFI PART") catch unreachable; // Signature
            _ = writer.interface.write("\x00\x00\x01\x00") catch unreachable; // Revision

            writeI(writer, u32, 92); // Header size
            writeI(writer, u32, 0); // header CRC32 (temp)
            writeI(writer, u32, 0); // Reserved

            writeI(writer, u64, 1); // Current LBA Header
            writeI(writer, u64, last_sector); // Backup LBA Header

            writeI(writer, u64, first_useable); // First usable LBA
            writeI(writer, u64, last_useable); // Last usable LBA

            const disk_guid = if (builder.identifier) |idtf|
                Guid.fromString(idtf) catch @panic("Invalid GUID identifier")
            else
                Guid.new();
            writeI(writer, u128, @bitCast(disk_guid)); // Disk GUID

            writeI(writer, u64, 2); // Partition table LBA
            writeI(writer, u32, 128); // Partition entry count
            writeI(writer, u32, 128); // Partition entry size
            writeI(writer, u32, 0); // partition table CRC32 (temp)
            n2.end();
        }

        n2 = n.start("Creating Partitions Table", 1);
        {
            const partitions = builder.partitions.items;
            var offset: usize = 2 + table_sectors;

            var utf16_buf: [72]u16 = undefined;

            var index: usize = 0;
            for (partitions) |i| {
                if (i.filesystem == ._unused) {
                    offset += i.size;
                    continue;
                }

                gotoOffset(writer, 2, @truncate(index * 128));

                switch (i.filesystem) { // paartition type GUID
                    .vFAT => {
                        _ = writer.interface.write("\x28\x73\x2a\xc1\x1f\xf8\xd2\x11") catch unreachable;
                        _ = writer.interface.write("\xba\x4b\x00\xa0\xc9\x3e\xc9\x3b") catch unreachable;
                    },
                    .empty => {
                        _ = writer.interface.write("\x00\x00\x00\x00\x00\x00\x00\x00") catch unreachable;
                        _ = writer.interface.write("\x00\x00\x00\x00\x00\x00\x00\x00") catch unreachable;
                    },
                    else => std.debug.panic("Unhandled file system {s}!", .{@tagName(i.filesystem)}),
                }

                const part_guid = if (i.identifier) |idtf|
                    Guid.fromString(idtf) catch @panic("Invalid GUID identifier")
                else
                    Guid.new();
                writeI(writer, u128, @bitCast(part_guid)); // partition unique GUID

                writeI(writer, u64, offset); // first LBA
                writeI(writer, u64, offset + i.size - 1); // last LBA

                writeI(writer, u64, 0); // attributes

                // partition name
                @memset(&utf16_buf, 0);
                _ = std.unicode.utf8ToUtf16Le(&utf16_buf, i.name) catch unreachable;
                _ = writer.interface.write(@as([*]u8, @ptrCast(&utf16_buf))[0 .. 72 * 2]) catch unreachable;

                i.start = offset + 1;
                offset += i.size;
                index += 1;
            }

            n2.end();
        }

        n2 = n.start("Calculating GPT Table's CRC32", 3);
        {
            var buf = b.allocator.alloc(u8, 128 * 128) catch unreachable;
            const buf_2: []u8 = buf[0..92];

            // calculate partition table's CRC32
            gotoSectorR(reader, 2);
            _ = reader.read(buf) catch unreachable;

            const hash1 = Crc32.hash(buf);
            n2.completeOne();

            gotoOffset(writer, 1, 0x58);
            writeI(writer, u32, hash1);

            // calculate header's CRC32
            gotoSectorR(reader, 1);
            _ = reader.read(buf_2) catch unreachable;

            std.mem.writeInt(u32, buf_2[0x10..0x14], 0, .little);
            const hash2 = Crc32.hash(buf_2);
            n2.completeOne();

            gotoOffset(writer, 1, 0x10);
            writeI(writer, u32, hash2);

            b.allocator.free(buf);

            n2.end();
        }

        n2 = n.start("Creating Backup Sectors", 1);
        {
            var buf: [512]u8 = undefined;

            gotoSectorR(reader, 1);
            _ = reader.read(&buf) catch unreachable;
            gotoSector(writer, last_sector);
            _ = writer.interface.write(&buf) catch unreachable;

            for (0..32) |i| {
                gotoSectorR(reader, @truncate(2 + i));
                _ = reader.read(&buf) catch unreachable;
                gotoSector(writer, @truncate(last_sector - 33 + i));
                _ = writer.interface.write(&buf) catch unreachable;
            }
        }

        n2 = undefined;
    }
    n.end();

    return .{
        .limit_start = first_useable,
        .limit_end = last_useable,
    };
}

// utils
const gotoSector = imageBuilder.gotoSector;
const gotoOffset = imageBuilder.gotoOffset;
const gotoSectorR = imageBuilder.gotoSectorR;
const gotoOffsetR = imageBuilder.gotoOffsetR;
const writeI = imageBuilder.writeI;
