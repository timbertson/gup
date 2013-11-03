#!/bin/bash
make gup-local.xml
exec 0install run --command=test gup-local.xml "$@"
