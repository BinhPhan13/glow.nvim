---@type integer win id
local win

---@type integer buffer id
local buf

---@type string tmp file path
local tmpfile

---@type function? stops the current cancelable (float) glow render
local current_job_stop

-- types
---@alias border 'shadow' | 'none' | 'double' | 'rounded' | 'solid' | 'single' | 'rounded'
---@alias style 'dark' | 'light'

---@class Glow
local glow = {}

---@class Config
---@field glow_path string glow executable path
---@field install_path string glow binary installation path
---@field border border floating window border style
---@field style style floating window style
---@field pager boolean display output in pager style
---@field width integer floating window width
---@field height integer floating window height
-- default configurations
local config = {
  glow_path = vim.fn.exepath("glow"),
  install_path = vim.env.HOME .. "/.local/bin",
  border = "shadow",
  style = vim.o.background,
  pager = false,
  width = 100,
  height = 100,
}

-- default configs
glow.config = config

local function cleanup()
  if tmpfile ~= nil then
    vim.fn.delete(tmpfile)
  end
end

local function err(msg)
  vim.notify(msg, vim.log.levels.ERROR, { title = "glow" })
end

local function safe_close(h)
  if not h:is_closing() then
    h:close()
  end
end

local function stop_job()
  if current_job_stop ~= nil then
    current_job_stop()
    current_job_stop = nil
  end
end

local function close_window()
  stop_job()
  cleanup()
  vim.api.nvim_win_close(win, true)
end

---@return string
local function tmp_file()
  local output = vim.api.nvim_buf_get_lines(0, 0, vim.api.nvim_buf_line_count(0), false)
  if vim.tbl_isempty(output) then
    err("buffer is empty")
    return ""
  end
  local tmp = vim.fn.tempname() .. ".md"
  vim.fn.writefile(output, tmp)
  return tmp
end

-- glow disables colors when its stdout is a pipe (not a tty), so force them on.
-- inherit the current environment so glow keeps HOME and the user's real
-- COLORTERM/TERM (which decide the color depth glow emits).
---@return table env list of "KEY=VALUE" strings
local function build_env()
  local env = {}
  for k, v in pairs(vim.fn.environ()) do
    table.insert(env, string.format("%s=%s", k, v))
  end
  table.insert(env, "CLICOLOR_FORCE=1")
  return env
end

-- build glow's argument vector for `file`, wrapped at `width` columns
---@param file string markdown file to render
---@param width integer wrap width passed to glow (-w)
---@param use_pager boolean whether to enable glow's pager (-p)
---@return table cmd_args
local function glow_cmd(file, width, use_pager)
  local cmd_args = { glow.config.glow_path, "-s", glow.config.style }
  if use_pager then
    table.insert(cmd_args, "-p")
  end
  table.insert(cmd_args, "-w")
  table.insert(cmd_args, width)
  table.insert(cmd_args, file)
  return cmd_args
end

-- spawn glow (`cmd_args`) and stream its colored output into a terminal channel
-- on `buf`. `on_done` (optional) runs, scheduled, when glow exits. Returns a
-- self-contained stop() that closes this render's pipes/handle (also called
-- automatically when glow exits), so each render manages its own lifecycle.
---@param buf integer buffer to attach the terminal channel to
---@param cmd_args table glow argument vector (glow_path first)
---@param on_done function? called when the process exits
---@return function stop
local function spawn_glow(buf, cmd_args, on_done)
  -- term to receive data
  local chan = vim.api.nvim_open_term(buf, {})
  local stdout = vim.loop.new_pipe(false)
  local stderr = vim.loop.new_pipe(false)
  local handle
  local stopped = false

  local function stop()
    if stopped then
      return
    end
    stopped = true
    pcall(function()
      stdout:read_stop()
    end)
    safe_close(stdout)
    pcall(function()
      stderr:read_stop()
    end)
    safe_close(stderr)
    if handle ~= nil then
      safe_close(handle)
    end
  end

  -- callback for handling output from process
  local function on_output(read_err, data)
    if read_err then
      err(vim.inspect(read_err))
    end
    if data then
      -- forward raw bytes to the terminal so ANSI escape sequences stay intact;
      -- only normalize line endings to CRLF (splitting the stream here would
      -- break color codes that span read-chunk boundaries). pcall guards against
      -- the buffer/channel being closed mid-render.
      pcall(vim.api.nvim_chan_send, chan, (data:gsub("\r?\n", "\r\n")))
    end
  end

  -- setup and kickoff process
  local cmd = table.remove(cmd_args, 1)
  handle = vim.loop.spawn(cmd, {
    args = cmd_args,
    stdio = { nil, stdout, stderr },
    env = build_env(),
  }, vim.schedule_wrap(function()
    stop()
    if on_done then
      on_done()
    end
  end))
  vim.loop.read_start(stdout, vim.schedule_wrap(on_output))
  vim.loop.read_start(stderr, vim.schedule_wrap(on_output))

  return stop
