"------------------------------------------------------------------------------
" Author: Luke Davis (lukelbd@gmail.com)
" Date:   2018-09-03
" A minimal, informative, black-and-white tabline that helps keep focus on the
" content in each window and accounts for long filenames and many open tabs.
"------------------------------------------------------------------------------
" Global settings and autocommands
" Note: Queue flag updates whenever reading or writing buffers to generate flags before
" gitgutter processes trigger and support simple fugitive-only version of plugin.
" Warning: For some reason 'checktime %' does not trigger autocommand but checktime
" without arguments does, and FileChangedShellPost causes warning message to be shown
" even with 'silent! checktime' but FileChangedShell does not.
scriptencoding utf-8  " required for truncation symbols
setglobal tabline=%!Tabline()
let &g:showtabline = &showtabline ? &g:showtabline : 1
if !exists('g:tabline_maxlength')  " support deprecated name
  let g:tabline_maxlength = get(g:, 'tabline_charmax', 13)
endif
if !exists('g:tabline_skip_filetypes')  " support deprecated name
  let g:tabline_skip_filetypes = get(g:, 'tabline_ftignore', ['diff', 'help', 'man', 'qf'])
endif
augroup tabline_update
  au!
  au FileChangedShell * call setbufvar(expand('<afile>'), 'tabline_file_changed', 1)
  au BufReadPost,BufWritePost * let b:tabline_file_changed = 0
  au BufReadPost,BufWritePost,FileChangedShell * let b:tabline_repo_changed = 1
  au BufEnter,InsertEnter,TextChanged * silent! checktime
  au BufWritePost * call s:gitgutter_update('%', 1)
  au User GitGutter call s:gitgutter_update('%')
  au User GitGutterStage call s:fugitive_update('%')
  au User FugitiveChanged call s:queue_updates()
  au FocusGained * call s:queue_updates()
augroup END

" Primary tabline function
" Note: Updating gitgutter can be slow and cause display to hang so run once without
" processing and queue another draw after every FugitiveChanged event. This prevents
" screen from hanging, e.g. after :Git stage triggers 'press enter to coninue' prompt
function! Tabline()
  let redraw = get(g:, 'tabline_redraw', 0)
  let g:tabline_redraw = 0
  if redraw  " quickly redraw tabline without checking unstaged changes
    let tabstring = s:tabline_text(0)
  else  " redraw tabline including unstaged changes check
    let tabstring = s:tabline_text(1)
  endif
  if redraw  " only happens if fugitive exists
    call feedkeys("\<Cmd>silent! redrawtabline\<CR>", 'n')
  endif
  return tabstring
endfunction
function! TablineFlags(...) abort  " public function
  return call('s:tabline_flags', a:000)
endfunct
function! TablineBuffers(...) abort  " public function
  return call('s:tabline_buffers', a:000)
endfunct

" Detect fugitive staged changes
" Note: Git gutter will be out of date if file is modified and has unstaged changes
" on disk so detect unstaged changes with fugitive. Only need to do this each time
" file changes then will persist the [~] flag state across future tab draws.
function! s:fugitive_update(...) abort
  let bnr = bufnr(a:0 ? a:1 : '')  " default current buffer
  let path = fnamemodify(bufname(bnr), ':p')
  let head = ['diff', '--quiet', '--ignore-submodules']
  if !exists('*FugitiveExecute') | return | endif
  let fchanged = getbufvar(bnr, 'tabline_file_changed', 0)
  let rchanged = getbufvar(bnr, 'tabline_repo_changed', 0)
  if fchanged || rchanged || !exists('*gitgutter#process_buffer')
    silent let result = FugitiveExecute(head + [path])
    let status = get(result, 'exit_status', 0)
    if status == 0 || status == 1
      call setbufvar(bnr, 'tabline_unstaged_changes', status == 1)
    endif
  endif  " see: https://stackoverflow.com/a/1587877/4970632
  silent let result = FugitiveExecute(head + ['--staged', path])
  let status = get(result, 'exit_status', 0)
  if status == 0 || status == 1  " exits 1 if there are staged changes
    call setbufvar(bnr, 'tabline_staged_changes', status == 1)
  endif
endfunction

" Detect gitgutter staged changes
" Note: Previously used git gutter to get staged/unstaged status but now have mostly
" switched to fugitive. No longer need to run forced updates but still useful e.g. to
" detect 'unstaged' status in modified buffer and skip fugitive unstaged checks.
function! s:gitgutter_update(...) abort
  let bnr = bufnr(a:0 ? a:1 : '')
  let path = fnamemodify(bufname(bnr), ':p')
  if !exists('*gitgutter#process_buffer') | return | endif
  if getbufvar(bnr, 'tabline_file_changed', 0) | return | endif  " use fugitive only
  if a:0 > 1 && a:2
    let async = get(g:, 'gitgutter_async', 0)
    try
      let g:gitgutter_async = 0 | silent call gitgutter#process_buffer(bnr, 0)
    finally
      let g:gitgutter_async = async
    endtry
  endif
  let stats = getbufvar(bnr, 'gitgutter', {})
  let hunks = copy(get(stats, 'summary', []))  " [added, modified, removed]
  let value = len(filter(hunks, 'v:val')) > 0
  call setbufvar(bnr, 'tabline_unstaged_changes', value)
