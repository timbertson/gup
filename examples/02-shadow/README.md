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
