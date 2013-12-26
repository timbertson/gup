# What is gup?

Gup is a general purpose, recursive, top down software build system. It
doesn't care what language or framework your project uses. It has almost no
syntax. It doesn't even care what language you write your *build* rules in,
which is a fairly novel concept for a build system. It freely allows nesting
of components and projects, and doesn't care where you build things from
(similar to a recursive `make` setup, but without the downsides).

It's very similar to [redo][], which was designed by Daniel J. Bernstein and
implemented by Avery Pennarun. So I can't take much credit for inventing it,
it's really a refinement of an already-great idea.

Gup doesn't require you to specify your dependencies up-front, just an
executable script which will build a target. This can be written in any
language that supports shebang-style scripts (files beginning with
`#!/path/to-interpreter`), and you can freely mix projects or components with
build scripts written in different languages.

In each build script script, you declare your dependencies as you need them,
simply by telling gup to make sure they're up to date. This allows you to keep
"the place where you use a file" and "the place where you declare a dependency
on a file" colocated, and even to create abstractions that handle these
details for you. This makes it much easier to create correct dependency
information compared to systems like `make` which rely on discipline and
intimate knowledge of build internals to maintain correct dependencies.

# How do I install it?

A repository-local installation is the most foolproof at the moment.

 - From a git checkout:

        make bin
        cp bin/* <your-project-workspace>/tools

 - From a released tarball:

        cp bin/* <your-project-workspace>/tools

**Note**: When run from a relative or absolute path, `gup`
will bootstrap itself by adding the directory containing
it to `$PATH`, so that executing `gup` will do the right thing
from within a build script. So you may wish to place it in
its own directory to avoid accidentally adding other scripts
to `$PATH`.

### Python dependency

Gup currently requires python 2.x. I have tested it on 2.7,
I don't know how it fares in versions greater or less than this.
Patches welcome if you find something broken on your python
version.

### Using it via `make`

For convenience, you may wish to provide a `Makefile` that
simply delegates to `gup`. You can find an example `Makefile`
in the `resources/` directory.

Other methods coming soon.

# How does it build stuff?

A trivial example would be:

`target.gup:`

    #!/bin/bash
    gup -u source
    cat source > "$1"
    echo "## Built by gup" >> "$1"

This will build the file called `target` in the current directory, copying the
contents of the file called `source` and adding a fairly useless footer
comment. Because it called `gup -u source`, gup knows that it should be
rebuilt whenever `source` is modified.

(**Note:** `gup target` will cause target to rebuilt regardless of its state.
To rebuild a target only when it's out of date, use `gup -u target`)

Obviously, that small example doesn't tell you everything you need to know,
but hopefully it gives you a basic idea of how `gup` works. Here are the full
details:

### The search path

When you run `gup build/foo` from `/home/tim/proj`, gup will look for *direct*
build scripts, in this order:

  - build/foo.gup
  - build/gup/foo.gup
  - gup/build/foo.gup
  - ../gup/proj/build/foo.gup
  - ../../gup/tim/proj/build/foo.gup
  - ../../../gup/home/tim/proj/build/foo.gup

Obviously, it's getting unlikely that you would keep a root /gup folder, but
gup doesn't really know where your project might end, so it just keeps
searching up to the root of your filesystem for consistency (e.g you may have
projects nested inside other projects, you wouldn't want it to stop at the
root of the innermost project, because then it would change behaviour based on
where it was called from).

Notice that this search pattern means you can choose whether to keep your
build scripts co-located with targets, or whether you keep them in a "shadow"
directory structure under gup/ somewhere. Having .gup files next to targets
can be convenient for small projects, but larger projects will usually want to
use a gup/ folder structure. Also, a gup/ structure can contain build scripts
for targets in directories that don't (yet) exist, which can be very useful.

After `gup` has exhausted the search for direct build scripts, it will start
looking for indirect build scripts, which are always named `Gupfile`. A
Gupfile has the syntax:

    BUILDSCRIPT:
      TARGET
      TARGET2
      TARGET3

That is, a non-indented line names a build script - any file path (relative to
the directory containing this Gupfile). Each following indented line is a
target pattern, which may include the `*` wildcard to match anything except a
"/", and `**` to match anything including "/". A target pattern beginning with
`!` inverts the match.

The search for Gupfiles follows a similar pattern as the search for direct
build scripts, but if it fails to find a match for "foo", it'll start to look
in higher directories for a Gupfile that knows how to build "build/foo".

using pattern "foo":

    - build/Gupfile
    - build/gup/Gupfile
    - gup/build/Gupfile
    - ../gup/proj/build/Gupfile
    - (...)

using pattern "build/foo":

    - Gupfile
    - gup/Gupfile
    - ../../gup/tim/proj/foo.gup
    - ../../../gup/home/tim/proj/foo.gup

using pattern "proj/build/foo":

    - ../Gupfile
    - ../gup/Gupfile
    - ../../gup/tim/proj/foo.gup
    - ../../../gup/home/tim/proj/foo.gup

etc.

This search behaviour may seem a little hard to follow, but it's fairly
intuitive once you actually start using it. It's also worth noting that if you
create a "more specific" build script for a target which has already been
built, `gup` will know that the target needs to be rebuilt using the new build
script, just like it rebuilds a target when the build script is modified.

### Running build scripts

Once `gup` has found the script to build a given target, it runs it as a
script. It will interpret shebang lines so that you don't actually have to
make your script executable, but you can also use an actual executable (with
no shebang line) if you need to. Relative script paths in the shebang line are
supported, and (unlike the default UNIX behaviour) are resolved relative to
the directory containing the script, rather than the current working
directory.

Every build script gets executed with two arguments:

  - `$1` - the (absolute) path to a temporary file created for this target
  - `$2` - the (relative) path to the target, from $CWD

The built file should be saved to the file named in `$1`, rather than the file
being built. This prevents writing incorrect or partial results (e.g if some
of the file is written but then the task fails, or if the build is cancelled
in the middle of writing a file).

When a build script is run, its working directory (`$CWD`) is determined by:

  1. For a direct build script, the working directory is the directory
     containing the target file. Note that if a target `a/b/c` is built by
     `gup/a/b/c.gup`, then the `$CWD` will be a/b, *not* gup/a/b. If you want
     the location of the executing script, use `$0`.

  2. For a file named by a `Gupfile`, the working directory is set to the path
     which makes $2 (the relative path to the target) match what was specified
     in the Gupfile. Some examples:

     src/Gupfile contents:

         default.gup:
           tmp/*
         obj/default.o.gup:
           *.o

    Then:

      - `gup src/tmp/foo` would run `src/default.gup` from `src/`, with `$2`
        set to `tmp/foo`.
      - `gup src/obj/foo.o` would run `src/obj/default.gup` from `src/obj`,
        with `$2` set to `foo.o`

    But if the same files were nested under `gup/` (e.g `gup/src/Gupfile`,
    `gup/src/default.gup`, etc, then the paths would remain the same - the
    `gup/` path containing the actual script being executed would be
    accessible only via `$0`.

Again, these rules may seem complex to read, but the actual behaviour is
fairly intuitive - rules get run from the target tree (not inside any `/gup/`
path), and from a directory depth consistent with the location of the build
script.

### Sample "shadow" directory structure

The ability to keep build scripts in a separate `gup/` directory is useful for
cleanliness, but also for defining targets whose destination doesn't actually
exist yet. For example, you might have:

    src/
      foo.c
      bar.c
    gup/
      build/
        Gupfile
        build-c
        build-foo
        windows/
          OPTS
          install.gup
        osx/
          OPTS
          install.gup
        linux/
          OPTS
          install.gup

Where the Gupfile contains rules like:

    build-c:
      */*.o

    build-foo:
      */foo

