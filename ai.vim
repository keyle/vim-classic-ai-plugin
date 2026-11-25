" ai.vim — minimal OpenRouter assistant for Vim 8.3
"
" Personal plugin (lives in ~/.vim/plugin/, not plugged/).
" Model has no tools: no disk, no network, no web search is passed to the
" API. It answers only from internal knowledge. Reasoning is captured but
" never inserted into the buffer — view it with :Ait.
"
" Usage:
"   :Ai                     ask. Preferred interactive form: opens a
"                           small scratch prompt below — type the
"                           question there (Enter sends, Esc then q
"                           cancels, and :q cancels too, like the usual
"                           Vim habit) and the answer appears below that.
"                           The prompt is plain buffer text, NOT the
"                           command line, so command-line abbreviations
"                           (cnoreabbrev make -> BuildViaMake, b, e, ...)
"                           cannot corrupt natural-language questions the
"                           way they do in ":Ai <question>" or input().
"                           With a visual selection (v/V then :Ai) the
"                           answer is about that selection: code changes
"                           (rewrite/implement/fix...) replace it in place,
"                           questions open as Markdown below. With NO
"                           selection it is a blank canvas — the question
"                           is sent alone, ChatGPT-style, and the answer
"                           opens in the Markdown window below; nothing in
"                           the buffer is touched.
"                           The model gets the file name + filetype as a
"                           hint and the selection as context when present
"                           — still no disk/network tools.
"                           Markdown answers open in a scratch window below
"                           (:q dismisses without writing anything).
"   :Ai <question>          same, with the question typed on the command
"                           line. Kept for scripts; interactive typing is
"                           better via bare :Ai (see above) because
"                           cnoreabbrev expands typed words — press Ctrl-V
"                           before a word ("<C-v>make") to bypass it.
"   :%Ai <question>         whole buffer counts as the selection (asks for
"                           confirm before a code replace; questions only
"                           open the Markdown buffer).
"   :Ait                    show last request/reasoning/response in a
"                           temporary scratch buffer.
"
" Config (in vimrc, before startup):
"   let g:ai_model = 'meta/muse-ember'
"   let g:ai_thinking = 'max'   " low|medium|high|max|xhigh|minimal|none
"   let g:ai_nitro = 1             " 1 => provider sort=throughput (fastest)
"   let g:ai_response_height = 42  " height of the Markdown answer window
"   let g:ai_prompt_height = 5     " height of the :Ai question prompt window
"   " API key is read ONLY from the environment variable
"   " $OPENROUTER_API_KEY — export it in your shell before starting Vim.

if exists('g:loaded_ai_plugin')
  finish
endif
let g:loaded_ai_plugin = 1

let s:save_cpo = &cpoptions
set cpoptions&vim

" ---- config defaults ---------------------------------------------------------

let g:ai_model = get(g:, 'ai_model', 'meta/muse-ember')
let g:ai_thinking = get(g:, 'ai_thinking', 'max')
let g:ai_reasoning_max_tokens = get(g:, 'ai_reasoning_max_tokens', 0)
let g:ai_temperature = get(g:, 'ai_temperature', 0.7)
let g:ai_max_tokens = get(g:, 'ai_max_tokens', 4096)
let g:ai_nitro = get(g:, 'ai_nitro', 1)
let g:ai_provider_sort = get(g:, 'ai_provider_sort', '')
let g:ai_provider_order = get(g:, 'ai_provider_order', [])
let g:ai_api_url = get(g:, 'ai_api_url', 'https://openrouter.ai/api/v1/chat/completions')
let g:ai_prompt_height = get(g:, 'ai_prompt_height', 5)
let g:ai_response_height = get(g:, 'ai_response_height', 42)
let g:ai_system = get(g:, 'ai_system',
      \ 'You are a helpful coding assistant inside Vim. When asked to modify code, return ONLY the replacement text with no explanation and no markdown fences, preserving indentation and language. When asked a question, give a complete answer in Markdown (headings, code fences and lists allowed) including bugs found and corrected code as needed. You have no file or network access; answer only from internal knowledge.')

