is there any way to import wisp/plan asm in reaver?

That's an interesting Q, actually.

I guess there is no reason why you couldn't do that?  Wisp is super simple.

And then you could just import the lambda compiler from reaver instead of porting it...

And Wisp is probably much less code than the compiler.

- Rearrange the sources and loadfile effects to that you can read wisp sources (if this is not already possible).
- Implement Wisp in Reaver
- load Wisp files

----

You could also imagine adding an effect for this (R.LoadAssembly), since runtimes already must implement Wisp.  However, I think this actually adds to much mandatory complexity to minimal runtime system impl.

In particular, a simple runtime that doesn't use the C stack at all for PLAN eval, then calling into wisp from PLAN is a big problem.

And not using the C stack at all is the key to a simple, portable runtime system that supports actor effects.

Such a runtime would still be able to implement Wisp because all of the C stuff for Wisp would live outside of PLAN evaluation and just manipulate the runtime system to expand macros.