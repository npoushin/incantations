# incantations
Hikey960 build/flash helper scripts

This is a rough and ready first pass of automating the instructions here:
https://github.com/96boards-hikey/tools-images-hikey960/blob/master/build-from-source/README-ATF-UEFI-build-from-source.md

It doesn't do nice stuff like getopts or argument parsing, but should provide a one-shot do-it-all build and flash firmware script to
get a functioning Debian system running on a Hikey960 v2 (even if it previously had no software on it).
