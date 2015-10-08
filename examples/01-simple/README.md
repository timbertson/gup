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