let g:ai_debug = get(g:, 'ai_debug', 0)

" ---- last-run state (for :Ait) ----------------------------------------------

let s:last_question = ''
let s:last_selection = ''
let s:last_has_selection = 0
let s:last_range = ''
let s:last_model = ''
let s:last_thinking_desc = ''
let s:last_reasoning = ''
let s:last_content = ''
let s:last_request_json = ''
let s:last_usage = ''
let s:last_mode = 'code'
" pending :Ai prompt (scratch buffer) — selection/range captured before
" the prompt opens, so submitting can resume in the original window.
let s:pending_prompt = {}

" ---- helpers ------------------------------------------------------------------

function! s:StripFences(text) abort
  let l:lines = split(a:text, "\n", 1)
  while len(l:lines) > 0 && l:lines[0] == ''
    call remove(l:lines, 0)
  endwhile
  while len(l:lines) > 0 && l:lines[-1] == ''
    call remove(l:lines, -1)
  endwhile
  if len(l:lines) > 0 && l:lines[0] =~ '^```'
    call remove(l:lines, 0)
  endif
  if len(l:lines) > 0 && l:lines[-1] =~ '^```'
    call remove(l:lines, -1)
  endif
  while len(l:lines) > 0 && l:lines[0] == ''
    call remove(l:lines, 0)
  endwhile
  while len(l:lines) > 0 && l:lines[-1] == ''
    call remove(l:lines, -1)
  endwhile
  return join(l:lines, "\n")
endfunction

function! s:ExtractContent(msg) abort
  if type(a:msg) != type({}) || !has_key(a:msg, 'content')
    return ''
  endif
  let l:c = a:msg.content
  if type(l:c) == type('')
    return l:c
  endif
  if type(l:c) == type([])
    let l:parts = []
    for l:p in l:c
      if type(l:p) == type('')
        call add(l:parts, l:p)
      elseif type(l:p) == type({}) && has_key(l:p, 'text')
        call add(l:parts, l:p.text)
      elseif type(l:p) == type({}) && has_key(l:p, 'content')
        call add(l:parts, l:p.content)
      endif
    endfor
    return join(l:parts, "\n")
  endif
  return ''
endfunction

function! s:ExtractReasoning(msg) abort
  if type(a:msg) != type({})
    return ''
  endif
  if has_key(a:msg, 'reasoning') && type(a:msg.reasoning) == type('')
    return a:msg.reasoning
  endif
  if has_key(a:msg, 'reasoning_content') && type(a:msg.reasoning_content) == type('')
    return a:msg.reasoning_content
  endif
  if has_key(a:msg, 'reasoning_details') && type(a:msg.reasoning_details) == type([])
    let l:parts = []
    for l:item in a:msg.reasoning_details
      if type(l:item) == type({}) && has_key(l:item, 'text') && type(l:item.text) == type('')
        call add(l:parts, l:item.text)
      elseif type(l:item) == type({}) && has_key(l:item, 'reasoning')
        if type(l:item.reasoning) == type('')
          call add(l:parts, l:item.reasoning)
        endif
      endif
    endfor
    return join(l:parts, "\n")
  endif
  return ''
endfunction

function! s:ThinkingDesc() abort
  if type(g:ai_thinking) == type(0)
    return 'max_tokens=' . g:ai_thinking
  endif
  if type(g:ai_thinking) == type('')
    return 'effort=' . g:ai_thinking
  endif
  return string(g:ai_thinking)
endfunction

