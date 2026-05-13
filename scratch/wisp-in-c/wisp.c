// GC RULE: Every zcall may trigger GC, invalidating all Plan values
// in C locals/args. Only values on the vstack (r15) or known direct
// numbers survive. Protect Plan values by pushing to vstack before
// any zcall, reload after.

#include <sys/stat.h>
#include <sys/mman.h>
#include <fcntl.h>
#include <stdnoreturn.h>

typedef unsigned long Plan;
typedef unsigned char u8;
typedef unsigned long u64;

extern Plan apply(Plan n);
extern Plan apple(Plan n, Plan nparams, Plan shouldRemember);
extern Plan c_eval(Plan thunk);
extern Plan c_apply1(Plan f, Plan x);
extern Plan opnat(Plan x);
extern Plan opisnat(Plan x);
extern Plan mkclosure(Plan sz); // sz must be > 0
extern Plan c_mkclz1(Plan tag, Plan val);
extern Plan c_mkclz2(Plan tag, Plan x, Plan y);
extern Plan c_mkclz3(Plan tag, Plan x, Plan y, Plan z);
extern Plan c_apply2(Plan f, Plan x, Plan y);
extern Plan reserve(int words);
extern Plan claim(int words);
extern Plan fastix(Plan i, Plan x);
extern Plan fastsz(Plan i);
extern Plan opix(Plan i, Plan x);
extern Plan opix0(Plan x);
extern Plan opix1(Plan x);
extern Plan opix3(Plan x);
extern Plan opix4(Plan x);
extern Plan ophd(Plan x);
extern Plan opnil(Plan x);
extern Plan oppin(Plan x);
extern Plan opsz(Plan x);
extern Plan compare(Plan i, Plan x);
extern Plan opeq(Plan i, Plan x);
extern u64  opbytes(Plan x);
extern Plan fastmul(Plan x, Plan y);
extern Plan fastadd(Plan x, Plan y);
extern Plan oplaw(Plan name, Plan arity, Plan body);
extern Plan fastrep(Plan hd, Plan val, Plan sz);
extern Plan fastupuniq(Plan i, Plan val, Plan row);
extern Plan fastlix(Plan i, Plan row);
extern Plan oplix(Plan i, Plan row);
extern Plan opup(Plan i, Plan val, Plan closure);
extern Plan opupuniq(Plan i, Plan val, Plan closure);
extern Plan fastup(Plan i, Plan val, Plan closure);
extern int  syscall_openat(int dirfd, const char *path, int flags);
extern int  syscall_fstat(int fd, struct stat *st);
extern void *syscall_mmap(void *addr, long len, int prot, int flags, int fd, long off);
extern int  syscall_munmap(void *addr, long len);
extern int  syscall_close(int fd);
extern int  syscall_open(const char *path, int flags);
extern int  syscall_write(int fd, const void *buf, int len);
extern void trace_value(Plan, int);

extern Plan zcall1(u64(*)(u64), u64);
extern Plan zcall2(u64(*)(u64,u64), u64, u64);
extern Plan zcall3(u64(*)(u64,u64,u64), u64, u64, u64);
extern Plan zcall4(u64(*)(u64,u64,u64,u64), u64, u64, u64, u64);

register u64 *heap_end  asm ("r13");
register u64 *heap_next asm ("r14");
register Plan *sp asm("r15");
static inline Plan pop  ()       { return *sp++; }
static inline void push (Plan x) { *--sp = x; }
static inline void drop ()       { sp++; }

Plan *env;

#define DEBUG 1
#define sym6(a,b,c,d,e,f)  \
	(a | (b<<8) | (c<<16) | ((Plan)d<<24) \
	| ((Plan)e<<32) | ((Plan)f<<40))
#define sym5(a,b,c,d,e) (a | (b<<8) | (c<<16) | ((Plan)d<<24) | ((Plan)e<<32))
#define sym4(a,b,c,d)   (a | (b<<8) | (c<<16) | ((Plan)d<<24))
#define sym3(a,b,c)     (a | (b<<8) | (c<<16))
#define sym1(a)         a

#define BRAK sym4('B', 'R', 'A', 'K')
#define CURL sym4('C', 'U', 'R', 'L')
#define JUXT sym4('J', 'U', 'X', 'T')
#define PAGE 4096

#define N_PIN   sym3('p', 'i', 'n')
#define N_LAW   sym3('l', 'a', 'w')
#define N_BIND  sym4('b', 'i', 'n', 'd')
#define N_LET   sym3('l', 'e', 't')

typedef struct { int res; Plan v; } Lookup;

static Plan wisp_to_thunk(Plan);
static Plan wisp_eval(Plan);
static Plan wisp_expand(Plan top);
static Plan parse_form(void);
static Plan parse_seq(int cls);

static const char *cur;
static int wisp_dir_fd;