When building `build/windows/foo`, it would run the script
`gup/build/build-foo` from the directory `build/` and "$2" (the target path)
set to windows/foo, from which it could determine which OPTS file to use. When
`gup` finds a build script for a path that doesn't yet exist (`build/windows/`
in this case), it will create this directory just prior to running the build
script - so your script can always assume the base directory for the target
it's building will exist.

This also allows you to keep your source and built files separate - your
`clean` task can be as simple as `rm -rf build/`.

# Where do I list a target's dependencies?

You don't, at least not up-front like you do in `make`.

As part of a build script, you should tell gup to make sure any file you
depend on is up to date. This includes both generated files and source files.
For a simple build script that just concatenates all files in `src/`, you
might write:

`all.gup:`

    #!/bin/bash
    set -eu

    files="$(find src -type f)"
    gup -u $files
    cat $files > "$1"

When gup first builds `all`, it doesn't exist - so clearly it needs to be
built. As the script runs, `gup` gets told to update all the files in src, so
it remembers that `all` depends on each of these files. The next time you ask
to build `all`, it knows that it only needs rebuilding if any of the files
passed to `gup -u` changed.

You don't have to specify all your dependencies in one place, though - you can
call `gup -u` from any place in your script - all calls make while building
your target are appended to the dependency information of the target being
built. This is done by setting environment variables when invoking running
build scripts, so it's completely parallel-safe.

Also, `gup` will by default include a dependency on the build script used to
generate a target. If you change the build script (or add a new build script
with a higher precedence for a given target), that target will be rebuilt.

### Checksum tasks

In the above example, there's a bug. If I add a new file to `src/`, gup
doesn't know that `all` should be rebuilt, because it called `gup -u` on the
files that existed at the time it was last built.