" Is this prompt a question ("is this okay", "is get_chunk correct",
" "explain/review/check ...") rather than a code-modification request
" ("rewrite this", "implement add", "fix this")? Questions open in a
" Markdown buffer and never touch the code; modification requests replace
" the selection. Rewrite verbs win over trailing "?" / trigger words so
" "fix this bug" stays code.
function! s:IsQuestion(q) abort
  let l:q = substitute(tolower(a:q), '^\s\+', '', '')
  if l:q ==# ''
    return 0
  endif
  if l:q =~ '^\(rewrite\|refactor\|reimplement\|implement\|complete\|fill\|write\|generate\|create\|add\|insert\|fix\|correct\|modify\|change\|update\|optimize\|optimise\|simplify\|translate\|convert\|remove\|delete\|rename\|make\|build\|produce\|return\|replace\|finish\|port\|clean\|tidy\|format\|modernize\|modernise\|upgrade\|improve\|enhance\|extend\|expand\)\>'
    return 0
  endif
  if l:q =~ '?$'
    return 1
  endif
  if l:q =~ '^\(is\|are\|was\|were\|do\|does\|did\|can\|could\|should\|would\|will\|shall\|may\|might\|what\|why\|how\|when\|where\|which\|who\|whom\|whose\|explain\|describe\|review\|check\|tell\|show\|give\|list\|summarize\|summarise\|analyze\|analyse\|evaluate\|assess\|inspect\|verify\|debug\|discuss\|comment\|critique\)\>'
    return 1
  endif
  if l:q =~ '\<\(correct\|okay\|bug\|buggy\|wrong\|safe\|efficient\|better\|problem\|issue\|overflow\|leak\|race\|undefined\|error\)\>'
    return 1
  endif
  return 0
endfunction

function! s:BuildPayload(question, selection, has_selection, is_question, ft, fname) abort
  if !a:has_selection
    " Blank canvas: ChatGPT-style quickshot. Only the question is sent.
    let l:user = "Question:\n" . a:question . "\n\nAnswer in Markdown."
  else
    let l:where = empty(a:fname) ? 'untitled' : a:fname
    if !empty(a:ft)
      let l:where = l:where . ' (' . a:ft . ')'
    endif
    if !a:is_question
      let l:user = "File: " . l:where . "\nInstruction:\n" . a:question . "\n\nSelected code/text:\n```\n" . a:selection . "\n```\n\n"
            \ . 'Return ONLY the replacement for the selection. Do not add explanation or text outside it.'
    else
      let l:user = "File: " . l:where . "\nQuestion:\n" . a:question . "\n\nSelected code/text:\n```\n" . a:selection . "\n```\n\n"
            \ . 'Answer the question about the selected code in Markdown. Do NOT return a replacement for the code. Include bugs found and, if helpful, corrected code in fenced code blocks.'
    endif
  endif
  let l:payload = {
        \ 'model': g:ai_model,
        \ 'messages': [{'role': 'system', 'content': g:ai_system},
        \              {'role': 'user', 'content': l:user}],
        \ 'temperature': g:ai_temperature,
        \ 'max_tokens': g:ai_max_tokens,
        \ }
  " reasoning is requested (exclude=false) so :Ait can show it, but it is
  " never inserted into the buffer. Use 'none' to disable.
  " NOTE: must be v:false (JSON false), not 0 — OpenRouter rejects a
  " numeric exclude with "expected boolean, received number".
  let l:think = g:ai_thinking
  if type(g:ai_reasoning_max_tokens) == type(0) && g:ai_reasoning_max_tokens > 0
    let l:payload.reasoning = {'max_tokens': g:ai_reasoning_max_tokens, 'exclude': v:false}
  elseif type(l:think) == type(0) && l:think > 0
    let l:payload.reasoning = {'max_tokens': l:think, 'exclude': v:false}
  elseif type(l:think) == type('') && l:think !=# '' && l:think !=# 'none' && l:think !=# 'off'
    let l:payload.reasoning = {'effort': l:think, 'exclude': v:false}
  endif
  let l:sort = g:ai_provider_sort
  if empty(l:sort) && g:ai_nitro
    let l:sort = 'throughput'
  endif
  let l:provider = {}
  if !empty(l:sort)
    let l:provider.sort = l:sort
  endif
  if type(g:ai_provider_order) == type([]) && !empty(g:ai_provider_order)
    let l:provider.order = g:ai_provider_order
  endif
  if !empty(l:provider)
    let l:payload.provider = l:provider
  endif
  return l:payload
endfunction

