"------------------------------------------------------------------------------
" Author: Luke Davis (lukelbd@gmail.com)
" Date:   2018-09-03
" A minimal, informative, black-and-white tabline that helps keep focus on the
" content in each window and accounts for long filenames and many open tabs.
"------------------------------------------------------------------------------
" Global settings and autocommands
" Warning: For some reason 'checktime %' does not trigger autocommand
" but checktime without arguments does.
" Warning: For some reason FileChangedShellPost causes warning message to
" be shown even with 'silent! checktime' but FileChangedShell does not.
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
  au VimEnter * call s:queue_updates()
  au BufEnter,InsertEnter,TextChanged * silent! checktime
  au BufReadPost,BufWritePost,BufNewFile * let b:tabline_filechanged = 0
  au BufWritePost,FileChangedShell * call s:fugitive_update(1, expand('<afile>'))
  au FileChangedShell * call setbufvar(expand('<afile>'), 'tabline_filechanged', 1)
  au User GitGutterStage call s:fugitive_update(0, '%')
  au User GitGutter call s:gitgutter_update(0, '%')
  au User FugitiveChanged call s:queue_updates() | let g:tabline_initialized = 0
augroup END

" Primary tabline function
" Note: Updating gitgutter can be slow and cause display to hang so run once without
" processing and queue another draw after every FugitiveChanged event. This prevents
" screen from hanging, e.g. after :Git stage triggers 'press enter to coninue' prompt
function! Tabline()
  let init = get(g:, 'tabline_initialized', 1)
  let g:tabline_initialized = 1
  if !init  " temporarily skip unstaged changes check
    let tabstring = s:tabline_text(0)
  else  " allow unstaged changes check
    let tabstring = s:tabline_text(1)
  endif
  if !init  " only happens if fugitive exists
    call feedkeys("\<Cmd>redrawtabline\<CR>", 'n')
  endif
  return tabstring
endfunction

" Detect fugitive staged changes
" Note: Git gutter will be out of date if file is modified and has unstaged changes
" on disk so detect unstaged changes with fugitive. Only need to do this each time
" file changes then will persist the [~] flag state across future tab draws.
function! s:fugitive_update(both, ...) abort
  let bnr = bufnr(a:0 ? a:1 : '')  " default current buffer
  let path = fnamemodify(bufname(bnr), ':p')
  let head = ['diff', '--quiet', '--ignore-submodules']
  if !exists('*FugitiveExecute') | return | endif
  if a:both
    let args = head + [path]
    let result = FugitiveExecute(args)
    let unstaged = get(result, 'exit_status', 0) == 1
    call setbufvar(bnr, 'tabline_unstaged', unstaged)
  endif
  let args = head + ['--staged', path]
  let result = FugitiveExecute(args)  " see: https://stackoverflow.com/a/1587877/4970632
  let staged = get(result, 'exit_status', 0) == 1  " exits 1 if there are staged changes
  call setbufvar(bnr, 'tabline_staged', staged)
endfunction

" Detect gitgutter staged changes
" Note: After e.g. :Git stage commands git gutter can be out of date if gitgutter
" process was not triggered, so update synchronously but only after FugitiveChanged
" events and only for the tabs visible in the window to prevent hanging.
function! s:gitgutter_update(process, ...) abort
  let bnr = bufnr(a:0 ? a:1 : '')
  let path = fnamemodify(bufname(bnr), ':p')
  if !exists('*gitgutter#process_buffer') | return | endif
  if getbufvar(bnr, 'tabline_filechanged', 0) | return | endif  " use fugitive only
  if a:process
    let async = get(g:, 'gitgutter_async', 0)
    try
      let g:gitgutter_async = 0 | call gitgutter#process_buffer(bnr, 0)
    finally
      let g:gitgutter_async = async
    endtry
  endif
  let stats = getbufvar(bnr, 'gitgutter', {})
  let hunks = copy(get(stats, 'summary', []))  " [added, modified, removed]
  let value = len(filter(hunks, 'v:val')) > 0
  call setbufvar(bnr, 'tabline_unstaged', value)
endfunction

" Assign git variables after FugitiveChanged
" Note: This assigns buffer variables after e.g. FileChangedShell or FugitiveChange
" so that Tabline() can further delay processing until tab needs to be redrawn.
function! s:queue_updates(...) abort
  let repo = FugitiveGitDir()  " repo that was changed
  let base = fnamemodify(repo, ':h')  " remove .git tail
  if empty(repo)
    return
  endif
  let [bnrs, paths] = call('s:tabline_paths', a:000)
  for idx in range(len(bnrs))
    let [bnr, path] = [bnrs[idx], paths[idx]]
    let irepo = getbufvar(bnr, 'git_dir', '')
    if irepo ==# repo || path =~# '^' . base
      call setbufvar(bnr, 'tabline_updated', 0)
    endif
  endfor
endfunction