static const u8 char_class[256] = {
	[0] = 0,
	[1 ... 9] = 8, ['\n'] = 1, [11 ... 31] = 8,
	[' '] = 1, ['!'] = 8, ['"'] = 2, ['#' ... '\''] = 8,
	['('] = 4, [')'] = 3, ['*' ... ','] = 8,
	['-'] = 7, ['.' ... '/'] = 8,
	['0' ... '9'] = 7, [':'] = 8, [';'] = 1, ['<' ... '@'] = 8,
	['A' ... 'Z'] = 7,
	['['] = 5, ['\\'] = 8, [']'] = 3, ['^'] = 8,
	['_'] = 7, ['`'] = 8, ['a' ... 'z'] = 7,
	['{'] = 6, ['|'] = 8, ['}'] = 3, ['~'] = 8, [127 ... 255] = 8,
};

static const Plan mode_for[]  = { 0, 0, 0, 0,  0,   BRAK,  CURL   };


// Wisp ////////////////////////////////////////////////////////////////////////

static void bug(const char *msg, Plan val) {
	int i = 0;
	while (msg[i]) i++;
	syscall_write(2, msg, i);
	syscall_write(2, "\n", 1);
	val = zcall1(c_eval, val);
	trace_value(val, 1);
}

// Print error context string to stdout, then the value, then trap.
static _Noreturn void die(const char *msg, Plan val) {
	bug(msg, val);
	__builtin_trap();
}

/*
	wisp_input is the high-level state machine step function.

	First, we check if the state is a BST (by checking if the head
	is zero).

	If the head is zero, the proces is:

		macro-expand
		convert to a thunk
		evaluate

	As a special, temporary debugging nicety, we have debug printing
	of top-level forms, but we supress printing when the top-level
	form was () (or a macro which expanded to ()).
*/
static void wisp_input(Plan x) {
	Plan show;
	push(x);
	x = zcall1(ophd, *env);
	if (x) goto hook;
	x = pop();
	x = wisp_expand(x);
	show = x;
	x = wisp_to_thunk(x);
	x = zcall1(c_eval, x);
	if (!show) goto ret;
	#if DEBUG
	trace_value(x, 1);
	#endif
ret:	return;
hook:	x = pop();
	x = zcall2(c_apply1, *env, x);
	*env = x;
	return;
}


// Parser //////////////////////////////////////////////////////////////////////

static inline int classify(char c) {
	return char_class[(u8)c];
}

/*
	make_nat constructs a PLAN nat from a buffer and a size, using
	reserve and claim.

	TODO: use rep movsb in assembly instead of the loop.
*/
static Plan make_nat(const char *buf, int len) {
	Plan x = 0;
	int words;
	if (len == 0) goto ret;
	words = len;
	words += 7;
	words /= 8;
	char *p = (char *)zcall1((void*)reserve, words);
	int i = 0;
loop:	if (i >= len) goto done;
	p[i] = buf[i];
	i++;
	goto loop;
done:	x = zcall1((void*)claim, words);
ret:	return x;
}

/*
	skip_ws consumes input from the `cur` buffer until something
	besides a space, newline, or comment regex|;[^\n\0]*| is found
	and then leaves `cur` pointing at that character.
*/

static void skip_ws(void) {
	char c;
gap:	c = *cur;
	if (c == ' ') goto loop;
	if (c == '\n') goto loop;
	if (c != ';') goto ret;
note:	cur++;
	c = *cur;
	if (c == '\n') goto loop;
	if (c != 0) goto note;
ret:	return;
loop:	cur++;
	goto gap;
}

/*
	parse_string scans forward until it finds a 0 byte (which could
	indicate an EOF, or could be in the file).

	If it finds a null, it crashes, otherwise, it constructs a string
	with the content between the initial cur location, up to the
	closing ".

	At the end, cur will be pointing to the character after the ".
*/

static Plan parse_string(void) {
	Plan x;
	char c;
	const char *start = cur;
check:	c = *cur;
	if (c == 0)   goto fail;
	if (c == '"') goto done;
	cur++;
	goto check;
done:	x = make_nat(start, cur - start);
	cur++;
	x = zcall2(c_mkclz1, 1, x);
	return x;
fail:	die("unterminated string", 0);
}

/*
	parse_decimal transforms a character sequence that is already
	known to be a decimal literal, into a natural number.

	The input string must be non-empty.

	This is GC-safe without using the stack, because no reference
	is ever preserved between calls.
*/

static Plan parse_decimal(const char *buf, int len) {
	Plan x = 0;
	int i = 0, n;
loop:	x = zcall2(fastmul, x, 10);
	n = buf[i];
	n -= '0';
	x = zcall2(fastadd, x, n);
	i++;
	if (i < len) goto loop;
	return x;
}

