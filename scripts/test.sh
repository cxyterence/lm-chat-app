#!/bin/sh
# Command Line Tools ship Testing.framework outside the default search path.
F=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
if [ -d "$F" ] && ! xcode-select -p | grep -q Xcode; then
  exec swift test -Xswiftc -F -Xswiftc "$F" -Xlinker -F -Xlinker "$F" -Xlinker -rpath -Xlinker "$F" "$@"
fi
exec swift test "$@"
