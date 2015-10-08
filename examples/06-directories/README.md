Most `gup` files are targets. But sometimes you'll want to build a directory.

There are two distinct cases here:

### Leaf directories

These are directories which don't contain any buildable targets inside them, and which are created in their entirety by one build script. `leaf-dir` is an example of this - its contents are an unpacked archive. It's fine to use a `gup` script named after the directory to build these.

### Directories with sub-targets

Because `gup` builds targets cleanly and atomically, it will _completely replace_ an old build result with the new one. If you had a `parent-dir` target with sub-targets of `parent-dir/a` and `parent-dir/b`, that would actually mean that whenever you built `parent-dir` it would completely replace this dir, including removing any previously-built versions of `a` and `b`. This is generally not what you want.

If you want to have a buildable directory with sub-targets, it's best to use a psuedo-file inside the directory, typically named `all` (`.all` is another common choice). This way, `gup` doesn't try to replace the entire `dir-target` directory since it's not itself a target. In this example, we also use a shadow `gup/` directory so that we don't have to check an empty `dir-target` into source control.