endfunction

" Assign git variables after FugitiveChanged
" Note: This assigns buffer variables after e.g. FileChangedShell or FugitiveChange
" so that Tabline() can further delay processing until tab needs to be redrawn.
function! s:queue_updates(...) abort
  let g:tabline_redraw = 1
  let repo = FugitiveGitDir()  " repo that was changed
  let base = fnamemodify(repo, ':h')  " remove .git tail
  if empty(repo)
    return
  endif
  let bnrs = call('s:tabline_buffers', a:000)
  let bnrs = type(bnrs) == 0 ? [bnrs] : bnrs
  for bnr in bnrs
    let irepo = getbufvar(bnr, 'git_dir', '')
    if irepo ==# repo
      call setbufvar(bnr, 'tabline_repo_changed', 1)
    endif
  endfor
endfunction

" Generate tabline colors
" Note: This is needed for GUI vim color schemes since they do not use cterm codes.
" Also some schemes use named colors so have to convert into hex by appending '#'.
function! s:tabline_color(code, ...) abort
  let group = hlID('Normal')  " see: https://vi.stackexchange.com/a/20757/8084
  let base = synIDattr(group, a:code . '#')
  if empty(base) || base[0] !=# '#'  " see: https://stackoverflow.com/a/27870856/4970632
    return
  endif  " unexpected output
  let shade = a:0 ? a:1 ? 0.3 : 0.0 : 0.0  " shade toward neutral gray
  let color = '#'  " default hex color
  for idx in range(1, 5, 2)  " vint: -ProhibitUsingUndeclaredVariable
    let value = str2nr(base[idx:idx + 1], 16)
    let value = value - shade * (value - 128)
    let value = printf('%02x', float2nr(value))
    let color .= value
  endfor
  return color
endfunction

" Get primary panel in tab ignoring popups
" Note: This skips windows containing shell commands, e.g. full-screen fzf
" prompts, and uses the first path that isn't a skipped filetype.
function! s:tabline_buffers(...) abort
  let skip = get(g:, 'tabline_skip_filetypes', [])
  let tnrs = a:0 ? a:000 : range(1, tabpagenr('$'))
  let bnrs = []
  for tnr in tnrs
    let ibnrs = tabpagebuflist(tnr)
    let bnr = get(ibnrs, 0, 0)  " default value
    for ibnr in ibnrs
      if expand('#' . ibnr . ':p') =~# '^!'
        continue  " skip shell commands e.g. fzf
      elseif index(skip, getbufvar(ibnr, '&filetype', '')) == -1
        let bnr = ibnr | break
      endif
    endfor
    for ibnr in ibnrs  " settabvar() somehow interferes with visual mode iter#scroll
      call setbufvar(ibnr, 'tabline_bufnr', bnr)
    endfor
    call add(bnrs, bnr)
  endfor
  if a:0 == 1  " scalar result
    return bnrs[0]
  else  " list result
    return bnrs
  endif
endfunction

" Get the path label for the tabline
" Note: This replaces 40-digit git hashes with 7-digit abbreviations and replaces
" empty filename paths with the detected filetype.
function! s:tabline_label(...)
  let bnr = bufnr(a:0 ? a:1 : '')
  let blob = '^\x\{33}\(\x\{7}\)$'
  let head = getbufvar(bnr, 'fugitive_type', '')
  let base = getbufvar(bnr, 'git_dir', '')
  let path = expand('#' . bnr . ':p')
  let name = expand('#' . bnr . ':p:t')
  if name =~# '^!'  " shell commands
    let name = ''
  elseif name =~# blob  " truncate fugitive commit hash
    let name = substitute(name, blob, '\1', '')
  elseif !empty(head)
    let name = fnamemodify(base, ':h:t')
  elseif empty(name)  " display filetype instead of path
    let name = getbufvar(bnr, '&filetype', name)
  endif
  let name = empty(name) ? '?' : name
  let name = empty(head) ? name : head . ':' . name
  return name
endfunction