function! s:CallOpenRouter(payload) abort
  let l:key = $OPENROUTER_API_KEY
  if empty(l:key)
    return {'ok': 0, 'error': 'Ai: $OPENROUTER_API_KEY is not set. Export it in your shell before starting Vim.'}
  endif
  if !exists('*json_encode') || !exists('*json_decode')
    return {'ok': 0, 'error': 'Ai: json support unavailable in this Vim (needs Vim 8.3).'}
  endif
  if !executable('curl')
    return {'ok': 0, 'error': 'Ai: curl not found in PATH.'}
  endif
  let l:reqfile = tempname()
  let l:respfile = tempname()
  let l:codefile = tempname()
  let l:errfile = tempname()
  let l:body = ''
  let l:code = '000'
  let l:code_num = 0
  let l:shellerr = 0
  try
    call writefile([json_encode(a:payload)], l:reqfile)
    let l:cmd = 'curl -s -S --max-time 300 -X POST '
          \ . shellescape(g:ai_api_url)
          \ . ' -H ' . shellescape('Authorization: Bearer ' . l:key)
          \ . ' -H ' . shellescape('Content-Type: application/json')
          \ . ' -H ' . shellescape('X-Title: ai.vim')
          \ . ' --data-binary ' . shellescape('@' . l:reqfile)
          \ . ' -o ' . shellescape(l:respfile)
          \ . ' -w "%{http_code}" > ' . shellescape(l:codefile)
          \ . ' 2> ' . shellescape(l:errfile)
    let l:_ = system(l:cmd)
    let l:shellerr = v:shell_error
    if filereadable(l:codefile)
      let l:code_lines = readfile(l:codefile)
      if !empty(l:code_lines)
        let l:code = l:code_lines[0]
        let l:code_num = str2nr(l:code)
      endif
    endif
    if filereadable(l:respfile)
      let l:body = join(readfile(l:respfile), "\n")
    endif
  catch
    return {'ok': 0, 'error': 'Ai: request failed: ' . v:exception}
  finally
    call delete(l:reqfile)
    call delete(l:respfile)
    call delete(l:codefile)
    call delete(l:errfile)
  endtry
  if empty(l:body)
    let l:errtxt = ''
    if filereadable(l:errfile)
      let l:errtxt = join(readfile(l:errfile), "\n")
    endif
    return {'ok': 0, 'error': 'Ai: empty response (http ' . l:code . ', curl ' . l:shellerr . ')' . (empty(l:errtxt) ? '' : ': ' . l:errtxt)}
  endif
  let l:resp = 0
  try
    let l:resp = json_decode(l:body)
  catch
    return {'ok': 0, 'error': 'Ai: could not parse response (http ' . l:code . '): ' . substitute(l:body, '\n', ' ', 'g')[:200]}
  endtry
  if type(l:resp) != type({})
    return {'ok': 0, 'error': 'Ai: unexpected response (http ' . l:code . ')', 'raw': l:body}
  endif
  if has_key(l:resp, 'error')
    let l:emsg = 'unknown error'
    if type(l:resp.error) == type('') && !empty(l:resp.error)
      let l:emsg = l:resp.error
    elseif type(l:resp.error) == type({}) && has_key(l:resp.error, 'message')
      let l:emsg = l:resp.error.message
    endif
    return {'ok': 0, 'error': 'Ai: API error (http ' . l:code . '): ' . l:emsg, 'raw': l:body}
  endif
  if !has_key(l:resp, 'choices') || type(l:resp.choices) != type([]) || empty(l:resp.choices)
    return {'ok': 0, 'error': 'Ai: no choices in response (http ' . l:code . ')', 'raw': l:body}
  endif
  if l:code_num < 200 || l:code_num > 299
    return {'ok': 0, 'error': 'Ai: http ' . l:code . ': ' . substitute(l:body, '\n', ' ', 'g')[:200], 'raw': l:body}
  endif
  let l:choice = l:resp.choices[0]
  let l:msg = {}
  let l:reasoning = ''
  let l:content = ''
  let l:finish = ''
  let l:usage = ''
  if type(l:choice) == type({}) && has_key(l:choice, 'message')
    let l:msg = l:choice.message
    let l:reasoning = s:ExtractReasoning(l:msg)
    let l:content = s:ExtractContent(l:msg)
    if has_key(l:choice, 'finish_reason')
      let l:finish = l:choice.finish_reason
    endif
  endif
  if has_key(l:resp, 'usage')
    let l:usage = string(l:resp.usage)
  endif
  if empty(l:content)
    if l:finish ==# 'length'
      return {'ok': 0, 'error': 'Ai: reasoning consumed the token budget (finish_reason=length). Lower g:ai_thinking or raise g:ai_max_tokens.', 'raw': l:body, 'reasoning': l:reasoning, 'usage': l:usage}
    endif
    return {'ok': 0, 'error': 'Ai: empty content in response (finish_reason=' . l:finish . ')', 'raw': l:body, 'reasoning': l:reasoning, 'usage': l:usage}
  endif
  return {'ok': 1, 'content': l:content, 'reasoning': l:reasoning, 'usage': l:usage, 'finish_reason': l:finish, 'raw': l:body}
