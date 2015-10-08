When integrating with external build tools, it's not always possible to instruct them to build a target in gup's temporary location (`$1`). `gup` will allow you to build directly into `$2` (the target), provided:

 - `$1` is not also created, and
 - `$2` is modified

In this case, the `npm` command will populate the `node_modules` directory, but there's no way to configure this, so the target is effectively writing to `$2` directly.

### Ensure `$2` is modified:

If `$1` is not created and `$2` is not modified, `gup` will think that _nothng_ was built from this target, and it will remove the target. So when integrating with third-party tools which may not always modify the target, you should generally `touch "$2"` to ensure `gup` knows you've actually built something.