" Get tabline flags
" Note: This uses [+] for modified changes, [~] for unstaged changes, [:] for staged
" uncommitted changes, and [!] for files changed on disk. See above for details.
function! s:tabline_flags(...) abort
  let bnr = bufnr(a:0 ? a:1 : '')
  let path = bufname(bnr)
  let blank = empty(path) || path =~# '^!'
  let process = a:0 > 1 ? a:1 : 0  " whether to re-process changes
  let changed = getbufvar(bnr, 'tabline_repo_changed', 0)  " after FugitiveChanged
  if !blank && changed && process
    call s:gitgutter_update(bnr)  " backup in case we skip fugitive unstaged check
    call s:fugitive_update(bnr)  " updates unstaged only if b:tabline_file_changed
    call setbufvar(bnr, 'tabline_repo_changed', 0)
  endif
  let flags = []  " flags 
  let modified = !blank && getbufvar(bnr, '&modified', 0)
  let unstaged = !blank && getbufvar(bnr, 'tabline_unstaged_changes', 0)
  let staged = !blank && getbufvar(bnr, 'tabline_staged_changes', 0)
  let changed = !blank && getbufvar(bnr, 'tabline_file_changed', 0)
  if modified | call add(flags, '[+]') | endif
  if unstaged | call add(flags, '[~]') | endif
  if staged | call add(flags, '[:]') | endif
  if changed | call add(flags, '[!]') | endif
  if changed && modified && !getbufvar(bnr, 'tabline_warnchanged', 0)
    echohl WarningMsg
    echo 'Warning: Modifying buffer that was changed on disk.'
    echohl None
    call setbufvar(bnr, 'tabline_warnchanged', 1)
  endif
  return empty(flags) ? '' : ' ' . join(flags, '')
endfunction

" Generate tabline text
" Note: This fills out the tabline by starting from the current tab then moving
" right-left-right-... until either all tabs are drawn or line is wider than &columns
function! s:tabline_text(...)
  " Initial stuff
  let tnr = tabpagenr()
  let nleft = 2  " maximum number of tabs to left before start filling to right
  let tleft = tnr + 1  " initial value before filling tabs to left
  let tright = tnr  " initial value before filling tabs to right
  let tcenter = tnr
  let tabstrings = []  " tabline string
  let tabtexts = []  " displayed text
  let process = a:0 ? a:1 : 0  " update gitgutter
  while strwidth(join(tabtexts, '')) <= &columns
    " Get tab path and tab text
    if tnr >= tabpagenr('$') || tleft > tcenter - nleft  " current and two to left
      let rfill = 0 | let tleft -= 1 | let tnr = tleft
    else  " fill to right until the final tab
      let rfill = 1 | let tright += 1 | let tnr = tright
    endif
    if tleft < 1 && tright > tabpagenr('$')
      break
    elseif rfill && tright > tabpagenr('$')
      continue  " possibly more tabs to the left
    elseif !rfill && tleft < 1
      continue  " possibly more tabs to the right
    endif
    let bnr = s:tabline_buffers(tnr)
    let label = s:tabline_label(bnr)
    let flags = s:tabline_flags(bnr, process)
    " Append truncated tab text
    let delta = len(label) - g:tabline_maxlength
    let index = (delta + delta % 2) / 2
    if label =~# '^\C[a-z]*:' && delta > 1
      let label = strcharpart(label, 0, g:tabline_maxlength) . '·'
    elseif delta > 2
      let label = '·' . strcharpart(label, index, g:tabline_maxlength) . '·'
    endif
    let group = tnr == tabpagenr() ? '%#TabLineSel#' : '%#TabLine#'
    let tabtext = ' ' . tnr . '|' . label . flags . ' '
    let tabstring = '%' . tnr . 'T' . group . tabtext
    if rfill
      call add(tabtexts, tabtext)
      call add(tabstrings, tabstring)
    else
      call insert(tabtexts, tabtext)
      call insert(tabstrings, tabstring)
    endif
  endwhile
  " Truncate if too long
  let tleft = max([tleft, 1])
  let tright = min([tright, tabpagenr('$')])
  let prefix = tleft > 1 ? '···' : ''
  let suffix = tright < tabpagenr('$') ? '···' : ''
  while strwidth(prefix . join(tabtexts, '') . suffix) > &columns
    if tleft <= 1 || tcenter - tleft <= nleft
      let tabstrings = tabstrings[:-2]
      let tabtexts = tabtexts[:-2]
      let tright -= 1
      let suffix = '···'
    else
      let tabstrings = tabstrings[1:]
      let tabtexts = tabtexts[1:]
      let prefix = '···'
      let tleft += 1
    endif
  endwhile
  " Apply syntax colors and return string
  let s = has('gui_running') ? 'gui' : 'cterm'
  let flag = has('gui_running') ? '#be0119' : 'Red'  " copied from xkcd scarlet
  let black = has('gui_running') ? s:tabline_color('bg', 1) : 'Black'
  let white = has('gui_running') ? s:tabline_color('fg', 0) : 'White'
  let tabline = s . 'fg=' . white . ' ' . s . 'bg=' . black . ' ' . s . '=None'
  let tablinesel = s . 'fg=' . black . ' ' . s . 'bg=' . white . ' ' . s . '=None'
  let tablinefill = s . 'fg=' . white . ' ' . s . 'bg=' . black . ' ' . s . '=None'
  exe 'highlight TabLine ' . tabline
  exe 'highlight TabLineSel ' . tablinesel
  exe 'highlight TabLineFill ' . tablinefill
  let tabstring = prefix . join(tabstrings,'') . suffix . '%#TabLineFill#'
  return tabstring
endfunction