endfunction

function! s:VisualColsIfCharwise(line1, line2) abort
  let l:vm = visualmode()
  if l:vm !=# 'v'
    return [0, 0]
  endif
  let l:lt = getpos("'<")
  let l:gt = getpos("'>")
  if l:lt[1] != a:line1 || l:gt[1] != a:line2
    return [0, 0]
  endif
  return [l:lt[2], l:gt[2]]
endfunction

function! s:ApplyReplace(line1, line2, resp_text) abort
  let l:resp_text = s:StripFences(a:resp_text)
  if empty(l:resp_text)
    echom 'Ai: response is empty after stripping fences; nothing changed.'
    return
  endif
  let l:resp_lines = split(l:resp_text, "\n", 1)
  let l:cols = s:VisualColsIfCharwise(a:line1, a:line2)
  if l:cols[0] > 0
    " charwise visual: splice prefix/suffix into first/last line so only
    " the selected columns are replaced.
    let l:first = getline(a:line1)
    let l:last = getline(a:line2)
    let l:prefix = l:cols[0] > 1 ? l:first[0 : l:cols[0] - 2] : ''
    let l:suffix = l:cols[1] < strlen(l:last) ? l:last[l:cols[1] :] : ''
    if len(l:resp_lines) == 1
      let l:newlines = [l:prefix . l:resp_lines[0] . l:suffix]
    else
      let l:newlines = [l:prefix . l:resp_lines[0]]
      if len(l:resp_lines) > 2
        call extend(l:newlines, l:resp_lines[1:-2])
      endif
      call add(l:newlines, l:resp_lines[-1] . l:suffix)
    endif
  else
    let l:newlines = l:resp_lines
  endif
  let l:oldcount = a:line2 - a:line1 + 1
  if len(l:newlines) > l:oldcount
    " grow: set first oldcount lines, then append the remainder.
    call setline(a:line1, l:newlines[0 : l:oldcount - 1])
    call append(a:line1 + l:oldcount - 1, l:newlines[l:oldcount :])
  else
    call setline(a:line1, l:newlines)
    if len(l:newlines) < l:oldcount
      execute (a:line1 + len(l:newlines)) . ',' . a:line2 . 'delete _'
    endif
  endif
  " place cursor at end of replacement
  call cursor(a:line1 + len(l:newlines) - 1, 1)
endfunction

" Show a question answer as Markdown in a scratch window below the
" current one. The code buffer is never modified; :q (or :close) dismisses
" the response and wipes the scratch buffer. Markdown is kept verbatim,
" including fenced code blocks.
function! s:ShowMarkdownResponse(resp_text) abort
  let l:lines = split(a:resp_text, "\n", 1)
  while len(l:lines) > 0 && l:lines[0] == ''
    call remove(l:lines, 0)
  endwhile
  while len(l:lines) > 0 && l:lines[-1] == ''
    call remove(l:lines, -1)
  endwhile
  if empty(l:lines)
    echom 'Ai: response is empty; nothing shown.'
    return
  endif
  let l:height = g:ai_response_height
  if type(l:height) != type(0) || l:height < 1
    let l:height = 15
  endif
  execute 'belowright ' . l:height . 'new'
  setlocal buftype=nofile bufhidden=wipe noswapfile
  setlocal nonumber norelativenumber wrap
  setlocal filetype=markdown
  silent execute 'file ' . fnameescape('AI response (' . bufnr('%') . ')')
  call setline(1, l:lines)
  setlocal nomodified
  call cursor(1, 1)
