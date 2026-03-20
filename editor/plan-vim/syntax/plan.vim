" Vim syntax file
" Language: PLAN

if exists("b:current_syntax")
  finish
endif

let b:current_syntax = "plan"

" PLAN is case-sensitive
syn case match

" ---------- Comments ----------
syn match planComment ";.*$" contains=planTodo
syn keyword planTodo contained TODO FIXME XXX NOTE HACK BUG

" ---------- Strings ----------
syn region planString start='"' end='"' skip='\\"'

" ---------- Numbers ----------
" Decimal literals (sequences of digits not adjacent to symbol chars)
syn match planNumber "\<\d\+\>"

" ---------- Special forms (builtins) ----------
syn keyword planSpecial LAW EVAL PIN
syn match   planSpecial "\<#juxt\>"
syn match   planDefine  "^(\s*\zs="
syn match   planDefine  "^(\s*\zs:="
syn match   planDefine  "\%((\s*\)\@<==" 
syn match   planDefine  "\%((\s*\)\@<=:="

" ---------- Law syntax ----------
" The @ in bind forms
syn match planBind "@" contained
" Highlight bind forms: (@ name expr)
syn match planBind "(\s*@\>" 

" ---------- File inclusion ----------
syn match planInclude "^<\S\+"

" ---------- Brackets and braces (#juxt / #curl sugar) ----------
syn match planDelimiter "[()\[\]{}]"

" ---------- Zero ----------
syn match planZero "()"

" ---------- Def/mac patterns ----------
" (= name ...) and (:= name ...)
" Highlight the name being defined
syn match planDefName "\%((\s*=\s\+\)\@<=\S\+"
syn match planDefName "\%((\s*:=\s\+\)\@<=\S\+"

" ---------- Law name in signature ----------
" (LAW (name ...) ...)
syn match planLawName "\%((\s*LAW\s\+(\s*\)\@<=\S\+"

" ---------- Highlighting ----------
hi def link planComment    Comment
hi def link planTodo       Todo
hi def link planString     String
hi def link planNumber     Number
hi def link planSpecial    Keyword
hi def link planDefine     Keyword
hi def link planBind       Keyword
hi def link planInclude    Include
hi def link planDelimiter  Delimiter
hi def link planZero       Constant
hi def link planDefName    Function
hi def link planLawName    Function
