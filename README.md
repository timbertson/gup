# What is gup?


# Origins

`gup` is based loosely on the [redo][] build system.
I used `redo` heavily for a number of months, and came
to the conclusion that some of its features were either
too fragile or too limited to support the way I wanted
to build software.

If you're familiar with `redo`, here are the main
(intentional) differences:

 - `gup` will rebuild targets if the stored metadata
   goes missing or is incorrect, rather than silently(*)
   assuming they never need to be built again.

   (*) `redo` does print a warning, but that's not easily
   missed in automated build processes, and requires manual
   intervention to fix the problem.

 - `gup` uses Gupfiles to specify exactly what should
   be built by each generic build script, rather than
   segregating targets only by their file extension
   or resorting to a `default.do` that tries to
   build every missing file, ever.

 - `gup` allows you to keep your source tree clean,
   by using a "shadow" gup/ directory - no need to
   scatter build and output files amongst your source
   code.

As a side effect of the above differences, gup never thinks
that a target is a source when it's actually a target, or
vice versa. `redo` has this problem, and it's suprisingly
hard to fix (I tried).

# Licence

Gup is distributed under th LGPL - see the LICENCE file.

### Copyrights

jwack.py and  lock.py are adapted from the [redo][]
project, which is LGP and is Copyright Avery Pennarun

All other source code is Copyright Tim Cuthbertson, 2013.

[redo]: https://github.com/apenwarr/redo

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

