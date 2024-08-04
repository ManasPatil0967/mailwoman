local curl = require('plenary.curl')
local popup = require('plenary.popup')
local async = require('plenary.async')

local M = {}

-- Function to validate URL
local function validate_url(url)
    return url:match('^https?://') ~= nil
end

-- Function to validate HTTP method
local function validate_method(method)
    local valid_methods = {GET = true, POST = true, PUT = true, DELETE = true, PATCH = true, HEAD = true, OPTIONS = true}
    return valid_methods[method:upper()]
end

-- Function to parse headers
local function parse_headers(header_string)
    local headers = {}
    for line in header_string:gmatch("[^\r\n]+") do
        local key, value = line:match("^([^:]+):%s*(.+)")
        if key and value then
            headers[key] = value
        end
    end
    return headers
end

-- Function to create a prompt buffer
local function create_prompt_buffer(prompt, callback, validator)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_option(buf, 'buftype', 'prompt')
    vim.fn.prompt_setprompt(buf, prompt)

    local function submit_input()
        local content = vim.api.nvim_buf_get_lines(buf, 0, -1, false)[1]
        content = content:sub(#prompt + 1)
        if validator and not validator(content) then
            print("Invalid input. Please try again.")
            return
        end
        vim.api.nvim_win_close(0, true)
        vim.schedule(function()
            callback(content)
        end)
    end

    vim.api.nvim_create_autocmd("BufLeave", {
        buffer = buf,
        callback = submit_input,
        once = true
    })

    local win = vim.api.nvim_open_win(buf, true, {
        relative = 'editor',
        width = 60,
        height = 1,
        row = 1,
        col = 1,
        style = 'minimal',
        border = 'rounded'
    })

    vim.cmd('startinsert!')

    -- On <Esc> close the buffer, <CR> submit the input
    vim.api.nvim_buf_set_keymap(buf, 'i', '<Esc>', '<Cmd>quit<CR>', { noremap = true, silent = true })
    vim.api.nvim_buf_set_keymap(buf, 'i', '>', '<Cmd>quit<CR>', { noremap = true, silent = true })
end

-- Function to handle user input with validation
local function get_input(prompt, callback, validator)
    create_prompt_buffer(prompt, callback, validator)
end

-- Function to format JSON-like strings
local function format_json_like(str)
  -- This is a very basic formatter and won't handle all cases correctly
  local indent = 0
  local formatted = {}
  for char in str:gmatch(".") do
    if char == "{" or char == "[" then
      table.insert(formatted, char)
      indent = indent + 2
      table.insert(formatted, "\n" .. string.rep(" ", indent))
    elseif char == "}" or char == "]" then
      indent = indent - 2
      table.insert(formatted, "\n" .. string.rep(" ", indent))
      table.insert(formatted, char)
    elseif char == "," then
      table.insert(formatted, char)
      table.insert(formatted, "\n" .. string.rep(" ", indent))
    else
      table.insert(formatted, char)
    end
  end
  return table.concat(formatted)
end

-- Function to display the response in a popup window
local function display_response(response)
  local lines = {}
  table.insert(lines, "Status: " .. response.status)
  table.insert(lines, "Headers:")
  for k, v in pairs(response.headers) do
    table.insert(lines, "  " .. k .. ": " .. v)
  end
  table.insert(lines, "")
  table.insert(lines, "Body:")
  -- Try to format JSON-like response
  local formatted_body = format_json_like(response.body)
  for line in formatted_body:gmatch("[^\r\n]+") do
    table.insert(lines, line)
  end

  local width = math.min(120, vim.o.columns - 4)
  local height = math.min(#lines, vim.o.lines - 4)
  local borderchars = { "─", "│", "─", "│", "╭", "╮", "╯", "╰" }

  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)

  local win_id = popup.create(bufnr, {
    title = "HTTP Response",
    line = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    minwidth = width,
    minheight = height,
    borderchars = borderchars,
  })

  -- Set buffer to modifiable
  vim.api.nvim_buf_set_option(bufnr, 'modifiable', true)

  -- Close the popup when pressing 'q'
  vim.api.nvim_buf_set_keymap(bufnr, 'n', 'q', ':q<CR>', { noremap = true, silent = true })
  -- Allow saving response to file
  vim.api.nvim_buf_set_keymap(bufnr, 'n', 's', ':lua require("mailwoman").save_response()<CR>', { noremap = true, silent = true })
  return bufnr
end

-- Function to save response to file
function M.save_response()
  local bufnr = vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local filename = vim.fn.input("Enter filename to save: ")
  if filename ~= "" then
    vim.fn.writefile(lines, filename)
    print("Response saved to " .. filename)
  end
end

-- Function to encode payload
local function encode(payload)
    if type(payload) == "string" then
        return payload
    elseif type(payload) == "table" then
        return vim.fn.json_encode(payload)
    else
        return tostring(payload)
    end
end

-- Function to make an HTTP request asynchronously
local function make_request(url, method, headers, payload, callback)
    local enc = encode(payload)
    local default_headers = {
        ["User-Agent"] = "Mailwoman/0.1",
        ["Accept"] = "application/json",
        ["Content-Type"] = "application/json"
    }
    async.run(function()
        local response = curl.request({
            url = url,
            method = method,
            headers = headers or default_headers,
            body = enc
        })
        callback(response)
    end)
end
-- Main function to handle the request
function M.send_request()
    local url, method, headers, payload

    get_input("Enter URL: ", function(input)
        url = input
        get_input("Enter method (GET/POST/PUT/DELETE/PATCH/HEAD/OPTIONS): ", function(i)
            method = i:upper()
            get_input("Enter headers (key: value, one per line, empty line to finish):\n", function(x)
                headers = parse_headers(x)
                if method == "POST" or method == "PUT" or method == "PATCH" then
                    get_input("Enter payload: ", function(y)
                        payload = y
                        -- Now we have all inputs, make the request
                        make_request(url, method, headers, payload, display_response)
                    end)
                else
                    make_request(url, method, headers, "", display_response)
                end
            end)
        end, validate_method)
    end, validate_url)
end
-- Set up a command to trigger the plugin
vim.api.nvim_create_user_command("Mailwoman", M.send_request, {})
vim.api.nvim_set_keymap('n', '<leader>mw', ':Mailwoman<CR>', { noremap = true, silent = true })

return M