" Generate tabline colors
" Note: This is needed for GUI vim color schemes since they do not use cterm codes.
" Also some schemes use named colors so have to convert into hex by appending '#'.
" See: https://vi.stackexchange.com/a/20757/8084
" See: https://stackoverflow.com/a/27870856/4970632
function! s:tabline_color(code, ...) abort
  let group = hlID('Normal')
  let base = synIDattr(group, a:code . '#')
  if empty(base) || base[0] !=# '#'
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
function! s:tabline_paths(...) abort
  let skip = get(g:, 'tabline_skip_filetypes', [])
  let tnrs = a:0 ? a:000 : range(1, tabpagenr('$'))
  let bnrs = [] | let paths = []
  for tnr in tnrs
    let ibnrs = tabpagebuflist(tnr)
    let ipaths = map(copy(ibnrs), "expand('#' . v:val . ':p')")
    let bnr = get(ibnrs, 0, 0)  " default value
    let path = get(ipaths, 0, '')  " default value
    for idx in range(len(ibnrs))
      if ipaths[idx] =~# '^!'
        continue  " skip shell commands e.g. fzf
      elseif index(skip, getbufvar(ibnrs[idx], '&filetype', '')) == -1
        let bnr = ibnrs[idx] | let path = ipaths[idx] | break
      endif
    endfor
    for ibnr in ibnrs  " settabvar() somehow interferes with visual mode iter#scroll
      call setbufvar(ibnr, 'tabline_bufnr', bnr)
    endfor
    call add(bnrs, bnr)
    call add(paths, path)
  endfor
  if a:0 != 1
    return [bnrs, paths]
  else  " scalar result
    return [bnrs[0], paths[0]]
  endif
endfunction

" Generate tabline text
" Note: This fills out the tabline by starting from the current tab then moving
" right-left-right-... until either all tabs are drawn or line is wider than &columns
function! s:tabline_text(...)
  " Initial stuff
  let tnr = tabpagenr()
  let tleft = tnr
  let tright = tnr - 1  " initial value
  let tabstrings = []  " tabline string
  let tabtexts = []  " displayed text
  let process = a:0 ? a:1 : 0  " update gitgutter
  while strwidth(join(tabtexts, '')) <= &columns
    " Get tab number and possibly exit
    if tnr == tleft
      let tright += 1 | let tnr = tright
    else
      let tleft -= 1 | let tnr = tleft
    endif
    if tleft < 1 && tright > tabpagenr('$')
      break
    elseif tnr == tright && tright > tabpagenr('$')
      continue  " possibly more tabs to the left
    elseif tnr == tleft && tleft < 1
      continue  " possibly more tabs to the right
    endif

    " Get truncated tab text and set variable
    let [bnr, path] = s:tabline_paths(tnr)
    let blob = '^\x\{33}\(\x\{7}\)$'
    let name = fnamemodify(path, ':t')
    let name = substitute(name, blob, '\1', '')
    let none = empty(name) || name =~# '^!'
    if none  " display filetype instead of path
      let name = getbufvar(bnr, '&filetype', name)
    endif
    if len(name) - 2 > g:tabline_maxlength
      let offset = len(name) - g:tabline_maxlength
      let offset += (offset % 2 == 1)
      let part = strcharpart(name, offset / 2, g:tabline_maxlength)
      let name = '·' . part . '·'
    endif

    " Add flags indicating file and repo status
    let flags = []
    let changed = !none && getbufvar(bnr, 'tabline_filechanged', 0)
    let updated = none || getbufvar(bnr, 'tabline_updated', 1)
    if !none && !updated && process
      let both = changed || !exists('*gitgutter#process_buffer')
      call s:gitgutter_update(process, bnr)  " exits early if b:tabline_filechanged
      call s:fugitive_update(both, bnr)  " also update unstaged status if file changed
      call setbufvar(bnr, 'tabline_updated', 1)
    endif
    let modified = !none && getbufvar(bnr, '&modified', 0)
    let unstaged = getbufvar(bnr, 'tabline_unstaged', 0)
    let staged = getbufvar(bnr, 'tabline_staged', 0)
    if modified | call add(flags, '[+]') | endif
    if unstaged | call add(flags, '[~]') | endif
    if staged | call add(flags, '[:]') | endif
    if changed | call add(flags, '[!]') | endif

    " Add to tab text and possibly warn
    let name = empty(name) ? '?' : name
    let group = tnr == tabpagenr() ? '%#TabLineSel#' : '%#TabLine#'
    let suffix = empty(flags) ? '' : join(flags, '') . ' '
    let tabtext = ' ' . tnr . '|' . name . ' ' . suffix
    let tabstring = '%' . tnr . 'T' . group . tabtext
    if tnr == tright
      call add(tabtexts, tabtext)
      call add(tabstrings, tabstring)
    else
      call insert(tabtexts, tabtext)
      call insert(tabstrings, tabstring)
    endif
    if changed && modified
      if !getbufvar(bnr, 'tabline_warnchanged', 0)
        echohl WarningMsg
        echo 'Warning: Modifying buffer that was changed on disk.'
        echohl None
        call setbufvar(bnr, 'tabline_warnchanged', 1)
      endif
    endif
  endwhile

  " Truncate if too long
  let direc = -1  " truncation direction
  let prefix = tleft > 1 ? '···' : ''
  let suffix = tright < tabpagenr('$') ? '···' : ''
  while strwidth(prefix . join(tabtexts, '') . suffix) > &columns
    if direc == 1
      let tabstrings = tabstrings[:-2]
      let tabtexts = tabtexts[:-2]
      let suffix = '···'
    else
      let tabstrings = tabstrings[1:]
      let tabtexts = tabtexts[1:]
      let prefix = '···'
    endif
    let direc *= -1
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
