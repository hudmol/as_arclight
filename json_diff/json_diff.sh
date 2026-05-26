#!/bin/bash

basedir=$(cd "`dirname "$0"`"; pwd)

"$basedir/../scripts/jruby.sh" "$basedir/json_diff.rb" ${1+"$@"}
