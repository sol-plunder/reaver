# Reaver Scheme

This contains an implementation of Reaver, a Scheme-like language for
the PLAN ISA.  Because Reaver is implemented directly in
PLAN, any implementation of PLAN should be able to run
this code.

A simple reference implementation of PLAN and
Wisp is also included, which is sufficient for testing Reaver, but which is not going to
have the performance or scalability needed for real applications.

Reaver is implemented in Wisp, which is a simple s-expression syntax
for PLAN with the ability to name expressions and define macros.

Reaver is indented to be used as the first language that lets you "live
in" a PLAN machine.  The intention is that it be used as a builting
block to build more sophisticated toolchains.

The PLAN implementation includes a snapshotting system which works by
pretty-printing PLAN files back to wisp and saving each pin into
`snap/$hash.plan`.  The same Wisp reader is then used to resume from these
snapshots.  And this lets you explore the snapshots in a text editor,
so that you can easily see everything that's going on.

## Running

`flake.nix` should be pull in all of the dependencies that you need
for this.  If you don't use Nix, then it's just a simple Haskell
program with a few standard dependencies.  Just look at `flake.nix`
to get a list of the dependencies, and then install them yourself.