endfunction

" ---- :Ai question prompt (scratch buffer) -----------------------------------
" Why a buffer, not input('AI: ')? Both input() and ":Ai <q>" go through
" the command line, where cnoreabbrev expands typed words ("make" ->
" BuildViaMake, "b" -> BuildViaMake, "e" -> :FZF, ...). Buffer text has
" no command-line abbreviations, so questions arrive verbatim.

function! s:ClosePrompt() abort
  let l:buf = bufnr('%')
  if winnr('$') > 1
    close
  else
    enew
  endif
  if bufexists(l:buf)
    execute 'bwipeout ' . l:buf
  endif
endfunction

function! s:ReturnToOrigin() abort
  let l:winid = get(s:pending_prompt, 'winid', 0)
  if l:winid != 0 && win_id2win(l:winid) != 0
    call win_gotoid(l:winid)
  endif
endfunction

function! s:CancelPrompt() abort
  if empty(s:pending_prompt)
    return
  endif
  let s:pending_prompt = {}
  call s:ClosePrompt()
  call s:ReturnToOrigin()
  echom 'Ai: prompt cancelled.'
endfunction

" Global wrappers: buffer-local mappings cannot call s: functions (E81),
" so the prompt mappings below go through these instead.
function! AiPromptCancel() abort
  call s:CancelPrompt()
endfunction

function! AiPromptSubmit() abort
  call s:SubmitPrompt()
endfunction

function! AiPromptWiped(buf) abort
  call s:PromptWiped(str2nr(a:buf))
endfunction

" A prompt buffer wiped by any other means (:q from Normal mode, :close,
" :bwipeout, ...) is a cancel too: just drop the pending state, exactly
" like Esc then q. Submit/cancel already cleared it, so this is a no-op
" on those paths.
function! s:PromptWiped(buf) abort
  if !empty(s:pending_prompt) && get(s:pending_prompt, 'bufnr', -1) == a:buf
    let s:pending_prompt = {}
  endif
endfunction

" Does this text mean "quit the prompt"? Only an exact :q/:q!/:quit/:quit!/
" :qa/:qa! counts — a longer question merely mentioning :q is still sent.
function! s:IsQuitText(text) abort
  return a:text =~# '^:q!\?$' || a:text =~# '^:quit!\?$' || a:text =~# '^:qa!\?$'
endfunction

function! s:SubmitPrompt() abort
  if empty(s:pending_prompt)
    return
  endif
  let l:pending = s:pending_prompt
  let s:pending_prompt = {}
  " line 1 is the instruction header; the question is line 2 onwards.
  let l:qlines = line('$') >= 2 ? getline(2, '$') : []
  while len(l:qlines) > 0 && l:qlines[-1] =~ '^\s*$'
    call remove(l:qlines, -1)
  endwhile
  let l:question = trim(join(l:qlines, "\n"))
  call s:ClosePrompt()
  call s:ReturnToOrigin()
  if empty(l:question)
    echom 'Ai: no question given.'
    return
  endif
  " Habitual quit: typing :q (and Enter) in the prompt cancels, exactly
  " like Esc then q, instead of sending ":q" as a question.
  if s:IsQuitText(l:question)
    echom 'Ai: prompt cancelled.'
    return
  endif
  call s:RunAi(l:question, l:pending.line1, l:pending.line2,
        \ l:pending.selection, l:pending.has_selection,
        \ l:pending.range_desc, l:pending.ft, l:pending.fname)
endfunction