/*
	parse_symbol scans a contiguous run of symbol characters
	(class >= 7), determines whether the result is a decimal
	literal or a symbol, then checks if there is a juxtaposed string
	or nest right after.

	Three phases:

	Scan:     consume symbol chars, record start and length.
	Classify: if all bytes are digits, produce (1 decimal),
	          otherwise produce the symbol nat.
	Juxt:     if the next byte is an opener (class 4-6) or
	          a double quote (class 2), parse the following
	          form and wrap in (0 JUXT val in).

	Note that the fudging of `cls` is used to implement the
	(cls >= 4 && cls <= 6) test.  By subtracting four (which wraps
	around), we can then use an unsigned comparison to check if the
	result is (cls <= 2), which is only true if it is in the correct
	range.  After this, we restore the original value by adding 4.
*/
static Plan parse_symbol(void) {
	int i, sz, cls;
	const char *start = cur;
	char c;
	Plan in, x;
scan:	c = *cur;                            // Find first non-symbol char
	i = classify(c);
	if (i < 7) goto scand;               // non-symchar (break)
	cur++;                               // symchar (continue)
	goto scan;
scand:	sz = cur - start;                    // Calculate size
	i = 0;
deci:	if (i >= sz) goto nat;               // all decimal
	c = start[i];
	if (c < '0') goto sym;               // non-decimal
	if (c > '9') goto sym;               // non-decimal
	i++;                                 // next char
	goto deci;                           // repeat
sym:	x = make_nat(start, sz);             // load symbol value
	goto juxt;                           // check juxt
nat:	x = parse_decimal(start, sz);        // get decimal value
	x = zcall2(c_mkclz1, 1, x);          // quote it
juxt:	cls = classify(*cur);                // check for juxtaposition
	if (cls == 2) goto jx;               // if quote
	cls -= 4;
	if ((unsigned)cls <= 2) goto jxs;    // found seq
	goto ret;                            // no juxt
jxs:	cls += 4;                            // restore cls
jx:	cur++;                               // found juxt, skip over starter
	push(x);                             // save head
	if (cls == 2) goto jxstr;            // x"foo" case
	in = parse_seq(cls);                 // x(f o o) case
	goto jxdone;
jxstr:	in = parse_string();                 // parse string
jxdone:	x = pop();                           // restore head
	x = zcall4(c_mkclz3,0,JUXT,x,in);    // construct (0 JUXT hd inner)
ret:	return x;                            // return
}


/*
	rev_n reverse the order of the top n elements of the value stack
	in place.
*/

static void rev_n(int n) {
	int n2 = n/2;
	int i  = 0;
again:	if (i >= n2) goto end;
	Plan x = sp[i];
	sp[i] = sp[n-1-i];
	sp[n-1-i] = x;
	i++;
	goto again;
end:	return;
}

/*
	parse_seq loads the elements of a nested form and constructs
	a closure, given the character class of the nest-opener.  We do not
	validate that the terminal character matches the opening character.

		(x..)   => (0 x..)
		[x..]   => (0 BRAK x..)
		{x..}   => (0 CURL x..)
		(1 2 3] => (0 1 2 3)

	We begin by optionally pushing a head atom if the nesting mode
	is curly or bracketed, and then we read a series of forms ending
	in any terminator character, pushing each to the stack.

	If there are no forms, we return 0.

	Otherwise, we reverse the order of the elements on the stack,
	push the 0 tag, and then construct a closure with `mkclosure`.
*/

static Plan parse_seq(int cls) {
	int n = 0, c;
	Plan x = mode_for[cls];
	if (!x) goto eat;
	push(x);
	n++;
eat:	skip_ws();
	c = classify(*cur);
	if (c != 3) goto eat1;
	cur++;
	goto done;
eat1:	*--sp = parse_form();
	n++;
	goto eat;
done:	x = 0;
	if (n==0) goto ret;
	rev_n(n);
	push(x);
	x = zcall1(mkclosure, n);
ret:	return x;
}

/*
	parse_form parses a single form.  A form can be either a symbol,
	a string, or a nested sequence.  We switch on the character class
	of the first character to determine which logic to use:

	7, 8    -> symbol
	2       -> string
	4, 5, 6 -> sequence
	0, 1, 3 -> error

	Callers are responsible for skipping whitespace before calling.
*/

static Plan parse_form(void) {
	char c;
	int cls;
	c   = *cur;
	cls = classify(c);
	if (cls >= 7) goto sym;
	if (cls == 2) goto str;
	if (cls < 4) goto error;
	goto seq;
seq:	cur++;
	return parse_seq(cls);
sym:	return parse_symbol();
str:	cur++;
	return parse_string();
error:	die("parse error", 0);
}

