" Vim ftplugin file
" Language: Wisp (surface syntax for PLAN)

if exists("b:did_ftplugin")
  finish
endif
let b:did_ftplugin = 1

setlocal commentstring=;\ %s
setlocal comments=:;
setlocal iskeyword=33,35-39,42-58,60-90,92,94-122,124,126
" That's: ! # $ % & ' * + , - . / 0-9 : < = > ? @ A-Z \ ^ _ ` a-z | ~
" Basically everything except whitespace, " ( ) [ ] { } ;

setlocal shiftwidth=2
setlocal softtabstop=2
setlocal expandtab

" Matchit support for bracket pairs
if exists("loaded_matchit")
  let b:match_words = '(:),\[:\],{:}'
endif

let b:undo_ftplugin = "setlocal commentstring< comments< iskeyword< shiftwidth< softtabstop< expandtab<"