function! s:OpenPrompt(line1, line2, selection, has_selection, range_desc, ft, fname) abort
  let s:pending_prompt = {
        \ 'line1': a:line1, 'line2': a:line2, 'selection': a:selection,
        \ 'has_selection': a:has_selection, 'range_desc': a:range_desc,
        \ 'ft': a:ft, 'fname': a:fname, 'winid': win_getid()}
  let l:height = g:ai_prompt_height
  if type(l:height) != type(0) || l:height < 1
    let l:height = 3
  endif
  execute 'belowright ' . l:height . 'new'
  setlocal buftype=nofile bufhidden=wipe noswapfile
  setlocal nonumber norelativenumber wrap
  setlocal filetype=text
  silent execute 'file ' . fnameescape('AI question (' . bufnr('%') . ')')
  let s:pending_prompt.bufnr = bufnr('%')
  call setline(1, ['-- AI question: type on the next line, Enter to send, Esc then q / :q to cancel --', ''])
  setlocal nomodified
  autocmd BufWipeout <buffer> call AiPromptWiped(expand('<abuf>'))
  inoremap <buffer><silent> <CR> <Esc>:call AiPromptSubmit()<CR>
  nnoremap <buffer><silent> <CR> :call AiPromptSubmit()<CR>
  nnoremap <buffer><silent> q :call AiPromptCancel()<CR>
  nnoremap <buffer><silent> <Esc> :call AiPromptCancel()<CR>
  call cursor(2, 1)
  startinsert
endfunction

" ---- :Ai ----------------------------------------------------------------------

function! Ai(question, line1, line2) abort
  " Vim gives <line1>/<line2> == cursor line for a bare :Ai, so a single
  " line on the cursor with no visual marks match means "no selection".
  " Multi-line ranges, off-cursor ranges, and visual matches count as a
  " selection. No selection is a blank canvas (ChatGPT quickshot).
  let l:lt = getpos("'<")
  let l:gt = getpos("'>")
  let l:visual_match = (visualmode() !=# ''
        \ && l:lt[1] == a:line1 && l:gt[1] == a:line2)
  let l:off_cursor = (a:line1 != line('.') || a:line2 != line('.'))
  let l:has_selection = (a:line1 != a:line2) || l:off_cursor || l:visual_match
  let l:selection = ''
  let l:range_desc = 'none (blank canvas)'
  if l:has_selection
    let l:selection = join(getline(a:line1, a:line2), "\n")
    let l:range_desc = a:line1 . ',' . a:line2
  endif
  let l:ft = &filetype
  let l:fname = expand('%:t')
  " No argument: prompt in a scratch buffer (abbreviation-immune). A typed
  " argument skips the prompt (scripts); cnoreabbrev may already have
  " expanded words in it — see header usage notes.
  if empty(substitute(a:question, '\s\+', '', 'g'))
    call s:OpenPrompt(a:line1, a:line2, l:selection, l:has_selection,
          \ l:range_desc, l:ft, l:fname)
    return
  endif
  call s:RunAi(a:question, a:line1, a:line2, l:selection, l:has_selection,
        \ l:range_desc, l:ft, l:fname)
endfunction