end

-- open the floating preview window and render `file` into it with glow
---@param file string markdown file to preview
local function open_window(file)
  local width = vim.o.columns
  local height = vim.o.lines
  local height_ratio = glow.config.height_ratio or 0.7
  local width_ratio = glow.config.width_ratio or 0.7
  local win_height = math.ceil(height * height_ratio)
  local win_width = math.ceil(width * width_ratio)
  local row = math.ceil((height - win_height) / 2 - 1)
  local col = math.ceil((width - win_width) / 2)

  if glow.config.width and glow.config.width < win_width then
    win_width = glow.config.width
  end

  if glow.config.height and glow.config.height < win_height then
    win_height = glow.config.height
  end

  local win_opts = {
    style = "minimal",
    relative = "editor",
    width = win_width,
    height = win_height,
    row = row,
    col = col,
    border = glow.config.border,
  }

  -- create preview buffer and set local options
  buf = vim.api.nvim_create_buf(false, true)
  win = vim.api.nvim_open_win(buf, true, win_opts)

  -- options
  vim.api.nvim_win_set_option(win, "winblend", 0)
  vim.api.nvim_buf_set_option(buf, "bufhidden", "wipe")
  vim.api.nvim_buf_set_option(buf, "filetype", "glowpreview")

  -- keymaps
  local keymaps_opts = { silent = true, buffer = buf }
  vim.keymap.set("n", "q", close_window, keymaps_opts)
  vim.keymap.set("n", "<Esc>", close_window, keymaps_opts)

  current_job_stop = spawn_glow(buf, glow_cmd(file, win_width, glow.config.pager), function()
    current_job_stop = nil
    cleanup()
  end)

  if glow.config.pager then
    vim.cmd("startinsert")
  end
end

---@return string
local function release_file_url()
  local os, arch
  local version = "1.5.1"

  -- check pre-existence of required programs
  if vim.fn.executable("curl") == 0 or vim.fn.executable("tar") == 0 then
    err("curl and/or tar are required")
    return ""
  end

  -- local raw_os = jit.os
  local raw_os = vim.loop.os_uname().sysname
  local raw_arch = jit.arch
  local os_patterns = {
    ["Windows"] = "Windows",
    ["Windows_NT"] = "Windows",
    ["Linux"] = "Linux",
    ["Darwin"] = "Darwin",
    ["BSD"] = "Freebsd",
  }

  local arch_patterns = {
    ["x86"] = "i386",
    ["x64"] = "x86_64",
    ["arm"] = "arm7",
    ["arm64"] = "arm64",
  }

  os = os_patterns[raw_os]
  arch = arch_patterns[raw_arch]

  if os == nil or arch == nil then
    err("os not supported or could not be parsed")
    return ""
  end

  -- create the url, filename based on os and arch
  local filename = "glow_" .. os .. "_" .. arch .. (os == "Windows" and ".zip" or ".tar.gz")
  return "https://github.com/charmbracelet/glow/releases/download/v" .. version .. "/" .. filename
end

---@param bufnr integer
---@return boolean
local function is_markdown_buf(bufnr)
  local allowed = { "markdown", "markdown.pandoc", "markdown.gfm", "wiki", "vimwiki", "telekasten" }
  return vim.tbl_contains(allowed, vim.bo[bufnr].filetype)
end

---@return boolean
local function is_md_ft()
  return is_markdown_buf(0)
end

---@return boolean
local function is_md_ext(ext)
  local allowed_exts = { "md", "markdown", "mkd", "mkdn", "mdwn", "mdown", "mdtxt", "mdtext", "rmd", "wiki" }
  if not vim.tbl_contains(allowed_exts, string.lower(ext)) then
    return false
  end
  return true
end

--------------------------------------------------------------------------------
-- Glow preview: :GlowToggle flips the current buffer between the glow-rendered
-- preview (a read-only, colored terminal buffer) and the editable source.
--------------------------------------------------------------------------------

---@class GlowMode
local glow_mode = {
  ---@type table<integer, integer> source buffer -> preview (terminal) buffer
  preview_of = {},
  ---@type table<integer, integer> preview buffer -> source buffer
  source_of = {},
  ---@type table<integer, boolean> source buffers the user toggled preview on for
  enabled = {},
}

