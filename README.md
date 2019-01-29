<img src="http://gfxmonk.net/dist/status/project/gup.png">

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

### Nix

`gup` is packaged in [nixpkgs][Nix], so you can do `nix-env -iA nixpkgs.gup`
to install it in your profile, or add `pkgs.gup` to your own package's
`buildInputs`.

### Bundled with your project

For repositories where you don't want to make everyone set
up `gup` as above, you can just commit the `gup` python script
to your project's repository:

 - From a git checkout or released tarball:

        cp python/bin/* [your-project-workspace]/tools

(If python/bin doesn't exist, you may need to `make python` first).

Then, you can run it as `./tools/gup`.

**Windows users**:

If you want Windows users (perhaps you are one) to be able to build
you project, remember to include the `gup.exe` shim. This a portable
`.exe` which just runs the python script named "gup" in whatever
directory you place it, passing along all arguments.

**Note**: When run from a relative or absolute path, `gup`
will bootstrap itself by adding the directory containing
it to `$PATH`, so that executing `gup` will do the right thing
from within a build script. So you may wish to place it in
its own directory to avoid accidentally adding other scripts
to `$PATH`.

# Bundled builders

Gup includes some generic builder scripts (in [./builders][]), which are
typically installed alongside `gup`. These are intended to be used as builders
in a `Gupfile` (prefixed with `!`). They are provided as-is, and will not
necessarily be as portable or as stable as gup itself. If you bundle `gup` into
your project, you should also include any scripts you make use of (you can
place them next to the `gup` binary, as gup will automatically add its
directory to your `$PATH` when building).

----

### Python version requirements

Gup works under both python 2 and 3, so it should work with
whatever recent python is on your $PATH.

I don't routinely test under old python versions, so if you
need to run gup in anything below 2.7 and you find
something broken, patches welcome.

### Using it via `make`

For convenience, you may wish to provide a `Makefile` that
simply delegates to `gup`. You can find an example `Makefile`
in the `resources/` directory.

# How does it build stuff?

The simplest build script is an executable which creates a single target.
This is called a "direct build script", and must be named "[target-name].gup".
If you've ever written a shell script to (re)generate a single file,
you know the basics of writing a direct build script. Here's a simple example:

Here's a simple example script which would be used to build the file named `target`:

`target.gup`:

    #!/bin/bash
    gup -u source
    cat source > "$1"
    echo "## Built by gup" >> "$1"

When you ask `gup` to update target, with:

    $ gup -u target

It will run this script, (almost) as if you had written `./target.gup target`.

Gup also supports indirect build scripts, which maps multiple targets (e.g. "any `.o` file") to
a single build script (which in this case knows how to build _any_ `.o` file).
These mappings are specified in a file named `Gupfile`.

### More examples

Please see the [examples][] directory - this contains example build scripts
covering `gup`'s main features, plus a README.md file with detailed descriptions of what's going on.

# Invoking `gup`:

`gup` has a few options, but most of the time you'll just be using:

    $ gup -u <target>

The `-u` means "update" - i.e. only build the target if it
is out of date. This is how you update a target from the command line.
Simply enough, it's _also_ how you update a dependency from _within_ a build script.

**Note**: Unlike many build tools, `gup` doesn't have the concept of a "project
directory" - you can build any target from anywhere - building `target` from
within `dir/` is exactly the same as building `dir/target`, building
`../dir/target` from `some-other-dir/`, or building `/full/path/to/dir/target`
from anywhere.

# Dependencies:

In each build script script, you declare your dependencies as you need them,
simply by telling gup to make sure they're up to date. So just as you run `gup
-u <target>` to build a target, each build script can itself run `gup -u
<input>` to make sure each file that it depends on is up to date. If the file
is buildable by gup, it will be built before the script continues. If not,
`gup` will remember that this target depends on `<input>`.

This allows you to keep "the place where you use a file" and "the place where
you declare a dependency on a file" colocated, and even to create abstractions
that handle these details for you. This makes it much easier to create correct
dependency information compared to systems like `make` which rely on discipline
and intimate knowledge of build internals to maintain correct dependencies.

You don't have to specify all your dependencies in one place - you can
call `gup -u` from any place in your script. All calls made while building
your target are appended to the dependency information of the target being
built. This is done by setting environment variables when invoking build
scripts, so it's completely parallel-safe.

Also, `gup` will by default include a dependency on the build script used to
generate a target. If you change the build script (or add a new build script
with a higher precedence for a given target), that target will be rebuilt.


## Build script execution:

`gup` invokes your build script as `scriptname output_path target`. Wherever possible,
your build script should generate its result in `output_path`. This is an absolute
path to a temporary file that, once your buildscript has completed successfully,
will replace the current `target` file. There are a few benefits to this approach:

1. By generating this file instead of writing to `target` directly, you can
   ensure that `target` is always the result of a successful build,
   and not a partially-created file from a build script that failed halfway through.

2. If your script _does not_ generate anything in `output_path`, `gup` will automatically
   delete `target` for you. This means that you won't get left with stale built files
   if your build script changes to no longer produce any output.

3. When building a directory, you can be assured that `output_path` does not yet
   exist. This means you can create it via `mkdir`, and not have to worry about
   cleaning up a previous version (`gup` will do this for you on a successful build).

If your build script cannot create `output_path`, it's OK to write to `target` instead.
Often this is necessary when shelling out to other tools where it's not easy to direct
their output to a specific file. **Note**: If you write your results to `target` directly
and there's a chance that the build won't touch `target` (because it turns out to be a
no-op), you must `touch target` in your build script. If you don't modify the `mtime`
of `target`, `gup` will think that your build script produced no output, and delete
`target` (due to point #2 above).

# `gup` in depth


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
the directory containing this Gupfile). A BUILDSCRIPT prefixed with `!`
will search for the named executable on $PATH, rather than in the current directory.

Each following indented line is a target pattern, which may include the `*`
wildcard to match anything except a "/", and `**` to match anything including
"/". A target pattern beginning with `!` inverts the match.

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

Once `gup` has found the script to build a given target, it runs it as
an executable. More concretely:

It will interpret shebang lines so that you don't actually have to
make your script executable, but you can also use an actual executable (with
no shebang line) if you need to.

Relative script paths (starting with `./`) in the shebang line are
supported, and are resolved relative to
the directory containing the script, rather than the current working
directory.

If your interpreter is just a program name (e.g. `#!python`), it will
be searched for in `$PATH`, making this a terse equivalent of `#!/usr/bin/env python`.

On windows, UNIX-y paths like `/bin/bash` may not be present, so you should either
use `#!bash` or `#!/usr/bin/env bash` (gup has special support for `/usr/bin/env`
in shebang lines, even if that path doesn't exist locally).

When a build script is run, its working directory (`$PWD`) is typically set to the directory
containing the Gupfile (for indirect targets), or the script itself (for direct `<name>.gup` targets).
The exception is that when a Gupfile or script lives inside a `gup/` directory, it is run from the
equivalent path without the `gup/` directory. This means that `$2` will always correspond to
the matched pattern in a Gupfile.

For example:

1. building `a/b/c` with a direct gupfile at `a/b/c.gup` will invoke `a/b/c.gup` from
   `a/b` with `$2` set to `c`.

2. For the following `src/Gupfile` contents:

```
default.gup:
  tmp/*
scripts/default.o.gup:
  *.o
!gup-link:
  *.a
```

  Then:

   - `gup src/tmp/foo` would run `src/default.gup` from `src/`, with `$2`
     set to `tmp/foo`.
   - `gup src/foo.o` would run `src/scripts/default.o.gup` from `src`,
     with `$2` set to `foo.o`
   - `gup src/foo.a` would run `gup-link` (found on $PATH) from `src`,
     with `$2` set to `foo.a`

  But if the same files were nested under `gup/` (e.g `gup/src/Gupfile`,
  `gup/src/default.gup`, etc, then the paths would remain the same - the
  `gup/` path containing the actual script being executed would be
  accessible only via `$0`.

Again, these rules may seem complex to read, but the actual behaviour is
fairly intuitive - rules get run from the target tree (not inside any `/gup/`
path), and from a directory depth consistent with the location of the Gupfile
(or .gup file).

### Variables

Gup exports a few environment variables which are used to propagate settings to sub-invocations of
`gup`. If you like, you can use some of these to influence your build script too.

 - `GUP_TARGET`: You should not care about the value of this, but it will always be
                 set in a gup build. By testing for the absence of this variable,
                 you can have a build script which also does something useful when
                 run directly (not through `gup`).

 - `GUP_XTRACE`: Set to either `"0"` or `"1"`. When you pass the `-x` or `--trace`
                 flags to gup, this variable will be set `"1"`. This can be used to 
                 enable extra output from your build script (e.g. `set -x` in bash,
                 or increasing the log verbosity in other languages).

- `GUP_VERBOSE`: `"0"` is the default, and `1` is added for each `-v`
                 flag passed to `gup`. May be a negative number if `-q` is used.
                 You normally shouldn't need to use this, as `-v` is typically
                 for debugging `gup` itself. But it can be useful if you need
                 more levels than `GUP_XTRACE` provides.




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

For a working example of a shadow directory, see the [examples][] directory.


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
concurrent tasks after `-j` or `--jobs`.

When `gup` is invoked from `make`, it automatically uses make's existing
jobserver instead of creating its own. This only works if `make` is at the
toplevel though - make's jobserver relies on open file descriptors being
inherited on `exec()` (which is forbidden in some languages), so
`gup` uses a more robust jobserver when it can.

# Using bash

`bash` is convenient as it's almost always installed on UNIX-like systems.
It has a _lot_ of gotchas, though. One benefit of `gup` is that it doesn't care what
interpreter you use, so I encourage you to use a better language than bash for anything non-trivial.

I tend to use python, but ruby and perl are other common choices. If your
project is a library or program for a particular language, it's often a good
choice to write your build scripts in that same language - that way anyone
contributing source code can probably understand your build code, too!

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
if you accidentally tell `gup` it was a target (_and_ your build script
succeeds). This is true of many build systems though, and if you keep
a clean separation between source and generated files (e.g by placing all
generated files under `build/`), it's reasonably hard to do the wrong thing by
accident.

# Where can I discuss stuff?

If it's a straightforward bug or feature request, it can probably go straight
on the [github issues page][issues].

For all other discussion, there's a [mailing list][gup-users].

[issues]: https://github.com/gfxmonk/gup/issues
[gup-users]: https://groups.google.com/forum/#!forum/gup-users

# What platforms does it work on?

The (fairly extensive) automated test suite passes on Linux, OSX and Windows.
The tests are automatically run on Linux (python2 & python3) whenever I push
new code, the other platforms only get tested whenever I worry that I might
have broken something. If you notice any breakage, please let me know by
opening a github issue (or just emailing me) and I'll do my best to fix it.

The ocaml version is more or less experimental - I use it in daily life, but
I have (as yet) made no attempt to test it on things that aren't linux.

# How buggy is it?

It's a relatively simple build system compared to many, and I've been
using it on various projects for a few years. I think it's pretty stable, but
there could still be bugs lurking. Please report any you find
to the github issues page.

Similarly, if you think anything is confusing in this documentation, please
suggest improvements. I already exactly how `gup` works, so I may be
explaining it badly.

# How stable is the design?

Strictly speaking, I make no guarantees. However, `gup` has been around a while
now, and I'm pretty happy with it. Being the lazy guy that I am, it seems
likely that gup won't change in a backwards-incompatible way unless there's a
very good reason for it.

However, nothing is set in stone - please raise any issues you find or
improvements you can think of as a github issue. If something is broken, I'd
much rather know about it now than later :)

# Why the name `gup`?

It's short, easy to type, and it contains `up` (as in update).

I pronounce it with a hard "g", rhyming with "cup". You can think of
it as "gee-up" or "get up" or even "get thyself upwards" if you like,
but you should just say "gup" if you have cause to say it out loud.

# Hacking on `gup`:

The python code (under `python/` and `test/`) is currently the supported version
of `gup`.

There is an experimental ocaml implementation (under `ocaml/`), which I intend to be
100% interchangeable with the python version. The purpose of the ocaml version is
twofold: It should be quite a bit faster than python, and I wanted to learn OCaml.
The ocaml version is less easily portable than the python version though, and probably
doesn't even compile on non-linux systems yet.

I don't require contributors to make changes to both codebases (i.e fixing a bug
in _just_ the python code is fine with me). It would of course be convenient
if you do update the python & ocaml code simultaneously when submitting a change,
but I know that's a lot to ask, so I will assume responsibility of
keeping the codebases in sync as necessary.

If you do add tests or fix bugs, please include tests. These are written in
python, and are run over both the python & ocaml versions. Doing this (aside
from generally being a good idea) will help avoid disparity between the
two versions.

### Building

If you have [nix][Nix], you can just run `nix-shell` and then use `make`.

Otherwise, you'll need to get dependencies manually:

For `python/`:

 - PyChecker (optional; you can disable this by exporting `$SKIP_PYCHECKER=1`)
 - `gmcs` (only if you want to run on windows; provided by the `mono-core`
   package on RPM systems and `mono-gmcs` on debian-based systems).
   If you don't need Windows support, you can ignore this. The shim
   is tiny and changes rarely, so you should also be fine to use gup.exe
   from a release tarball.

For `ocaml/`, the best bet is to look at the before_install script in `.travis.yml`
and follow those instructions.

### Building

The `gup` build process itself uses `make`, but you can use the included `./make`
or `./make.bat` if you don't already have make installed.

Most operations work from the appropriate directory - e.g running `make bin`, `make unit-test`,
`make integration-test` in either the `ocaml/` or `python/` directories will do the right thing.

To run the automated tests, you will also need some standard GNU utilities,
including `bash`, `find`, `cat`, etc. On Windows, MSYS provides these.

# Licence

Gup is distributed under th LGPL - see the LICENCE file.

### Copyrights

`jwack.py` and `lock.py` are adapted from the [redo][] project, which is LGPL
and is Copyright Avery Pennarun

`zeroinstall_utils.ml` and some of `util.py` is adapted from the [ZeroInstall][] project, which is LGPL
and is copyright Thomas Leonard.

All other source code is Copyright Tim Cuthbertson, 2013-2014.

[redo]: https://github.com/apenwarr/redo
[ZeroInstall]: http://0install.net/
[Nix]: http://nixos.org/nix/
[examples]: ./examples/