function! s:RunAi(question, line1, line2, selection, has_selection, range_desc, ft, fname) abort
  let l:question = a:question
  " Blank canvas is always a question (nothing to replace).
  let l:is_question = !a:has_selection ? 1 : s:IsQuestion(l:question)
  " echo (not echom) for transient status: the window switch below cannot
  " be in "chunk mode". echom here would pause for press-ENTER.
  echo 'Ai: asking ' . g:ai_model . ' ...'
  redraw
  let l:payload = s:BuildPayload(l:question, a:selection, a:has_selection, l:is_question, a:ft, a:fname)
  let l:result = s:CallOpenRouter(l:payload)
  let s:last_question = l:question
  let s:last_selection = a:selection
  let s:last_has_selection = a:has_selection
  let s:last_range = a:range_desc
  let s:last_model = g:ai_model
  let s:last_thinking_desc = s:ThinkingDesc()
  let s:last_request_json = json_encode(l:payload)
  if !get(l:result, 'ok', 0)
    let s:last_reasoning = get(l:result, 'reasoning', '')
    let s:last_content = get(l:result, 'content', '')
    let s:last_usage = get(l:result, 'usage', '')
    if has_key(l:result, 'raw')
      let s:last_content = l:result.raw . "\n(ERROR) " . l:result.error
    endif
    " clear stale visual marks so a later bare :Ai is a blank canvas again.
    call setpos("'<", [0, 0, 0, 0])
    call setpos("'>", [0, 0, 0, 0])
    echohl ErrorMsg
    echom get(l:result, 'error', 'Ai: unknown error')
    echohl None
    return
  endif
  let s:last_reasoning = l:result.reasoning
  let s:last_content = l:result.content
  let s:last_usage = l:result.usage
  " Query-driven routing: questions open as Markdown below and never
  " modify the code; modification queries (selection required) replace
  " the selection. Blank canvas always routes to Markdown.
  if l:is_question
    let s:last_mode = 'markdown'
    let s:last_range = a:range_desc . ' (answer in Markdown window below)'
    call s:ShowMarkdownResponse(l:result.content)
  else
    let s:last_mode = 'code'
    " whole-buffer replace touches parts outside any smaller selection:
    " ask first. Smaller explicit ranges are the selection itself.
    if a:line1 == 1 && a:line2 == line('$') && line('$') > 1
      if confirm('Ai: replace the whole buffer? (other parts will change)', "&Yes\n&No", 1) != 1
        echom 'Ai: whole-buffer replace cancelled.'
        return
      endif
    endif
    let s:last_range = a:line1 . ',' . a:line2
    call s:ApplyReplace(a:line1, a:line2, l:result.content)
  endif
  " clear stale visual marks so a later bare :Ai is a blank canvas again.
  call setpos("'<", [0, 0, 0, 0])
  call setpos("'>", [0, 0, 0, 0])
  " drop the stale "asking ..." line without history/press-ENTER.
  echon ''
  echom 'Ai: done. See :Ait for reasoning.'
endfunction

" ---- :Ait ---------------------------------------------------------------------

function! Ait() abort
  if empty(s:last_question) && empty(s:last_content)
    echom 'Ait: no :Ai call yet.'
    return
  endif
  let l:lines = []
  call add(l:lines, 'Model: ' . s:last_model)
  call add(l:lines, 'Thinking: ' . s:last_thinking_desc)
  if empty(get(g:, 'ai_nitro', 0))
    call add(l:lines, 'Nitro: off')
  else
    call add(l:lines, 'Nitro: on (sort=throughput)')
  endif
  if s:last_mode ==# 'markdown'
    call add(l:lines, 'Mode: markdown (question answer in scratch window below; code untouched)')
  else
    call add(l:lines, 'Mode: code (selection replaced)')
  endif
  call add(l:lines, 'Range: ' . s:last_range)
  call add(l:lines, 'Usage: ' . (empty(s:last_usage) ? '(none)' : s:last_usage))
  call add(l:lines, '')
  call add(l:lines, '--- QUESTION ---')
  call extend(l:lines, split(s:last_question, "\n", 1))
  call add(l:lines, '')
  call add(l:lines, '--- SELECTION ---')
  if s:last_has_selection
    call extend(l:lines, split(s:last_selection, "\n", 1))
  else
    call add(l:lines, '(none)')
  endif
  call add(l:lines, '')
  call add(l:lines, '--- REASONING ---')
  if empty(s:last_reasoning)
    call add(l:lines, '(no reasoning returned by the model)')
  else
    call extend(l:lines, split(s:last_reasoning, "\n", 1))
  endif
  call add(l:lines, '')
  call add(l:lines, '--- RESPONSE ---')
  call extend(l:lines, split(s:last_content, "\n", 1))
  call add(l:lines, '')
  call add(l:lines, '--- REQUEST JSON (key omitted) ---')
  call add(l:lines, s:last_request_json)
  execute 'new'
  setlocal buftype=nofile bufhidden=wipe noswapfile
  setlocal nonumber norelativenumber
  setlocal filetype=text
  call setline(1, l:lines)
  setlocal nomodifiable
  call cursor(1, 1)
  nnoremap <buffer> q :close<CR>
  redraw
endfunction

command! -nargs=* -range Ai call Ai(<q-args>, <line1>, <line2>)
command! -nargs=0 Ait call Ait()

let &cpoptions = s:save_cpo
unlet s:save_cpo