The solution for this is to use a checksum task, like so:

`inputs.gup:`

    #!/bin/bash
    set -eu

    find src -type f > "$1"
    gup --always
    gup --contents "$1"

`all.gup:`

    #!/bin/bash
    set -eu

    gup -u inputs
    files="$(cat inputs)"
    gup -u $files
    cat $files > "$1"

The `inputs` task will *always* be re-run (at most once per `gup` invocation),
but after it runs, it will only be considered out of date (and cause `all` to
be rebuilt) if the contents of the file passed to `gup --contents` changed
since the last time it was built - in this case, if the number or names of
files in `src/` changes.

You can also pass contents to `gup --contents` via stdin, for pure "stamp" tasks
where the output is not actually used for anything.

### Other features

`gup` can build targets in parallel - just pass in the maximum number of
concurrent tasks after `-j` or `--jobs`. The jobserver code (courtesy of
[redo][]) is compatible with GNU make's jobserver, so `gup` should work in
parallel when invoked by a parallel `make` build, and vice versa.

# Using bash

Please don't! At least, not for anything complex.

The examples in this readme all use `bash` as an interpreter, because bash is
a lowest common denominator that most people know and understand. The author
**strongly recommends** against using bash for any build scripts that aren't
trivial. Most people have a preferred scripting language that is safer than
bash - use it! I tend to use python, but ruby and perl are other common
choices. Really, almost anything is better than bash.

# Relationship to `redo`

`gup` is based heavily on the [redo][] build system. Most of the core ideas
come from `redo`, since I used (and enjoyed) `redo` for quite some time. But
as I encountered a number of bugs that were hard to fix while staying within
the design of `redo`, I decided I could make a more reliable system by
changing some of the details.

If you're familiar with `redo`, here are the main (intentional) differences:

 - `gup` will rebuild targets if the stored metadata goes missing or is
   incorrect, rather than silently(*) assuming they never need to be built
   again.

   (*) `redo` does print a warning, but that's too easily missed in automated
   build processes, and requires manual intervention to fix the problem.

 - `gup` uses Gupfiles to specify exactly what should be built by each generic
   build script, rather than segregating targets only by their file extension
   or resorting to a `default.do` that tries to build every nonexistent file.

   This will sometimes mean more work for you, but allows gup to be completely
   confident about what is buildable, without ever having to guess based on
   the current state of your working copy.

 - `gup` allows you to keep your source tree clean, by using a "shadow" gup/
   directory - no need to scatter build and output files amongst your source
   code.

As a side effect of the above differences, gup never thinks that a target is a
source when it's actually a target, or vice versa. It *does* mean than an
existing (source) file could be overwritten by an improperly written `Gupfile`
if you accidentally tell `gup` it was a target (and your build script actually
produces a result). This is true of many build systems though, and if you keep
a clean separation between source and generated files (e.g by placing all
generated files under `build/`), it's reasonably hard to do the wrong thing by
accident.

# Got any examples?

Not yet, sorry. `gup` is still very new.

# What platforms does it work on?

I don't know, yet. It's very early days. It's currently written in python,
although that may change. It's been tested on Linux and OSX, and works
fine on both.

# How buggy is it?

It's pretty new, so chances are there are bugs. Please report any you find
to the github issues page.

Similarly, if you think anything is confusing in this documentation, please
suggest improvements. I already exactly how `gup` works, so I may be
explaining it badly.

# How stable is the design?

It's not. While the design decisions seem unlikely to change, no plan survives
contact with actual users.

So any details of how `gup` works may still change in the future. I'll do what
I can to make these changes backwards compatible (or at least easy to
migrate), but I can make no promises.

On that note - please raise any issues you find or improvements you can think
of as a github issue. If something is broken, I'd much rather know about it
now than later :)

# Development dependencies

 - [0install](http://0install.net)
 - PyChecker (optional; you can disable this by exporting `$SKIP_PYCHECKER=1`)

The `gup` build process itself uses `make`, but you can use the included `./make`
or `./make.bat` if you don't already have make installed.

To run the automated tests, you will also need some standard GNU utilities,
including `bash`, `find`, `cat`, etc. On Windows, MSYS provides these.

# Why the name `gup`?

It's short, easy to type, and it contains `up` (as in update).

I pronounce it with a hard "g", rhyming with "cup". You can think of
it as "gee-up" or "get up" or even "get thyself upwards" if you like,
but you should just say "gup" if you have cause to say it out loud.

# Licence

Gup is distributed under th LGPL - see the LICENCE file.

### Copyrights

`jwack.py` and `lock.py` are adapted from the [redo][] project, which is LGPL
and is Copyright Avery Pennarun

All other source code is Copyright Tim Cuthbertson, 2013.

[redo]: https://github.com/apenwarr/redo
