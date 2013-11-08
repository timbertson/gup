

# What gets executed?

Every .gup file gets executed with two arguments:

  - `$1` - an (absolute) path to the temporary file created for this target
  - `$2` - the (relative) path to the target, from $CWD

The built file should be saved to the file named in `$1`, rather than the file being built.
This prevents writing incorrect or partial results (e.g if some of the file is written
but then the task fails).

When a .gup script is run, its working directory (`$CWD`) is determined by:

  1. For a regular .gup file, the working directory is the directory containing the target file.
     Note that if a target `a/b/c` is built by `gup/a/b/c.gup`, then the
     `$CWD` will be a/b, *not* gup/a/b. If you want the location of
     the executing script, use `$0`.

  2. For a file named by a `Gupfile`, the working directory is set to
     the path which makes $2 (the relative path to the target) match
     what was specifid in the Gupfile. Some examples:

     src/Gupfile contents:
     > default.gup:
     >   tmp/*
     > obj/default.o.gup:
     >   *.o

    Then:
      - `gup src/tmp/foo` would run `src/default.gup` from `src/`, with `$2` set to `tmp/foo`.
      - `gup src/obj/foo.o` would run `src/obj/default.gup` from `src/obj`, with `$2` set to `foo.o`

    But if the same files were nested under `gup/` (e.g `gup/src/Gupfile`, `gup/src/default.gup`, etc,
    then the paths would remain the same - the `gup/` path containing the actual script being
    executed would be accessible only via `$0`.

These rules may seem complex, but the actual behaciour is fairly intuitive - rules get run from the target tree
(not inside any `/gup/` path), and from a directory depth consistent with the location of the .gup file.