-- delete a source buffer's cached preview (so the next show re-renders fresh)
---@param source_buf integer
local function glow_mode_drop(source_buf)
  local preview_buf = glow_mode.preview_of[source_buf]
  if preview_buf then
    glow_mode.source_of[preview_buf] = nil
    glow_mode.preview_of[source_buf] = nil
    if vim.api.nvim_buf_is_valid(preview_buf) then
      pcall(vim.api.nvim_buf_delete, preview_buf, { force = true })
    end
  end
end

-- cursor position of `win` as a 0..1 fraction of `buf`'s line count
---@param win integer
---@param buf integer
---@return number
local function cursor_ratio(win, buf)
  local line = vim.api.nvim_win_get_cursor(win)[1]
  return (line - 1) / math.max(1, vim.api.nvim_buf_line_count(buf) - 1)
end

-- place `win`'s cursor at `ratio` of `buf`'s line count (glow reflows, so this
-- is an approximate mapping, not an exact source->render position)
---@param win integer
---@param buf integer
---@param ratio number
local function set_cursor_ratio(win, buf, ratio)
  if not (vim.api.nvim_win_is_valid(win) and vim.api.nvim_buf_is_valid(buf)) then
    return
  end
  local n = vim.api.nvim_buf_line_count(buf)
  local line = math.max(1, math.min(n, math.floor(ratio * (n - 1) + 0.5) + 1))
  pcall(vim.api.nvim_win_set_cursor, win, { line, 0 })
end

-- render `source_buf` with glow into a (cached) preview terminal buffer and show
-- it in `win`. `on_ready(preview_buf)` fires once the preview is populated.
---@param source_buf integer
---@param win integer
---@param on_ready function? called with the preview buffer once rendered
local function glow_mode_show(source_buf, win, on_ready)
  local preview_buf = glow_mode.preview_of[source_buf]
  local rendering = false

  if not (preview_buf and vim.api.nvim_buf_is_valid(preview_buf)) then
    -- dump source content to a temp file so glow never touches the real file
    local lines = vim.api.nvim_buf_get_lines(source_buf, 0, -1, false)
    local tmp = vim.fn.tempname() .. ".md"
    vim.fn.writefile(lines, tmp)

    -- wrap width = window text area (exclude number/sign/fold gutters)
    local info = vim.fn.getwininfo(win)[1]
    local width = math.max(1, info.width - (info.textoff or 0))

    preview_buf = vim.api.nvim_create_buf(false, true)
    -- "hide" (not "wipe") so the preview survives being swapped out of a window
    vim.api.nvim_buf_set_option(preview_buf, "bufhidden", "hide")
    vim.api.nvim_buf_set_option(preview_buf, "filetype", "glowpreview")
    -- q flips this buffer back to source
    vim.keymap.set("n", "q", function()
      glow.toggle()
    end, { silent = true, buffer = preview_buf, nowait = true })

    -- fire-and-forget render; self-cleans on exit and removes its temp file
    rendering = true
    spawn_glow(preview_buf, glow_cmd(tmp, width, false), function()
      vim.fn.delete(tmp)
      if on_ready then
        -- the terminal keeps painting for a moment after glow exits, so wait
        -- for the line count to settle before mapping the cursor.
        -- ponytail: fixed 20ms poll / 500ms cap, fine for a cursor position
        local last, tries = -1, 0
        local function settle()
          local n = vim.api.nvim_buf_line_count(preview_buf)
          if n == last or tries >= 25 then
            on_ready(preview_buf)
          else
            last, tries = n, tries + 1
            vim.defer_fn(settle, 20)
          end
        end
        settle()
      end
    end)

    glow_mode.preview_of[source_buf] = preview_buf
    glow_mode.source_of[preview_buf] = source_buf
  end

  if vim.api.nvim_win_get_buf(win) ~= preview_buf then
    vim.api.nvim_win_set_buf(win, preview_buf)
  end

  -- cached preview is already populated: run on_ready now
  if on_ready and not rendering then
    on_ready(preview_buf)
  end
end

-- restore the preview when returning to a buffer the user toggled on (nav back
-- to a toggled source shows the source, not its preview, without this)
local function glow_mode_restore()
  local win = vim.api.nvim_get_current_win()
  local b = vim.api.nvim_win_get_buf(win)
  -- already showing a preview, or not one we were asked to preview
  if glow_mode.source_of[b] or not glow_mode.enabled[b] then
    return
  end
  glow_mode_show(b, win)
end

