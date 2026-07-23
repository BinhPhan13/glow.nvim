<h1 align="center">
  <img src="https://i.postimg.cc/Y9Z030zC/glow-nvim.jpg" />
</h1>

<div align="center">
  <p>
    <strong>Preview markdown code directly in your neovim terminal</strong><br/>
    <small>Powered by charm's <a href="https://github.com/charmbracelet/glow">glow</a></small>
  </p>
  <img src="https://img.shields.io/badge/Made%20with%20Lua-blueviolet.svg?style=for-the-badge&logo=lua" />
</div>

https://user-images.githubusercontent.com/178641/215353259-eb8688fb-5600-4b95-89a2-0f286e3b6441.mp4

> A maintained fork of [ellisonleao/glow.nvim](https://github.com/ellisonleao/glow.nvim) (now archived).
>
> On top of the original floating-window preview, this fork adds:
> - **`:GlowToggle`** — render the current markdown buffer in place, flipping between preview and source (per buffer)
> - cursor position kept across the preview/source flip
> - forced glow colors in the preview (glow drops color when its output is piped)

## Prerequisites

- Neovim 0.8+

## Installing

- [vim-plug](https://github.com/junegunn/vim-plug)

```
Plug 'BinhPhan13/glow.nvim'
lua << EOF
require('glow').setup()
EOF
```

- [packer.nvim](https://github.com/wbthomason/packer.nvim)

```lua
use {"BinhPhan13/glow.nvim", config = function() require("glow").setup() end}
```

- [lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
{"BinhPhan13/glow.nvim", config = true, cmd = { "Glow", "GlowToggle" }}
```

## Setup

The script comes with the following defaults:

```lua
{
  glow_path = "", -- will be filled automatically with your glow bin in $PATH, if any
  install_path = "~/.local/bin", -- default path for installing glow binary
  border = "shadow", -- floating window border config
  style = "dark|light", -- filled automatically with your current editor background, you can override using glow json style
  pager = false,
  width = 80,
  height = 100,
  width_ratio = 0.7, -- maximum width of the Glow window compared to the nvim window size (overrides `width`)
  height_ratio = 0.7,
}
```

To override the custom configuration, call:

```lua
require('glow').setup({
  -- your override config
})
```

Example:

```lua
require('glow').setup({
  style = "dark",
  width = 120,
})
```

## Usage

### Preview file

```
:Glow [path-to-md-file]
```

### Preview current buffer

```
:Glow
```

### Close window

```
:Glow!
```

You can also close the floating window using `q` or `<Esc>` keys

### Toggle preview in place

```
:GlowToggle
```

Flips the current markdown buffer between the glow-rendered preview (a read-only,
colored view) and the editable source. `q` in a preview flips it back to source.
Your cursor position is kept (approximately) across the flip.
