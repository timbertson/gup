#!/bin/bash
set -eu
make unit-test-pre
exec 0install run --command=test gup-local.xml "$@"
