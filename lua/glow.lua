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
    if stdout ~= nil then
      pcall(function()
        stdout:read_stop()
      end)
      safe_close(stdout)
    end
    if stderr ~= nil then
      pcall(function()
        stderr:read_stop()
      end)
      safe_close(stderr)
    end
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

---@return boolean
local function is_md_ft()
  local allowed_fts = { "markdown", "markdown.pandoc", "markdown.gfm", "wiki", "vimwiki", "telekasten" }
  if not vim.tbl_contains(allowed_fts, vim.bo.filetype) then
    return false
  end
  return true
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
-- Glow mode: a global toggle (:GlowToggle). While enabled, every markdown
-- buffer shown in a window is rendered with glow (a read-only, colored preview);
-- non-markdown buffers are left untouched. To edit, toggle glow mode off, edit,
-- then toggle it back on.
--------------------------------------------------------------------------------

---@class GlowMode
local glow_mode = {
  enabled = false,
  ---@type table<integer, integer> source buffer -> preview (terminal) buffer
  preview_of = {},
  ---@type table<integer, integer> preview buffer -> source buffer
  source_of = {},
  ---@type integer? autocmd group id
  augroup = nil,
}

---@param bufnr integer
---@return boolean
local function is_markdown_buf(bufnr)
  local allowed = { "markdown", "markdown.pandoc", "markdown.gfm", "wiki", "vimwiki", "telekasten" }
  return vim.tbl_contains(allowed, vim.bo[bufnr].filetype)
end

-- render `source_buf` with glow into a (cached) preview terminal buffer and show
-- it in `win`
---@param source_buf integer
---@param win integer
local function glow_mode_show(source_buf, win)
  local preview_buf = glow_mode.preview_of[source_buf]

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
    -- q is a convenient way to turn glow mode back off
    vim.keymap.set("n", "q", function()
      glow.toggle()
    end, { silent = true, buffer = preview_buf, nowait = true })

    -- fire-and-forget render; self-cleans on exit and removes its temp file
    spawn_glow(preview_buf, glow_cmd(tmp, width, false), function()
      vim.fn.delete(tmp)
    end)

    glow_mode.preview_of[source_buf] = preview_buf
    glow_mode.source_of[preview_buf] = source_buf
  end

  if vim.api.nvim_win_get_buf(win) ~= preview_buf then
    vim.api.nvim_win_set_buf(win, preview_buf)
  end
end

-- if the current window shows a markdown source buffer, render it with glow
local function glow_mode_refresh_current_win()
  if not glow_mode.enabled then
    return
  end
  local win = vim.api.nvim_get_current_win()
  local b = vim.api.nvim_win_get_buf(win)
  -- skip our own preview buffers (avoids any re-entrancy)
  if glow_mode.source_of[b] then
    return
  end
  if is_markdown_buf(b) then
    glow_mode_show(b, win)
  end
end

local function glow_mode_enable()
  if glow_mode.enabled then
    return
  end
  if vim.fn.executable(glow.config.glow_path) == 0 then
    err(string.format("could not execute glow binary in path=%s", glow.config.glow_path))
    return
  end

  glow_mode.enabled = true
  local group = vim.api.nvim_create_augroup("GlowMode", { clear = true })
  glow_mode.augroup = group

  -- render markdown buffers as they are shown in a window
  vim.api.nvim_create_autocmd({ "BufWinEnter", "WinEnter", "BufEnter" }, {
    group = group,
    callback = glow_mode_refresh_current_win,
  })

  -- render markdown buffers already visible right now
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local b = vim.api.nvim_win_get_buf(win)
    if is_markdown_buf(b) and not glow_mode.source_of[b] then
      glow_mode_show(b, win)
    end
  end
end

local function glow_mode_disable()
  if not glow_mode.enabled then
    return
  end
  glow_mode.enabled = false
  if glow_mode.augroup then
    pcall(vim.api.nvim_del_augroup_by_id, glow_mode.augroup)
    glow_mode.augroup = nil
  end

  -- restore the source buffer in any window currently showing a preview
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_is_valid(win) then
      local b = vim.api.nvim_win_get_buf(win)
      local src = glow_mode.source_of[b]
      if src and vim.api.nvim_buf_is_valid(src) then
        vim.api.nvim_win_set_buf(win, src)
      end
    end
  end

  -- drop all preview buffers
  for _, preview_buf in pairs(glow_mode.preview_of) do
    if vim.api.nvim_buf_is_valid(preview_buf) then
      pcall(vim.api.nvim_buf_delete, preview_buf, { force = true })
    end
  end
  glow_mode.preview_of = {}
  glow_mode.source_of = {}
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
  print("hello")
  vim.api.nvim_create_user_command("Glow", function(opts)
    glow.execute(opts)
  end, { complete = "file", nargs = "?", bang = true })

  vim.api.nvim_create_user_command("GlowToggle", function()
    glow.toggle()
  end, { desc = "Toggle glow mode: render every markdown buffer with glow" })
end

-- toggle glow mode: while on, every markdown buffer is rendered with glow
glow.toggle = function()
  if glow_mode.enabled then
    glow_mode_disable()
  else
    glow_mode_enable()
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