// SAFE: only char*/int values. No Plan.
static const char *map_file(const char *name, int namelen, long *alloc_out) {
	char path[128];
	int i, j;
	for (i = 0; i < namelen; i++) path[i] = name[i];
	for (j = 0; j < 5; j++, i++) path[i] = ".wisp"[j];
	path[i] = 0;
	int fd = syscall_openat(wisp_dir_fd, path, O_RDONLY);
	if (fd < 0) __builtin_trap();
	struct stat st;
	syscall_fstat(fd, &st);
	long size = st.st_size;
	long alloc = ((size + PAGE) / PAGE) * PAGE;
	char *base = syscall_mmap(0, alloc, PROT_READ, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	if (base == MAP_FAILED) __builtin_trap();
	if (size > 0)
		syscall_mmap(base, size, PROT_READ, MAP_PRIVATE | 0x10, fd, 0);
	syscall_close(fd);
	*alloc_out = alloc;
	return base;
}

/*
	process_file maps a .wisp source file, parses and evaluates
	each top-level form, then unmaps the file.

	Before each form, we check for the @modname include directive:
	@ followed by one or more modchars (class 7), terminated by
	whitespace, semicolon, or NUL.  If matched, we recursively
	process the named module.  If the scan fails (e.g. @foo/bar),
	we fall through to normal parsing.

	name:    pointer to the module name (not NUL-terminated).
	namelen: length of the module name.
*/

static void process_file(const char *name, int namelen) {
	long alloc;
	const char *data = map_file(name, namelen, &alloc);
	const char *save_cur = cur;
	const char *p;
	char c;
	cur = data;
top:	skip_ws();
	c = *cur;
	if (c == 0) goto done;
	if (c != '@') goto form;
	int i = classify(cur[1]);
	if (i != 7) goto form;
	p = cur + 1;
iscan:	c = *p;
	if (classify(c) != 7) goto icheck;
	p++;
	goto iscan;
icheck:	if (c == ' ')  goto incl;
	if (c == '\n') goto incl;
	if (c == ';')  goto incl;
	if (c == 0)    goto incl;
	goto form;                            // not a valid include
incl:	const char *mod = cur + 1;
	int modlen = p - mod;
	cur = p;
	const char *my_cur = cur;
	process_file(mod, modlen);
	cur = my_cur;
	goto top;
form:	Plan x = parse_form();
	wisp_input(x);
	goto top;
done:	syscall_munmap((void*)data, alloc);
	cur = save_cur;
}


// Environment /////////////////////////////////////////////////////////////////

/*
	getenv takes a key (which must be a number), grabs the global
	environment value, and then traverses down the tree until a
	matching node is found or a leaf (leaf == 0).

	Because the environment can technically contain thunks (macros
	can put anything there), getenv needs to be careful to keep it's
	live values on the stack.

		stack: env key ...
*/

static Lookup getenv(Plan key) {
	Plan tmp, m, code=0, v=0;
	push(key);
	push(*env);
loop:	tmp = zcall1(opnil, sp[0]);                // node==0 -> leaf
	if (tmp) goto ret;                         // if leaf, return 0, 0
	tmp = zcall2(opix, 0, sp[0]);
	tmp = zcall2(compare, sp[1], tmp);         // compare(key, node.key)
	if (tmp == 0) goto lt;                     // 0 means LT
	if (tmp == 2) goto gt;                     // 2 means GT, 1 means EQ
	m = zcall2(opix, 2, sp[0]);                // ismacro
	v = zcall2(opix, 1, sp[0]);                // isvalue
	code = m?2:1;
	goto ret;
lt:	sp[0] = zcall2(opix, 3, sp[0]);
	goto loop;
gt:	sp[0] = zcall2(opix, 4, sp[0]);
	goto loop;
ret:	sp += 2;
	return (Lookup){ code, v }; // rax, rdx
}

/*
	putrecur inserts or updates a binding in the environment BST.

	Environment nodes are (0 key val isMacro left right), indices
	0-4.  We compare the key, then either update in place (EQ) or
	recurse into a subtree (LT/GT) and update the child pointer.

	To keep things visible to GC, we store things in this stack frame:

		key val isMac 0 0 node ..
*/
Plan putrecur(Plan key, Plan val, Plan isMac, Plan node) {
	Plan tmp;
	push(node);
	push(0);
	push(0);
	push(isMac);
	push(val);
	push(key);
	tmp = zcall1(opnil, sp[5]);
	if (!tmp) goto node;
	push(0);
	tmp = zcall1(mkclosure, 5);
	drop();
	return tmp;
node:
	#if DEBUG
	tmp = zcall1(opsz, sp[5]);
	if (tmp != 5) die("bad env size", sp[5]);
	tmp = zcall1(ophd, sp[5]);
	if (tmp != 0) die("bad env tag", sp[5]);
	#endif
	tmp = zcall1(opix0, sp[5]);
	tmp = zcall2(compare, sp[0], tmp);
	if (tmp == 0) goto lt;
	if (tmp == 1) goto eq;
	goto gt;
lt:	tmp = zcall1(opix3, sp[5]);
	tmp = putrecur(sp[0], sp[1], sp[2], tmp);
	tmp = zcall3(opup, 3, tmp, sp[5]);
	sp += 6;
	return tmp;
eq:	tmp = sp[5];
	tmp = zcall3(opup, 1, sp[1], tmp);
	tmp = zcall3(opupuniq, 2, sp[2], tmp);
	sp += 6;
	return tmp;
gt:	tmp = sp[5];
	tmp = zcall1(opix4, tmp);
	tmp = putrecur(sp[0], sp[1], sp[2], tmp);
	tmp = zcall3(opupuniq, 4, tmp, sp[5]);
	sp += 6;
	return tmp;
}


// Macro Expansion /////////////////////////////////////////////////////////////

/*
	lookup_locals does a linear search for a key in a local
	environment, represented as a PLAN array of natural numbers.

	We perform the comparison using `Eq`, which casts the given key
	to zero if it is not a nat.

	We return either the first matching index or -1.

	TODO: enforce the invariant that the locals_slot and all of it's
	fields must always be normalized and all fields must be numbers.
	Then, we can use oplix and fasteq and avoid needing to write to
	the stack.
*/
static int lookup_local(Plan sym, Plan *locals_slot) {
	int i=0, n;
	Plan x;
	push(sym);
	n = (int)zcall1(opsz, *locals_slot);
loop:	if (i >= n) goto fail;
	x = zcall2(opix, i, *locals_slot);
	x = zcall2(opeq, *sp, x);
	if (x) goto ret;
	i++;
	goto loop;
fail:	i = -1;
ret:	drop();
	return i;
}

typedef struct { Plan x, y; } Pair;

/*
	getmacro lookup up a binding in a context where it could be
	a macro: (macro ..)

	If a local is bound to a macro name, we treat that as shaddowing
	and say that there is no macro.

	Otherwise, we lookup the key in the environment, and check
	the macro flag.  If it is bound as a macro, it's a user macro.
	If it's bound as a value, this isn't a macro.

	If it is not in either environment, then we check if it is one
	of the primitive macros, and return the name of that.

	Otherwise, it's not a macro.

	The return value is a pair of a flag and an associated value:

		(0, 0)      = not a macro
		(1, macro)  = user macro
		("bind", 0) = bind primitive
		("law", 0)  = law primitive
		("pin", 0)  = pin primitive
*/

static Pair getmacro(Plan sym, Plan *locals_slot) {
	Plan rax = 0;
	Plan rdx = 0;
	int loc = lookup_local(sym, locals_slot);
	if (loc >= 0) goto none;
	Lookup lu = getenv(sym);
	if (lu.res == 2)   goto macro;
	if (lu.res == 1)   goto none;
	if (sym == N_PIN)  goto sym;
	if (sym == N_LAW)  goto sym;
	if (sym == N_BIND) goto sym;
none:	goto ret;
sym:	rax = sym;
	goto ret;
macro:	rax = 1;
	rdx = lu.v;
	goto ret;
ret:	return (Pair){ rax, rdx };
}

static Plan macroexpand(Plan *locals_slot, Plan x);

/*
	compileExpr translates a macroexpanded form into law-body IR.

	Dispatch:
	  0 (nil)     → constant zero:  (0 0)
	  nat         → local ref or env lookup
	  (1 x)       → quoted constant: (0 x)
	  (0 f a ...) → compile each, foldl into nested applications

	locals: pointer to the locals array slot.
	v:      the expression to compile (pushed to vstack for GC).

	Returns the compiled IR.
*/

static Plan compileExpr(Plan *locals, Plan v) {
	Plan x;
	int i, sz;
	Lookup lu;
	push(v);
	x = zcall1(opnil, sp[0]);
	if (x) goto nil;
	x = zcall1(opisnat, sp[0]);
	if (x) goto nat;
	x = zcall1(ophd, sp[0]);
	if (x == 1) goto quote;
	if (x != 0) goto bad;
	goto app;
nil:	drop();
	x = zcall2(c_mkclz1, 0, 0);
	goto ret;
nat:	x = pop();
	i = lookup_local(x, locals);
	if (i >= 0) goto local;
	lu = getenv(x);
	if (lu.res == 1) goto envval;
	die("unbound", x);
envval:	x = zcall2(c_mkclz1, 0, lu.v);
	goto ret;
local:	x = i;
	goto ret;
quote:	x = zcall2(oplix, 0, sp[0]);
	drop();
	x = zcall2(c_mkclz1, 0, x);
	goto ret;
app:	sz = (int)zcall1(opsz, sp[0]);
	if (sz == 0) __builtin_trap();
	i = sz - 1;
xloop:	if (i < 0) goto xdone;
	x = zcall2(opix, i, sp[sz - i - 1]);
	push(x);
	i--;
	goto xloop;
xdone:	i = sz - 1;
shift:	if (i < 0) goto sdone;
	sp[i + 1] = sp[i];
	i--;
	goto shift;
sdone:	drop();
	i = 0;
comp:	if (i >= sz) goto fold;
	sp[i] = compileExpr(locals, sp[i]);
	i++;
	goto comp;
fold:	i = 1;
floop:	if (i >= sz) goto fdone;
	sp[0] = zcall3(c_mkclz2, 0, sp[0], sp[i]);
	i++;
	goto floop;
fdone:	x = sp[0];
	sp += sz;
ret:	return x;
bad:	die("bad law", sp[0]);
}

/*
	law_build_locals fills in the locals array for a law body.

	The locals array is a flat PLAN row 0[self, arg0, arg1, ...,
	bind0, bind1, ...] where the index in the array IS the de
	Bruijn index used by the compiler.

	locals:   pointer to the locals array slot (in the frame).
	form:     pointer to the original form slot (on the vstack,
	          above the frame).  Re-read each iteration for GC safety.
	nArgs:    number of arguments in the signature.
	nBinds:   number of bind forms.

	Indexes into sig (form[1]) for self-sym and arg syms.
	Indexes into form[2..] for bind names.
	Does NOT modify the stack layout.
*/
static void law_build_locals(Plan *locals, Plan *form, int nArgs, int nBinds) {
	Plan tmp;
	int i;

	// Self sym at index 0.
	tmp = zcall2(opix, 1, *form);
	tmp = zcall2(opix, 0, tmp);
	if (zcall1(opisnat, tmp)) goto self;
	tmp = 0;
self:
	*locals = zcall3(fastupuniq, 0, tmp, *locals);

	// Arg syms at indices 1..nArgs.
	i = 0;
args:
	if (i >= nArgs) goto abinds;
	tmp = zcall2(opix, 1, *form);
	tmp = zcall2(opix, i + 1, tmp);
	if (!zcall1(opisnat, tmp)) die("bad law argument", tmp);
	*locals = zcall3(fastupuniq, 1 + i, tmp, *locals);
	i++;
	goto args;

	// Bind names at indices (1+nArgs)..
abinds:
	i = 0;
bloop:
	if (i >= nBinds) goto ret;
	tmp = zcall2(opix, 2 + i, *form);
	push(tmp);
	tmp = (int)zcall1(opsz, sp[0]);
	if (tmp != 3) die("bad law bind", sp[0]);
	tmp = zcall2(opix, 0, sp[0]);
	if (tmp != N_LET) die("bad law bind", sp[0]);
	tmp = zcall2(opix, 1, sp[0]);
	drop();
	if (!zcall1(opisnat, tmp)) die("bad law bind name", tmp);
	*locals = zcall3(fastupuniq, 1 + nArgs + i, tmp, *locals);
	i++;
	goto bloop;
ret:
	return;
}

#if DEBUG
/*
	law_check_dups validates that no two non-zero locals have the
	same name.  This is a diagnostic aid, not a correctness
	requirement — the evaluator hook can provide better checking.

	For each local, we look it up in the locals array.  If the
	returned index doesn't match the current one, there's a
	duplicate earlier in the array.  Zero entries (anonymous
	self-reference) are skipped.

	locals: pointer to the locals array slot (in the frame).
	Stack:  temporaries may be pushed/popped above the frame.
*/
static void law_check_dups(Plan *locals) {
	int n = (int)zcall1((void*)opsz, *locals);
	for (int i = 0; i < n; i++) {
		*--sp = zcall2(opix, i, *locals);
		if (!sp[0]) { sp++; continue; }
		int found = lookup_local(sp[0], locals);
		if (found != i) bug("duplicate local", sp[0]);
		sp++;
	}
}
#endif

/*
	law_compile macroexpands and compiles each expression form,
	then folds the bind IRs around the body IR into the final
	law body.

	locals: pointer to the locals array slot (in the frame).
	forms:  pointer to the first form slot (in the frame).
	end:    pointer past the last form slot.

	Two left-to-right passes: macroexpand, then compile.
	Then a right-to-left fold wrapping (1 bind_ir body_ir).

	Returns the folded law body IR.
	Frame: form slots are modified in place.
*/

static Plan law_compile(Plan *locals, Plan *forms, Plan *end) {
	Plan *p = forms, *body = end - 1;
xpand:	if (p >= end) goto comp;
	*p = macroexpand(locals, *p);
	p++;
	goto xpand;
comp:	p = forms;
cloop:	if (p >= end) goto fold;
	*p = compileExpr(locals, *p);
	p++;
	goto cloop;
fold:	p = body - 1;
floop:	if (p < forms) goto ret;
	*body = zcall3(c_mkclz2, 1, *p, *body);
	p--;
	goto floop;
ret:	return *body;
}

/*
	expand1_law compiles a law form into a PLAN law value.

	Entry: the full law form (law sig bind.. body) is at sp[0].
	Exit:  sp[0] = (1 compiled-law).

	We allocate a fixed-shape frame on the vstack:

	    F[0]                      locals array
	    F[1]                      tag
	    F[2 .. 2+nForms-1]        bind exprs and body
	    F[frameSize]              original form (temporary)

	The original form sits just above the frame, naturally
	rooted on the vstack.  We index into it to fill the locals
	array and extract bind exprs + body into the frame.  Once
	extraction is done, the form is dropped and the frame
	becomes the entire working set.

	Subroutines receive direct pointers into the frame and
	may use sp freely for temporaries above it.
*/
static void expand1_law() {
	Plan tmp;
	int i;

	int sz = (int)zcall1(opsz, sp[0]);
	if (sz < 3) die("bad law", sp[0]);
	int nBinds = sz - 3;
	int nForms = nBinds + 1;
	int frameSize = 2 + nForms;

	tmp = zcall2(opix, 1, sp[0]);
	int sigSz = (int)zcall1(opsz, tmp);
	int nArgs = sigSz - 1;
	if (nArgs < 1) die("bad law", sp[0]);

	sp -= frameSize;
	Plan *F = sp;
	for (i = 0; i < frameSize; i++) F[i] = 0;
	Plan *form   = &F[frameSize];
	Plan *locals = &F[0];
	Plan *forms  = &F[2];
	Plan *end    = forms + nForms;

	tmp = zcall1(opix1, *form);          // sig = form[1]
	tmp = zcall1(opix0, tmp);            // tag = sig[0]
	push(tmp);
	tmp = zcall1(opisnat, tmp);
	if (tmp) goto bare;
	tmp = zcall1(opix0, sp[0]);          // tag[0]
	*sp = zcall1(opnat, tmp);            // nat(tag[0])
bare:	F[1] = pop();                        // tag

	int nLocs = 1 + nArgs + nBinds;
	F[0] = zcall3(fastrep, 0, 0, nLocs);

	law_build_locals(locals, form, nArgs, nBinds);

	if (DEBUG) law_check_dups(locals);

	i = 0;
xbinds:	if (i >= nBinds) goto xbody;
	forms[i] = zcall2(opix, 2, zcall2(opix, 2 + i, *form));
	i++;
	goto xbinds;
xbody:	forms[nBinds] = zcall2(opix, sz - 1, *form);

	Plan lawBody = law_compile(locals, forms, end);

	Plan tag = F[1];
	sp += frameSize;
	tmp = zcall3(oplaw, tag, (Plan)nArgs, lawBody);
	tmp = zcall2(c_mkclz1, 1, tmp);
	*sp = tmp;
}

/*
	expand1_pin implements the (pin x) primitive macro.  It process
	the first argument as a wisp expression, wraps it in a pin,
	and then expands to that pin, quoted as a constant value.
*/

static void expand1_pin(void) {
	Plan x;
	#if DEBUG
	int sz = (int)zcall1((void*)opsz, *sp);
	if (sz != 2) die("bad pin call", *sp);
	#endif
	x = *sp;
	x = zcall2(opix, 1, x);
	x = wisp_eval(x);
	x = zcall1(oppin, x);
	x = zcall2(c_mkclz1, 1, x);
	*sp = x;
}

static void expand1_bind(void) {
	int sz = (int)zcall1((void*)opsz, *sp);
	if (sz != 4) die("bad bind usage", sp[0]);
	push(0);                             // grow stack
	push(0);
	sp[0] = zcall2(opix, 1, sp[2]);      // nm
	sp[1] = zcall2(opix, 2, sp[2]);      // isMacro
	sp[2] = zcall2(opix, 3, sp[2]);      // exp
	sp[0] = zcall1(opnat, sp[0]);        // nm
	sp[1] = wisp_eval(sp[1]);            // isMacro
	sp[2] = wisp_eval(sp[2]);            // val
	*env = putrecur(sp[0], sp[2], sp[1], *env);
	sp += 2;                             // shrink stack
	sp[0] = 0;
	return;
}

static void expand1_user(Plan mac) {
	push(zcall3(c_apply2, mac, *env, sp[0])); // [(mac env expr) ..]
	int rsz = (int)zcall1((void*)opsz, sp[0]);
	int hd  = (int)zcall1((void*)ophd, sp[0]);

	if (hd != 0 || rsz != 2)
		die("bad user macro call", sp[0]);

	*env     = zcall2(opix, 0, sp[0]);
	Plan out = zcall2(opix, 1, sp[0]);
	drop();
	sp[0] = out;
}

/*
	macroexpand recursively expands macros in a form.

	The form is pushed to the vstack.  We loop, checking
	if the head of the form is a known macro.  If so, we
	dispatch to the appropriate expander and loop again
	(each expander replaces sp[0] in place).

	If the head is not a macro, we extract all sub-forms
	onto the stack, recursively expand each, then
	reassemble into a new closure via mkclosure.

	Non-closure forms (nil, nat, tag != 0) pass through
	unchanged.

	locals_slot: pointer to the locals array (may be empty).
	initial:     the form to expand.

	Returns the expanded form.
*/
static Plan macroexpand(Plan *locals_slot, Plan initial) {
	Plan x;
	int i, sz;
	push(initial);
again:	x = zcall1(opnil, sp[0]);            // Top of expansion loop
	if (x) goto end;
	x = zcall1(opisnat, sp[0]);
	if (x) goto end;
	x = zcall1(ophd, sp[0]);
	if (x) goto end;
	sz = (int)zcall1(opsz, sp[0]);
	if (sz == 0) goto end;
	x = zcall2(opix, 0, sp[0]);         // Check head for macro
	push(x);                            // protect across opisnat
	x = zcall1(opisnat, x);
	if (!x) goto notmac;
	x = pop();                          // recover head (nat)
	Pair mac = getmacro(x, locals_slot);
	if (mac.x == 0)      goto deep;
	if (mac.x == 1)    { expand1_user(mac.y); goto again; }
	if (mac.x == N_PIN)  { expand1_pin(); goto again; }
	if (mac.x == N_LAW)  { expand1_law(); goto again; }
	if (mac.x == N_BIND) { expand1_bind(); goto again; }
	die("impossible", 0);
notmac:	drop();                               // discard head
	// === Expand sub-forms ===
	// Extract elements onto the stack above the form.
	// The form stays at sp[sz] as elements are pushed.
deep:	i = sz - 1;
xloop:	if (i < 0) goto xdone;
	x = zcall2(opix, i, sp[sz - i - 1]);
	*--sp = x;
	i--;
	goto xloop;
xdone:	i = 0;                               // stack: [elem0, .., elemN, form]
	                                     // Expand each in place.
expd:	if (i >= sz) goto build;
	sp[i] = macroexpand(locals_slot, sp[i]);
	i++;
	goto expd;
	// Reassemble: push tag, mkclosure consumes tag + elems,
	// then overwrite the form slot with the result.
build:	push(0);
	x = zcall1(mkclosure, sz);          // consumes sz+1 slots
	sp[0] = x;                          // overwrite form slot
end:	return pop();
}

static Plan wisp_expand(Plan x) {
	push(0); // empty locals
	x = macroexpand(sp, x);
	drop();
	return x;
}

static Plan wisp_eval(Plan x) {
	x = wisp_expand(x);
	x = wisp_to_thunk(x);
	return zcall1(c_eval, x);
}

/*
	wisp_to_thunk converts a compiled IR expression into a PLAN
	thunk ready for evaluation by c_eval.

	Dispatch:
	  0 (nil)     → literal zero
	  nat         → env lookup (must be bound)
	  (1 x)       → quoted constant, return x
	  (0 f a ...) → recursively convert each element, then
	                apply f to the arguments via apple

	top_expr: the IR expression (pushed to vstack for GC).

	Returns a PLAN value or thunk.
*/

static Plan wisp_to_thunk(Plan top_expr) {
	Plan x;
	int i, sz;
	push(top_expr);
	x = zcall1(opnil, sp[0]);
	if (x) goto nil;
	x = zcall1(opisnat, sp[0]);
	if (x) goto nat;
	x = zcall1(ophd, sp[0]);
	if (x == 1) goto quote;
	if (x != 0) die("bad expression", sp[0]);
	goto app;
nil:	drop();
	return 0;
nat:	x = pop();
	Lookup lu = getenv(x);
	if (lu.res == 0) goto miss;
	return lu.v;
miss:	die("unbound", x);
quote:	x = sp[0];
	x = zcall2(oplix, 0, x);
	drop();
	return x;
app:	x = *sp;
	sz = (int)zcall1(opsz, x);
	i = sz - 1;
xloop:	if (i < 0) goto xdone;
	x = sp[sz - i - 1];
	x = zcall2(opix, i, x);
	push(x);
	i--;
	goto xloop;
xdone:	i = sz - 1;
shift:	if (i < 0) goto sdone;
	x = sp[i];
	sp[i + 1] = x;
	i--;
	goto shift;
sdone:	drop();
	i = 0;
conv:	if (i >= sz) goto apply;
	x = sp[i];
	x = wisp_to_thunk(x);
	sp[i] = x;
	i++;
	goto conv;
apply:	if (sz != 1) goto multi;
	x = sp[0];
	sp += sz;
	return x;
multi:	x = pop();
	return zcall3(apple, x, sz - 1, 1);
}


// Entry ///////////////////////////////////////////////////////////////////////

void run_wisp(const char *module) {
	*--sp = 0;
	env = sp;
	wisp_dir_fd = syscall_open("wisp", O_RDONLY | O_DIRECTORY);
	if (wisp_dir_fd < 0) __builtin_trap();
	int len = 0;
	while (module[len]) len++;
	process_file(module, len);
	syscall_close(wisp_dir_fd);
	sp++;
}
