# Mailwoman
This is a Neovim plugin to send curl requests right from an UI and see the output.

# Installation
Using packer:
```lua
use { 
    'ManasPatil0967/mailwoman'
    requires = { 
        { 'nvim-lua/plenary.nvim' }
        } 
    }
```
# Keymaps
```vim
nmap <leader>mw :lua require('mailwoman').send_request()<CR>
```
# Usage
- Press the keymap to open the UI.
- Enter the URL, method, headers and body. For each input, press > to submit and move to the next input.
- At last > will send the request and show the output in a new buffer.
- Press q to close the output buffer. Press s to save the output buffer to a file.
