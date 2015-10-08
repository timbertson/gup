Not every target is a unique snowflake - in fact, most aren't.

So far we've seen how a `<target>.gup` file is used to build a file named `<target>`. But we often want to build a whole number of targets with the same build script. This is where the `Gupfile` comes in. You can place a `Gupfile` anywhere, and `gup` will check it for targets relative to its location (including in subdirectories).

The `Gupfile` syntax is straightforward. Each unindented line specifies a path to a build script, followed by a colon. Each subsequent indented line specifies a target, which may contain `*` and `**` wildards. `gup` will use the named buildscript to build any target that matches one of these patterns.

Note that `gup` will attempt to build any matching target. If you have _source_ files which also match a pattern in a `Gupfile`, you will need to add exclusions so that `gup` doesn't erroneously try to build them. An exclusion is any pattern prefixed with an `!`.

Here's an example of a `Gupfile` builder which will be used to build any `.o` or `.md` file, but which will _not_ be used to build `README.md` (which is presumably hand-written, and not generated):

    <build-script>:
        *.o
        *.md
        !README.md
 

