#!/bin/bash

if [ "$ARCHIVESSPACE" = "" ]; then
    # Try to find an ArchivesSpace checkout or installation
    maybe_aspace_dir="`dirname "$0"`"/../..

    if [ -e "$maybe_aspace_dir/build/build.xml" ] && [ -e "$maybe_aspace_dir/build/gems"]; then
        # ArchivesSpace checkout
        ARCHIVESSPACE="$maybe_aspace_dir"
    elif [ -e "$maybe_aspace_dir/archivesspace.sh" ] && [ -e "$maybe_aspace_dir/gems"]; then
        ARCHIVESSPACE="$maybe_aspace_dir"
    else
        echo "Can't find your ArchivesSpace installation.  Please set the ARCHIVESSPACE environment variable and retry."
        echo
        echo "Example: export ARCHIVESSPACE=/path/to/archivesspace"
        echo
        exit 1
    fi
fi

gempath="`ls -d "$ARCHIVESSPACE/gems" "$ARCHIVESSPACE"/build/gems/jruby/*/gems/../ 2>/dev/null`"

if [ "$gempath" = "" ]; then
    echo "Couldn't locate any Rubygems at $ARCHIVESSPACE"
    echo
    echo "If using an ArchivesSpace checkout, you may need to bootstrap your installation with:"
    echo
    ( cd "$ARCHIVESSPACE"; echo -n "  cd "; pwd)
    echo "  build/run bootstrap"
    echo

    exit 1
fi

jruby_jars="`cd "$gempath"/gems/jruby-jars-*/; pwd`"

export GEM_HOME="$gempath"
export GEM_PATH="$gempath"

# Try to run without warnings no matter how new (or old!) the JVM
if java --sun-misc-unsafe-memory-access=allow --enable-native-access=ALL-UNNAMED -version 2>/dev/null; then
    extra_args=(--sun-misc-unsafe-memory-access=allow --enable-native-access=ALL-UNNAMED)
elif java --enable-native-access=ALL-UNNAMED -version 2>/dev/null; then
    extra_args=(--enable-native-access=ALL-UNNAMED)
else
    extra_args=()
fi

java "${extra_args[@]}" -cp "$jruby_jars/lib/*" org.jruby.Main --debug ${1+"$@"} 2> >(grep -v 'extensions are not built' >&2)
