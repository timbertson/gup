Normally, `gup` will consider a file dirty if any of its dependencies have been touched (i.e. their `mtime` has changed since the target was last built). But sometimes you might rebuild a file only to find that its contents are identical.

In cases like this, your build script can tell gup "don't consider this file to have changed unless the contents are actually different". This is done by passing in some contents to `gup --contents`, either by piping the data directly to it, or by giving it the name of one or more files for it to read.

This is often called a "checksum" or "stamp" target - since it may need to be built very often, but won't cause its dependencies to be rebuilt unless it actually changes.

This example has two different stamp targets. `toc.md` uses `gup --contents` for efficiency - `toc.md` will _always_ be rebuilt when `README.md` changes, however a target depending on `toc` (e.g. `docs-metadata.tgz`) will not be rebuilt unless there are changes to the section headings in README.md, since that is all `toc.md` contains.

On the other hand, `machine-id` is actually an impure target - it can't possibly declare what it depends on, since it grabs things from the environment (and `gup` only knows how to depend on other files). In this case, the best we can do is to _always_ build it (`gup --always`), but only cause dependencies to be rebuilt if the result is different from last time.

Often the contents passed to `gup --contents` will be the same contents that you write to your target, but it doesn't have to me.
