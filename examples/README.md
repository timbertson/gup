
# `01-simple/`: A simple build script

Contents of `source`:

    This is a source file

Contents of `target.gup`:

    #!/bin/bash
    gup -u source
    cat source > "$1"
    echo "## Built by gup" >> "$1"

----

This example is a trivial build target. You can build it with:

    $ gup -u target

This builds the file named `target` in the current directory, (almost) as if
you had run: `./target.gup target`

    $ gup -u target

Does nothing.

The build script (`target.gup`) registers its dependencies _during_ its run. In
this case, the most recent run of `target.gup` invoked `gup -u source`. This
would cause `source` to be build (if it were a `gup` target itself), but also
causes `gup` to remember that `target` depends on `source`. Since `source`
has not changed, `gup` knows the file doesn't need to be rebuilt.

    $ touch source
    $ gup -u target

Rebuilds `target`, since `source` has been modified.

    $ touch target
    $ gup -u target

Also rebuilds `target`, and prints a warning that "target" has
been modified outside of `gup`. In order to ensure that all build
targets are correct and consistent, `gup` will rebuild a file that
has been modified. For this reason it's not a good idea to make
manual edits to a build target - your edits will be lost next time the
target is built.

    $ touch target.gup
    $ gup -u target

This too will rebuild `target`, since every target implicitly depends on its
own build script.

# `02-shadow/`: `gup` shadow directory

Contents of `out.gup`:

    #!bash
    echo "tada!" > "$1"

----

This example shows a simple "shadow" build layout. When you ask `gup` to build
a target, it will first search for a build script named `<target>.gup`. If that
doesn't exist, it will look for "shadow" build scripts - a parallel  directory
structure inside a folder named "gup".

This has a few benefits. For starters, it lets you separate build scripts from
build results. So here we can remove the entire `build` directory without
worrying about losing any build scripts or source code.

Also, it means `gup` can automatically create directories as needed. In this
example there's no `build` directory in source control, gut `gup` will create
it for us when we first build `build/out`.

    $ gup -u build/out

Since there's no `build/out.gup` file, `gup` will use `gup/build/out.gup` as
the build script. This shadow "gup" directory can live at each level - see [the
README][README] for a more detailed description.

# `03-Gupfile/`

