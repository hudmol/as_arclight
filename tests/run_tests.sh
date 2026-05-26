#!/bin/bash

aspace_dir="$1"

if [ "$1" = "" ]; then
    echo "Usage: $0 <aspace directory>"
    exit
fi

$aspace_dir/scripts/jruby -e 'true' &>/dev/null

if [ $? != "0" ]; then
    echo
    echo "ERROR: Running JRuby test failed.  Please ensure your ArchivesSpace directory exists and is bootstrapped:"
    echo
    echo "  cd $aspace_dir && build/run bootstrap"
    echo
    echo "JRuby output:"
    echo
    $aspace_dir/scripts/jruby -e 'true'
fi

$aspace_dir/scripts/jruby arclight_test_runner.rb "$aspace_dir"
