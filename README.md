# Reaver Scheme

This contains an implementation of Reaver, a Scheme-like language for
the PLAN ISA.  Because Reaver is implemented directly in PLAN Assembly,
any implementation of PLAN should be able to run this code.

Probably the best way to jump into Reaver dev is to look at the
stdlib, and just start extending that.  I also write up a quick manual
[here](doc/reaver.md).

This will eventually be integrated with the production runtime
(https://github.com/xocore-tech/PLAN), but isn't yet.

A simple reference implementation of PLAN and a PLAN Assembler is also
included, which is sufficient for testing Reaver, but which is not going
to have the performance or scalability needed for real applications.

Reaver is indented to be used as the first language that lets you "live
in" a PLAN machine.  The intention is that it be used as a builting
block to build more sophisticated toolchains.

This PLAN implementation includes a simple snapshotting system which
works by pretty-printing PLAN files back to PLAN Assembly and saving
each pin into `snap/$hash.plan`.  Any PLAN assembler can then be used
to resume from these snapshots.  This lets you explore snapshots from
a text editor, so that you can easily see everything that's going on.

## Running

Just run `x/reaver` to build everything and get a Reaver REPL.  The Nix
flake should pull in everything for you, otherwise you will need
`cabal-install` which should also handle everything for you.

Use `rlwrap x/reaver` to get line-editing for now, eventually we will
implement actual line-editing in the system.

In Reaver, you can use `:*module` to reload a module and import all of
it's bindings.  It use the last-written timestamp to determine if the
file needs to be reloaded, so this is pretty fast.
