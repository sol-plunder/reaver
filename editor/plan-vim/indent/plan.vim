" Vim indent file
" Language: plan (PLAN Assembly)

if exists("b:did_indent")
  finish
endif
let b:did_indent = 1

setlocal indentexpr=PlanIndent()
setlocal indentkeys=0),0],0},o,O
setlocal autoindent
setlocal lisp
setlocal lispwords==,:=,LAW,EVAL,PIN,#juxt,@

function! PlanIndent()
  let lnum = prevnonblank(v:lnum - 1)
  if lnum == 0
    return 0
  endif

  let prev = getline(lnum)
  let curr = getline(v:lnum)
  let ind = indent(lnum)

  " Count net open parens/brackets/braces on previous line
  let opens = 0
  let i = 0
  while i < len(prev)
    let c = prev[i]
    if c == ';'
      break
    endif
    if c == '"'
      let i += 1
      while i < len(prev) && prev[i] != '"'
        let i += 1
      endwhile
    endif
    if c == '(' || c == '[' || c == '{'
      let opens += 1
    elseif c == ')' || c == ']' || c == '}'
      let opens -= 1
    endif
    let i += 1
  endwhile

  " Count net close parens on current line (for dedent)
  let closes = 0
  let i = 0
  while i < len(curr)
    let c = curr[i]
    if c == ';'
      break
    endif
    if c == '"'
      let i += 1
      while i < len(curr) && curr[i] != '"'
        let i += 1
      endwhile
    endif
    if c == ')' || c == ']' || c == '}'
      let closes += 1
    elseif c == '(' || c == '[' || c == '{'
      break
    endif
    let i += 1
  endwhile

  let ind += opens * shiftwidth()
  let ind -= closes * shiftwidth()
  return ind < 0 ? 0 : ind
endfunction