local function run(opts)
  local file

  -- check if glow binary is valid even if filled in config
  if vim.fn.executable(glow.config.glow_path) == 0 then
    err(
      string.format(
        "could not execute glow binary in path=%s . make sure you have the right config",
        glow.config.glow_path
      )
    )
    return
  end

  local filename = opts.fargs[1]

  if filename ~= nil and filename ~= "" then
    -- check file
    file = opts.fargs[1]
    if not vim.fn.filereadable(file) then
      err("error on reading file")
      return
    end

    local ext = vim.fn.fnamemodify(file, ":e")
    if not is_md_ext(ext) then
      err("preview only works on markdown files")
      return
    end
  else
    if not is_md_ft() then
      err("preview only works on markdown files")
      return
    end

    file = tmp_file()
    if file == nil then
      err("error on preview for current buffer")
      return
    end
    tmpfile = file
  end

  stop_job()

  open_window(file)
end

local function install_glow(opts)
  local release_url = release_file_url()
  if release_url == "" then
    return
  end

  local install_path = glow.config.install_path
  local download_command = { "curl", "-sL", "-o", "glow.tar.gz", release_url }
  local extract_command = { "tar", "-zxf", "glow.tar.gz", "-C", install_path }
  local output_filename = "glow.tar.gz"
  ---@diagnostic disable-next-line: missing-parameter
  local binary_path = vim.fn.expand(table.concat({ install_path, "glow" }, "/"))

  -- check for existing files / folders
  if vim.fn.isdirectory(install_path) == 0 then
    vim.loop.fs_mkdir(glow.config.install_path, tonumber("777", 8))
  end

  ---@diagnostic disable-next-line: missing-parameter
  if vim.fn.filereadable(binary_path) == 1 then
    local success = vim.loop.fs_unlink(binary_path)
    if not success then
      err("glow binary could not be removed!")
      return
    end
  end

  -- download and install the glow binary
  local callbacks = {
    on_sterr = vim.schedule_wrap(function(_, data, _)
      local out = table.concat(data, "\n")
      err(out)
    end),
    on_exit = vim.schedule_wrap(function()
      vim.fn.system(extract_command)
      -- remove the archive after completion
      if vim.fn.filereadable(output_filename) == 1 then
        local success = vim.loop.fs_unlink(output_filename)
        if not success then
          err("existing archive could not be removed")
          return
        end
      end
      glow.config.glow_path = binary_path
      run(opts)
    end),
  }
  vim.fn.jobstart(download_command, callbacks)
end

---@return string
local function get_executable()
  if glow.config.glow_path ~= "" then
    return glow.config.glow_path
  end

  return vim.fn.exepath("glow")
end

local function create_autocmds()
  vim.api.nvim_create_user_command("Glow", function(opts)
    glow.execute(opts)
  end, { complete = "file", nargs = "?", bang = true })

  vim.api.nvim_create_user_command("GlowToggle", function()
    glow.toggle()
  end, { desc = "Toggle glow preview for the current buffer" })

  -- re-show the preview for toggled-on buffers when navigating back to them.
  -- BufWinEnter only: fires when a buffer is displayed in a window (the return
  -- case), without the churn WinEnter/BufEnter add while cycling windows.
  local group = vim.api.nvim_create_augroup("GlowMode", { clear = true })
  vim.api.nvim_create_autocmd("BufWinEnter", {
    group = group,
    callback = glow_mode_restore,
  })
end

-- toggle the glow preview for the current buffer (preview <-> source)
glow.toggle = function()
  local win = vim.api.nvim_get_current_win()
  local b = vim.api.nvim_win_get_buf(win)
  local src = glow_mode.source_of[b]
  if src then
    -- showing preview -> back to source, mapping the cursor across
    local ratio = cursor_ratio(win, b)
    glow_mode.enabled[src] = nil
    if vim.api.nvim_buf_is_valid(src) then
      vim.api.nvim_win_set_buf(win, src)
    end
    glow_mode_drop(src)
    set_cursor_ratio(win, src, ratio)
  elseif is_markdown_buf(b) then
    -- showing source -> render preview, mapping the cursor across
    if vim.fn.executable(glow.config.glow_path) == 0 then
      err(string.format("could not execute glow binary in path=%s", glow.config.glow_path))
      return
    end
    local ratio = cursor_ratio(win, b)
    glow_mode.enabled[b] = true
    glow_mode_show(b, win, function(preview_buf)
      set_cursor_ratio(win, preview_buf, ratio)
    end)
  else
    err("glow preview only works on markdown files")
  end
end

---@param params Config? custom config
glow.setup = function(params)
  glow.config = vim.tbl_extend("force", {}, glow.config, params or {})
  create_autocmds()
end

glow.execute = function(opts)
  if vim.version().minor < 8 then
    vim.notify_once("glow.nvim: you must use neovim 0.8 or higher", vim.log.levels.ERROR)
    return
  end

  local current_win = vim.fn.win_getid()
  if current_win == win then
    if opts.bang then
      close_window()
    end
    -- do nothing
    return
  end

  if get_executable() == "" then
    install_glow(opts)
    return
  end

  run(opts)
end

return glow
