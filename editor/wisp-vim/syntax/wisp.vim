" Vim syntax file
" Language: Wisp (surface syntax for PLAN)

if exists("b:current_syntax")
  finish
endif

let b:current_syntax = "wisp"

" Wisp is case-sensitive
syn case match

" ---------- Comments ----------
syn match wispComment ";.*$" contains=wispTodo
syn keyword wispTodo contained TODO FIXME XXX NOTE HACK BUG

" ---------- Strings ----------
syn region wispString start='"' end='"' skip='\\"'

" ---------- Numbers ----------
" Decimal literals (sequences of digits not adjacent to symbol chars)
syn match wispNumber "\<\d\+\>"

" ---------- Special forms (builtins) ----------
syn keyword wispSpecial LAW EVAL PIN
syn match   wispSpecial "\<JUXT\>"
syn match   wispDefine  "^(\s*\zs="
syn match   wispDefine  "^(\s*\zs:="
syn match   wispDefine  "\%((\s*\)\@<==" 
syn match   wispDefine  "\%((\s*\)\@<=:="

" ---------- Law syntax ----------
" The @ in bind forms
syn match wispBind "@" contained
" Highlight bind forms: (@ name expr)
syn match wispBind "(\s*@\>" 

" ---------- File inclusion ----------
syn match wispInclude "^<\S\+"

" ---------- Brackets and braces (JUXT / CURL sugar) ----------
syn match wispDelimiter "[()\[\]{}]"

" ---------- Zero ----------
syn match wispZero "()"

" ---------- Def/mac patterns ----------
" (= name ...) and (:= name ...)
" Highlight the name being defined
syn match wispDefName "\%((\s*=\s\+\)\@<=\S\+"
syn match wispDefName "\%((\s*:=\s\+\)\@<=\S\+"

" ---------- Law name in signature ----------
" (LAW (name ...) ...)
syn match wispLawName "\%((\s*LAW\s\+(\s*\)\@<=\S\+"

" ---------- Highlighting ----------
hi def link wispComment    Comment
hi def link wispTodo       Todo
hi def link wispString     String
hi def link wispNumber     Number
hi def link wispSpecial    Keyword
hi def link wispDefine     Keyword
hi def link wispBind       Keyword
hi def link wispInclude    Include
hi def link wispDelimiter  Delimiter
hi def link wispZero       Constant
hi def link wispDefName    Function
hi def link wispLawName    Function