Contents of `Gupfile`:

    gup-build-obj:
      build/*.o
    

Contents of `gup-compile-obj`:

    #!bash
    src="src/$(basename "$2" .o).c"
    gcc -o "$1" "src/$src"

Contents of `main.gup`:

    #!bash
    SOURCES="build/main.o"
    gup -u $SOURCES
    ld -o "$1" $SOURCES

Contents of `main.c`:

    int main() {
      println("Hello, world!");
      return 0;
    }

----

Not every target is a unique snowflake - in fact, most aren't.

So far we've seen how a `<target>.gup` file is used to build a file named `<target>`. But we often want to build a whole number of targets with the same build script. This is where the `Gupfile` comes in. You can place a `Gupfile` anywhere, and `gup` will check it for targets relative to its location (including in subdirectories).

The `Gupfile` syntax is straightforward. Each unindented line specifies a path to a build script, followed by a colon. Each subsequent indented line specifies a target, which may contain `*` and `**` wildards. `gup` will use the named buildscript to build any target that matches one of these patterns.

Note that `gup` will attempt to build any matching target. If you have _source_ files which also match a pattern in a `Gupfile`, you will need to add exclusions so that `gup` doesn't erroneously try to build them. An exclusion is any pattern prefixed with an `!`.

Here's an example of a `Gupfile` builder which will be used to build any `.o` or `.md` file, but which will _not_ be used to build `README.md` (which is presumably hand-written, and not generated):

    <build-script>:
        *.o
        *.md
        !README.md



# `04-checksum/`: Recognise unchanged inputs

Contents of `docs-metadata.tgz.gup`:

    #!bash -eu
    SOURCES="machine-id toc.md"
    gup -u $SOURCES
    tar czf "$1" $SOURCES

Contents of `docs.md`:

    # Getting started
    Lorem impsum getting started.
    
    # Installation
    Lorem impsum intallation instructions.

Contents of `machine-id.gup`:

    #!bash -eu
    gup --always
    echo "$USER@$(hostname)" | tee "$1" | gup --contents

Contents of `toc.md.gup`:

    #!bash
    gup -u docs
    grep '^#' docs | tee "$1" | gup --contents

----

Normally, `gup` will consider a file dirty if any of its dependencies have been touched (i.e. their `mtime` has changed since the target was last built). But sometimes you might rebuild a file only to find that its contents are identical.

In cases like this, your build script can tell gup "don't consider this file to have changed unless the contents are actually different". This is done by passing in some contents to `gup --contents`, either by piping the data directly to it, or by giving it the name of one or more files for it to read.

This is often called a "checksum" or "stamp" target - since it may need to be built very often, but won't cause its dependencies to be rebuilt unless it actually changes.

This example has two different stamp targets. `toc.md` uses `gup --contents` for efficiency - `toc.md` will _always_ be rebuilt when `README.md` changes, however a target depending on `toc` (e.g. `docs-metadata.tgz`) will not be rebuilt unless there are changes to the section headings in README.md, since that is all `toc.md` contains.

On the other hand, `machine-id` is actually an impure target - it can't possibly declare what it depends on, since it grabs things from the environment (and `gup` only knows how to depend on other files). In this case, the best we can do is to _always_ build it (`gup --always`), but only cause dependencies to be rebuilt if the result is different from last time.

Often the contents passed to `gup --contents` will be the same contents that you write to your target, but it doesn't have to me.

# `05-python/`: Using a real programming language

Contents of `Gupfile`:

    gup-build-object:
      build/*.o
    
    gup-build-src:
      src/.all

Contents of `gup-build-src`:

    #!python
    from __future__ import print_function
    import os, shutil, subprocess
    from . import gup
    gup.build(__file__)
    
    dest, _ = sys.argv[1:]
    
    checksum = subprocess.Popen(['gup','--contents'], stdin=subprocess.PIPE)
    with open(dest, 'w') as dest:
      for base, files, dirs in os.walk('src'):
    
        # skip hidden dirs
        for i in reversed(range(0, len(dirs))):
          if dirs[i].startsWith('.'):
            del dirs[i]
          else:
            # depend on each dir, so this target gets rebuilt
            # when a file is created/removed
            gup.build(os.path.join(base, dirs[i]))
    
        for file in files:
          # skip hidden files
          if file.startsWith('.'):
            continue
    
            # print each file to dest:
            path = os.path.join(base, file)
            print(path, dest=dest)
    
            # and include each file in checksum
            print(path, dest=checksum.stdin)
            with open(path) as src:
              shutil.copyfileobj(src, checksum.stdin)
    
    checksum.stdin.close()
    assert checksum.wait() == 0, "Checksum task failed"
    
    

Contents of `main.gup`:

    #!python
    from build_util import gup, src
    from os import path
    import sys, subprocess
    
    dest, _ = sys.subprocess[1:]
    
    sources = src.build_all()
    def src_to_obj(src):
      objname = path.splitext(src)[0] + '.o'
      return path.join('build', objname)
    
    objects = list(map(src_to_obj, sources))
    subprocess.check_call(['ld', '-o', dest] + objects)

Contents of `gup.py`:

    import subprocess
    
    def build(*targets):
      subprocess.check_call(['gup','-u'] + list(targets))
    
    build(__file__)

Contents of `src.py`:

    from . import gup
    gup.build(__file__)
    STAMP_FILE='src/.stamp'
    
    def build_all():
      # build the meta-target which depends on all src/files,
      # and return its contents (one source file per line)
      gup.build(STAMP_FILE)
      with open(STAMP_FILE) as sources:
        return sources.readlines()

----

Most of these examples use `bash` as a build script language, because it's widely available and understandable for most users.

However, it's not necessarily a good idea to use `bash`. Unless your build scripts are trivial, it can be hard to get `bash` scripts right.

To show how non-bash `gup` build scripts look, here's a simple set of build scripts written entirely in python. You can of course substitute `python` for your preferred scripting language, or the language that your program is itself written in.

# `06-directories/`: Building entire directories

Contents of `leaf-dir.gup`:

    #!bash -eu
    # this target has no dependencies - it'll only be rebuilt
    # when the .gup file changes (e.g. we change the URL)
    
    curl "http://example.com/archive.tgz" | tar xz -C "$1"

Contents of `a.txt.gup`:

    #!bash -eu
    echo "ay" > "$1"

Contents of `all.gup`:

    #!bash -eu
    gup -u a.txt b.txt

Contents of `b.txt.gup`:

    #!bash -eu
    echo "bee" > "$1"

----

Most `gup` files are targets. But sometimes you'll want to build a directory.

There are two distinct cases here:

### Leaf directories

These are directories which don't contain any buildable targets inside them, and which are created in their entirety by one build script. `leaf-dir` is an example of this - its contents are an unpacked archive. It's fine to use a `gup` script named after the directory to build these.

### Directories with sub-targets

Because `gup` builds targets cleanly and atomically, it will _completely replace_ an old build result with the new one. If you had a `parent-dir` target with sub-targets of `parent-dir/a` and `parent-dir/b`, that would actually mean that whenever you built `parent-dir` it would completely replace this dir, including removing any previously-built versions of `a` and `b`. This is generally not what you want.

If you want to have a buildable directory with sub-targets, it's best to use a psuedo-file inside the directory, typically named `all` (`.all` is another common choice). This way, `gup` doesn't try to replace the entire `dir-target` directory since it's not itself a target. In this example, we also use a shadow `gup/` directory so that we don't have to check an empty `dir-target` into source control.



# `07-writing-target-directly/`: Best used sparingly

Contents of `node_modules.gup`:

    #!bash -eu
    gup -u package.json
    npm install
    touch "$2"

Contents of `package.json`:

    {
      "name": "test",
      "dependencies": {
        "tar": "*"
      }
    }

----

When integrating with external build tools, it's not always possible to instruct them to build a target in gup's temporary location (`$1`). `gup` will allow you to build directly into `$2` (the target), provided:

 - `$1` is not also created, and
 - `$2` is modified

In this case, the `npm` command will populate the `node_modules` directory, but there's no way to configure this, so the target is effectively writing to `$2` directly.

### Ensure `$2` is modified:

If `$1` is not created and `$2` is not modified, `gup` will think that _nothng_ was built from this target, and it will remove the target. So when integrating with third-party tools which may not always modify the target, you should generally `touch "$2"` to ensure `gup` knows you've actually built something.

