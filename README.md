# LUMI's Image Building Steps for Zig;

This is a very tiny library that I made for generating disk images
in the zig build script.

It is fully written in zig and completelly system-independent.

## How to settup it in your project:

1. Clone this repository;
2. Copy the `image-builder/` directory inside your project's root or dependency directory;
3. See the documentation about how to use it.

## Content and Documentation:

Inside `image-builder/` there are 2 itens:
```
image-builder/
 |-- main.zig  -- Main namespace interface
 '-- .src/     -- Implementation of the library
```
You should only import `main.zig` and never directly use anything inside
`.src/` if you don't know exactly what you're doing!

---

In your build script, create a reference for `imageBuilder.zig` as follows:
```zig
const imageBuilder = @import("image-builder/main.zig");
```

Also create references for important constants:

```zig
const KiB = imageBuilder.size_constants.KiB;                    // 1 KiB in sectors size
const MiB = imageBuilder.size_constants.MiB;                    // i MiB in sectors size
const GPTr = imageBuilder.size_constants.GPT_reserved_sectors;  // GPT reserved sectors
```

You can create a GPT disk by calling the `addBuildGPTDiskImage()` function.
It returns a `Disk` structure that contains the build step and some usefull
functions to manipulate it data:

```zig
const disk = imageBuilder.addBuildGPTDiskImage(
    b,              // The `*Build` reference
    20*MiB,         // The size of the disk, in sectors
    "mydisk.img"    // The image file name, relative to `zig-out`
);
```

To create a partition inside the disk, you can call tha function `addPartition()` in
the disk instance. Notice that you need togive to it a path to a directory. This
directory is the source of the content of the partition, relative to the project root
directory:

```zig
disk.addPartition(
    .FAT,           // The file system
    "Main",         // The partition label
    "disk-data",    // The source directory
    20*MiB - GPTr   // The partition size
);
```

and at the end, don't forget to link the disk creation step with some already
existent:

```zig
build_step.dependOn(&disk.step);
// or
b.default_step = &disk.step;
```

**For more information about how to use the tool, check [build.zig](build.zig) or the module files!**

## Development Status:

```
Version: 1.0
```
```
| Disk Type    | Implemented | Tested |
|--------------|-------------|--------|
| GPT          |     🟩     |   ⚠️   |
| MBR          |     🔴     |   🔴   |
| Hybrid       |     🔴     |   🔴   |
| Free         |     🔴     |   🔴   |
```
```
| File Systems | Implemented | Tested |
---------------|-------------|--------|
| vFAT         |     🟩     |   ⚠️   |
| Ext2         |     🔴     |   🔴   |
| Ext3         |     🔴     |   🔴   |
| Ext4         |     🔴     |   🔴   |
| NTFS         |     🔴     |   🔴   |
| Btrfs        |     🔴     |   🔴   |
| ISO 9660     |     🔴     |   🔴   |
```

> obs: disk types and file systems listed here are planned to be added at some moment

## Using and Contributing:

Feel free to use this code how you want, this project is under the [MIT license!](LICENSE) \
Feel free to contribute using the tool, sending issues or pull requests!
