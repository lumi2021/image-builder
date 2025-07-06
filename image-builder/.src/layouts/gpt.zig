const std = @import("std");
const imageBuilder = @import("../imageBuilder.zig");
const layouts = @import("layouts.zig");
const Crc32 = std.hash.Crc32;

pub fn write_headers(
    img_file: std.fs.File,
    builder: *imageBuilder.DiskBuilder,
    b: *std.Build,
    progress: *const std.Progress.Node,
) !layouts.Limits {

    var w = img_file.writer();
    const r = img_file.reader();

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
            gotoOffset(img_file, 0, 0x1BE);
            writeI(&w, u8, 0x00); // bootable partition

            const cylinder_0 = 2 / (255 * 63);
            const temp_0 = 2 % (255 * 63);
            const head_0: u8 = @truncate(temp_0 / 63);
            const sector_0 = (temp_0 % 63) + 1;
            const addr_0: u16 = @truncate((sector_0 & 0x3F) | ((cylinder_0 >> 2) & 0xC0));

            writeI(&w, u8, head_0); // start CHS head (legacy)
            writeI(&w, u16, addr_0); // start CHS addr (legacy)

            writeI(&w, u8, 0xEE); // partition type: GPT protective

            const cylinder_1 = last_sector / (255 * 63);
            const temp_1 = last_sector % (255 * 63);
            const head_1: u8 = @truncate(temp_1 / 63);
            const sector_1 = (temp_1 % 63) + 1;
            const addr_1: u16 = @truncate((sector_1 & 0x3F) | ((cylinder_1 >> 2) & 0xC0));

            writeI(&w, u8, head_1); // end CHS head (legacy)
            writeI(&w, u16, addr_1); // end CHS (legacy)

            writeI(&w, u32, 1); // first sector
            writeI(&w, u32, last_sector); // last sector

            // BOOT sector signature
            gotoOffset(img_file, 0, 0x1FE);
            _ = img_file.write("\x55\xAA") catch unreachable;
            n2.end();
        }

        n2 = n.start("Creating GPT Table", 1);
        {
            gotoSector(img_file, 1);

            _ = w.write("EFI PART") catch unreachable; // Signature
            _ = w.write("\x00\x00\x01\x00") catch unreachable; // Revision

            writeI(&w, u32, 92); // Header size
            writeI(&w, u32, 0); // header CRC32 (temp)
            writeI(&w, u32, 0); // Reserved

            writeI(&w, u64, 1); // Current LBA Header
            writeI(&w, u64, last_sector); // Backup LBA Header

            writeI(&w, u64, first_useable); // First usable LBA
            writeI(&w, u64, last_useable); // Last usable LBA

            writeI(&w, u128, genGuid()); // Disk GUID

            writeI(&w, u64, 2); // Partition table LBA
            writeI(&w, u32, 128); // Partition entry count
            writeI(&w, u32, 128); // Partition entry size
            writeI(&w, u32, 0); // partition table CRC32 (temp)
            n2.end();
        }

        n2 = n.start("Creating Partitions Table", 1);
        {
            const partitions = builder.partitions.items;
            var offset: usize = 2 + table_sectors;

            var utf16_buf: [72]u16 = undefined;

            for (partitions, 0..) |i, index| {
                gotoOffset(img_file, 2, @truncate(index * 128));

                switch (i.filesystem) { // paartition type GUID
                    .vFAT => {
                        _ = w.write("\x28\x73\x2a\xc1\x1f\xf8\xd2\x11") catch unreachable;
                        _ = w.write("\xba\x4b\x00\xa0\xc9\x3e\xc9\x3b") catch unreachable;
                    },
                }
                writeI(&w, u128, genGuid()); // partition unique GUID

                writeI(&w, u64, offset); // first LBA
                writeI(&w, u64, offset + i.size); // last LBA

                writeI(&w, u64, 0); // attributes

                // partition name
                @memset(&utf16_buf, 0);
                _ = std.unicode.utf8ToUtf16Le(&utf16_buf, i.name) catch unreachable;
                _ = w.write(@as([*]u8, @ptrCast(&utf16_buf))[0 .. 72 * 2]) catch unreachable;

                i.start = offset;
                offset += i.size + 1;
            }

            n2.end();
        }

        n2 = n.start("Calculating GPT Table's CRC32", 3);
        {
            var buf = b.allocator.alloc(u8, 128 * 128) catch unreachable;
            const buf_2: []u8 = buf[0..92];

            // back a little
            gotoSector(img_file, 2);

            // calculate partition table's CRC32
            _ = r.read(buf) catch unreachable;
            const hash1 = Crc32.hash(buf);
            n2.completeOne();

            gotoOffset(img_file, 1, 0x58);
            writeI(&w, u32, hash1);

            // calculate header's CRC32
            gotoSector(img_file, 1);
            _ = r.read(buf_2) catch unreachable;
            std.mem.writeInt(u32, buf_2[0x10..0x14], 0, .little);
            const hash2 = Crc32.hash(buf_2);
            n2.completeOne();

            gotoOffset(img_file, 1, 0x10);
            writeI(&w, u32, hash2);

            b.allocator.free(buf);

            n2.end();
        }

        n2 = n.start("Creating Backup Sectors", 1);
        {
            var buf: [512]u8 = undefined;

            gotoSector(img_file, 1);
            _ = r.read(&buf) catch unreachable;
            gotoSector(img_file, last_sector);
            _ = w.write(&buf) catch unreachable;

            for (0..32) |i| {
                gotoSector(img_file, @truncate(2 + i));
                _ = r.read(&buf) catch unreachable;
                gotoSector(img_file, @truncate(last_sector - 33 + i));
                _ = w.write(&buf) catch unreachable;
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
const writeI = imageBuilder.writeI;
const genGuid = imageBuilder.genGuid;
