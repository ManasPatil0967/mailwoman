local curl = require('plenary.curl')
local popup = require('plenary.popup')
local async = require('plenary.async')
local Path = require('plenary.path')

local M = {}
M.history = {}
M.active_request = nil
M.env_variables = {}
M.current_response = nil
M.request_chains = {}

-- UI Constants
local COLORS = {
  SUCCESS = "DiagnosticOk",
  REDIRECT = "DiagnosticWarn",
  ERROR = "DiagnosticError",
  INFO = "DiagnosticInfo",
  HEADER = "Title",
  BORDER = "FloatBorder"
}

-- Create status line component
function M.status_component()
  if M.active_request then
    return " 󰖟 API Request Running"
  end
  return ""
end

local function validate_url(url)
  return url:match('^https?://') ~= nil
end

local function validate_method(method)
  local valid_methods = {GET = true, POST = true, PUT = true, DELETE = true, PATCH = true, HEAD = true, OPTIONS = true}
  return valid_methods[method:upper()]
end

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

-- Enhanced buffer with floating window and better UI
local function create_enhanced_buffer(opts)
  opts = opts or {}
  local title = opts.title or "Mailwoman"
  local content = opts.content or {}
  local width = opts.width or math.floor(vim.o.columns * 0.8)
  local height = opts.height or math.floor(vim.o.lines * 0.8)
  local callback = opts.callback
  local syntax = opts.syntax
  local enter = opts.enter ~= false
  local on_exit = opts.on_exit
  
  local bufnr = vim.api.nvim_create_buf(false, true)
  
  -- Set content
  if type(content) == "string" then
    content = vim.split(content, "\n")
  end
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, content)
  
  if syntax then
    vim.api.nvim_buf_set_option(bufnr, 'syntax', syntax)
  end
  
  -- Create window
  local win_opts = {
    title = title,
    line = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    minwidth = width,
    minheight = height,
    borderchars = { "─", "│", "─", "│", "╭", "╮", "╯", "╰" },
  }
  
  local win_id = popup.create(bufnr, win_opts)
  
  -- Set modifiable based on options
  vim.api.nvim_buf_set_option(bufnr, 'modifiable', opts.modifiable ~= false)
  
  -- Add keymaps
  local keymap_opts = { noremap = true, silent = true }
  vim.api.nvim_buf_set_keymap(bufnr, 'n', 'q', ':close<CR>', keymap_opts)
  vim.api.nvim_buf_set_keymap(bufnr, 'n', '<Esc>', ':close<CR>', keymap_opts)
  
  -- Add resizing keymaps
  vim.api.nvim_buf_set_keymap(bufnr, 'n', '+', ':lua require("mailwoman").resize_window(5)<CR>', keymap_opts)
  vim.api.nvim_buf_set_keymap(bufnr, 'n', '-', ':lua require("mailwoman").resize_window(-5)<CR>', keymap_opts)
  
  if opts.fold then
    vim.api.nvim_buf_set_keymap(bufnr, 'n', 'za', ':lua require("mailwoman").toggle_fold()<CR>', keymap_opts)
    vim.api.nvim_buf_set_keymap(bufnr, 'n', 'zo', ':lua require("mailwoman").open_fold()<CR>', keymap_opts)
    vim.api.nvim_buf_set_keymap(bufnr, 'n', 'zc', ':lua require("mailwoman").close_fold()<CR>', keymap_opts)
  end
  
  if callback then
    callback(bufnr, win_id)
  end
  
  -- Set focus if required
  if not enter then
    vim.api.nvim_set_current_win(0)
  end
  
  -- Handle exit
  if on_exit then
    vim.api.nvim_create_autocmd({"BufWipeout", "BufDelete"}, {
      buffer = bufnr,
      callback = function()
        on_exit(bufnr)
      end,
      once = true
    })
  end
  
  return {
    bufnr = bufnr,
    win_id = win_id
  }
end

-- Form-like input buffer
local function create_form_buffer(fields, callback)
  local form_data = {}
  local field_order = {}
  local max_label_width = 0
  
  -- Calculate padding for all fields
  for _, field in ipairs(fields) do
    table.insert(field_order, field.id)
    max_label_width = math.max(max_label_width, #field.label)
  end
  
  local content = {}
  for _, field in ipairs(fields) do
    local padding = string.rep(" ", max_label_width - #field.label)
    local default = field.default or ""
    table.insert(content, field.label .. padding .. ": " .. default)
    form_data[field.id] = {
      value = default,
      line = #content,
      start = #field.label + padding + 2,
      validator = field.validator
    }
  end
  
  table.insert(content, "")
  table.insert(content, "[Submit] (press Enter)  [Cancel] (press Esc)")
  
  local buf_data = create_enhanced_buffer({
    title = "Mailwoman Form",
    content = content,
    width = 80,
    height = #content + 1,
    modifiable = true,
    callback = function(bufnr)
      -- Add form editing support
      for id, field in pairs(form_data) do
        vim.api.nvim_create_autocmd({"TextChanged", "TextChangedI"}, {
          buffer = bufnr,
          callback = function()
            local line = vim.api.nvim_buf_get_lines(bufnr, field.line - 1, field.line, false)[1]
            field.value = line:sub(field.start)
          end
        })
      end
      
      -- Handle form navigation with Tab
      vim.api.nvim_buf_set_keymap(bufnr, 'i', '<Tab>', '<Esc>:lua require("mailwoman").next_field()<CR>', { noremap = true, silent = true })
      vim.api.nvim_buf_set_keymap(bufnr, 'i', '<S-Tab>', '<Esc>:lua require("mailwoman").prev_field()<CR>', { noremap = true, silent = true })
      
      -- Handle submission
      vim.api.nvim_buf_set_keymap(bufnr, 'n', '<CR>', ':lua require("mailwoman").submit_form()<CR>', { noremap = true, silent = true })
      vim.api.nvim_buf_set_keymap(bufnr, 'i', '<C-CR>', '<Esc>:lua require("mailwoman").submit_form()<CR>', { noremap = true, silent = true })
      
      -- Position cursor at the first field
      vim.api.nvim_win_set_cursor(0, {1, form_data[field_order[1]].start})
      vim.cmd('startinsert')
    end
  })
  
  -- Store form data for later
  M.current_form = {
    bufnr = buf_data.bufnr,
    win_id = buf_data.win_id,
    fields = form_data,
    field_order = field_order,
    current_field = 1,
    callback = callback
  }
  
  return buf_data
end

-- Navigate form fields
function M.next_field()
  if not M.current_form then return end
  
  M.current_form.current_field = M.current_form.current_field + 1
  if M.current_form.current_field > #M.current_form.field_order then
    M.current_form.current_field = 1
  end
  
  local field_id = M.current_form.field_order[M.current_form.current_field]
  local field = M.current_form.fields[field_id]
  vim.api.nvim_win_set_cursor(0, {field.line, field.start})
  vim.cmd('startinsert')
end

function M.prev_field()
  if not M.current_form then return end
  
  M.current_form.current_field = M.current_form.current_field - 1
  if M.current_form.current_field < 1 then
    M.current_form.current_field = #M.current_form.field_order
  end
  
  local field_id = M.current_form.field_order[M.current_form.current_field]
  local field = M.current_form.fields[field_id]
  vim.api.nvim_win_set_cursor(0, {field.line, field.start})
  vim.cmd('startinsert')
end

function M.submit_form()
  if not M.current_form then return end
  
  local values = {}
  local invalid_fields = {}
  
  -- Collect and validate all field values
  for id, field in pairs(M.current_form.fields) do
    values[id] = field.value
    if field.validator and not field.validator(field.value) then
      table.insert(invalid_fields, id)
    end
  end
  
  -- If any validation errors, highlight the first invalid field
  if #invalid_fields > 0 then
    local field = M.current_form.fields[invalid_fields[1]]
    vim.api.nvim_win_set_cursor(0, {field.line, field.start})
    vim.cmd('startinsert')
    vim.api.nvim_echo({{string.format("Invalid input for field '%s'", invalid_fields[1]), "ErrorMsg"}}, true, {})
    return
  end
  
  -- Close the form window
  vim.api.nvim_win_close(M.current_form.win_id, true)
  
  -- Call the callback with form values
  local callback = M.current_form.callback
  M.current_form = nil
  callback(values)
end

local function format_json_like(str)
  -- Try to parse as JSON first
  local success, parsed = pcall(vim.fn.json_decode, str)
  if success then
    return vim.fn.json_encode(parsed)
  end

  -- Otherwise, do simple formatting
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

-- Apply the appropriate highlight based on status code
local function get_status_highlight(status)
  local status_num = tonumber(status)
  if status_num >= 200 and status_num < 300 then
    return COLORS.SUCCESS
  elseif status_num >= 300 and status_num < 400 then
    return COLORS.REDIRECT
  elseif status_num >= 400 then
    return COLORS.ERROR
  else
    return COLORS.INFO
  end
end

-- Enhanced response display
local function display_response(response)
  M.active_request = nil
  M.current_response = response
  local lines = {}
  
  -- Format status with highlighting
  local status_line = "Status: " .. response.status
  table.insert(lines, status_line)
  
  -- Add headers
  table.insert(lines, "Headers:")
  for k, v in pairs(response.headers) do
    table.insert(lines, "  " .. k .. ": " .. v)
  end
  
  -- Add body
  table.insert(lines, "")
  table.insert(lines, "Body:")
  
  -- Format response body based on Content-Type
  local content_type = response.headers["content-type"] or response.headers["Content-Type"] or ""
  local body_lines = {}
  
  if content_type:find("application/json") then
    local formatted_body = format_json_like(response.body)
    for line in formatted_body:gmatch("[^\r\n]+") do
      table.insert(body_lines, line)
    end
  else
    for line in response.body:gmatch("[^\r\n]+") do
      table.insert(body_lines, line)
    end
  end
  
  -- Add body lines
  for _, line in ipairs(body_lines) do
    table.insert(lines, line)
  end
  
  local buf_data = create_enhanced_buffer({
    title = "HTTP Response",
    content = lines,
    modifiable = false,
    fold = true,
    callback = function(bufnr)
      -- Highlight the status line based on status code
      local ns_id = vim.api.nvim_create_namespace("MailwomanHighlight")
      vim.api.nvim_buf_add_highlight(bufnr, ns_id, get_status_highlight(response.status), 0, 0, -1)
      
      -- Add response export options
      vim.api.nvim_buf_set_keymap(bufnr, 'n', 's', ':lua require("mailwoman").save_response()<CR>', { noremap = true, silent = true })
      vim.api.nvim_buf_set_keymap(bufnr, 'n', 'v', ':lua require("mailwoman").toggle_view_mode()<CR>', { noremap = true, silent = true })
      vim.api.nvim_buf_set_keymap(bufnr, 'n', 'e', ':lua require("mailwoman").extract_value()<CR>', { noremap = true, silent = true })
      
      -- Add status line for headers
      vim.api.nvim_buf_add_highlight(bufnr, ns_id, COLORS.HEADER, 1, 0, -1)
      
      -- Set JSON syntax highlighting for formatted JSON
      if content_type:find("application/json") then
        vim.api.nvim_buf_set_option(bufnr, 'syntax', 'json')
      end
    end
  })
  
  M.response_buf = buf_data.bufnr
  M.response_win = buf_data.win_id
  
  -- Add to history
  table.insert(M.history, {
    url = M.last_request.url,
    method = M.last_request.method,
    headers = M.last_request.headers,
    body = M.last_request.body,
    response = response
  })
  
  return buf_data.bufnr
end

-- Toggle between formatted and raw response view
function M.toggle_view_mode()
  if not M.current_response then return end
  
  M.raw_view = not M.raw_view
  local content
  
  if M.raw_view then
    content = {M.current_response.body}
  else
    -- Recreate the formatted view
    content = {"Status: " .. M.current_response.status, "Headers:"}
    for k, v in pairs(M.current_response.headers) do
      table.insert(content, "  " .. k .. ": " .. v)
    end
    table.insert(content, "")
    table.insert(content, "Body:")
    
    local content_type = M.current_response.headers["content-type"] or M.current_response.headers["Content-Type"] or ""
    if content_type:find("application/json") then
      local formatted_body = format_json_like(M.current_response.body)
      for line in formatted_body:gmatch("[^\r\n]+") do
        table.insert(content, line)
      end
    else
      for line in M.current_response.body:gmatch("[^\r\n]+") do
        table.insert(content, line)
      end
    end
  end
  
  vim.api.nvim_buf_set_option(M.response_buf, 'modifiable', true)
  vim.api.nvim_buf_set_lines(M.response_buf, 0, -1, false, content)
  vim.api.nvim_buf_set_option(M.response_buf, 'modifiable', false)
  
  -- Update title
  local title = M.raw_view and "HTTP Response (Raw)" or "HTTP Response (Formatted)"
  vim.api.nvim_buf_set_name(M.response_buf, title)
end

-- Window resizing
function M.resize_window(amount)
  local win_id = vim.api.nvim_get_current_win()
  local height = vim.api.nvim_win_get_height(win_id)
  local width = vim.api.nvim_win_get_width(win_id)
  
  vim.api.nvim_win_set_height(win_id, height + amount)
  vim.api.nvim_win_set_width(win_id, width + amount)
end

-- Simple folding for JSON responses
function M.toggle_fold()
  local line = vim.api.nvim_win_get_cursor(0)[1]
  local content = vim.api.nvim_buf_get_lines(0, line - 1, line, false)[1]
  
  if content:match("{") or content:match("%[") then
    M.close_fold()
  else
    M.open_fold()
  end
end

function M.close_fold()
  local line = vim.api.nvim_win_get_cursor(0)[1]
  local content = vim.api.nvim_buf_get_lines(0, line - 1, line, false)[1]
  
  if content:match("{") or content:match("%[") then
    local nest_level = 0
    local end_line = line
    local max_lines = vim.api.nvim_buf_line_count(0)
    
    for i = line, max_lines do
      local current = vim.api.nvim_buf_get_lines(0, i - 1, i, false)[1]
      for c in current:gmatch(".") do
        if c == "{" or c == "[" then
          nest_level = nest_level + 1
        elseif c == "}" or c == "]" then
          nest_level = nest_level - 1
          if nest_level == 0 then
            end_line = i
            break
          end
        end
      end
      
      if nest_level == 0 then
        break
      end
    end
    
    -- Create a fold
    vim.api.nvim_buf_set_option(0, 'modifiable', true)
    local fold_content = content .. " ... " .. vim.api.nvim_buf_get_lines(0, end_line - 1, end_line, false)[1]
    vim.api.nvim_buf_set_lines(0, line - 1, end_line, false, {fold_content})
    vim.api.nvim_buf_set_option(0, 'modifiable', false)
  end
end

function M.open_fold()
  local line = vim.api.nvim_win_get_cursor(0)[1]
  local content = vim.api.nvim_buf_get_lines(0, line - 1, line, false)[1]
  
  if content:match(" ... ") then
    -- This is a folded line, unfold it
    -- For simplicity, we'll just reload the response
    M.toggle_view_mode()
    M.toggle_view_mode()
  end
end

function M.extract_value()
  if not M.current_response then return end
  
  create_form_buffer({
    {id = "jsonpath", label = "JSON Path", default = "$."},
    {id = "name", label = "Variable Name", default = "response_value"}
  }, function(values)
    -- Try to extract the value from response
    local path = values.jsonpath
    local var_name = values.name
    
    -- Simple path parser for demonstration
    local success, parsed = pcall(vim.fn.json_decode, M.current_response.body)
    if not success then
      vim.api.nvim_echo({{"Failed to parse response as JSON", "ErrorMsg"}}, true, {})
      return
    end
    
    -- Very basic path handling (would need a full JSONPath implementation)
    local value = parsed
    if path ~= "$" and path ~= "$." then
      -- Strip $ prefix
      path = path:gsub("^%$%.", "")
      
      -- Split by dots
      for part in path:gmatch("[^%.]+") do
        -- Handle array indexing
        local array_index = part:match("%[(%d+)%]")
        if array_index then
          local array_name = part:match("([^%[]+)")
          value = value[array_name]
          value = value[tonumber(array_index)]
        else
          value = value[part]
        end
        
        if value == nil then
          vim.api.nvim_echo({{"Path not found in response", "ErrorMsg"}}, true, {})
          return
        end
      end
    end
    
    -- Store the extracted value
    M.env_variables[var_name] = value
    
    -- Show success message
    vim.api.nvim_echo({{"Extracted value to variable '" .. var_name .. "'", ""}}, true, {})
    
    -- If this is part of a chain, continue to the next request
    if M.current_chain and M.current_chain.current_index < #M.current_chain.requests then
      M.continue_chain()
    end
  end)
end

function M.save_response()
  if not M.current_response then return end
  
  create_form_buffer({
    {id = "filename", label = "Filename", default = "response.json"}
  }, function(values)
    local filename = values.filename
    if filename ~= "" then
      local file = io.open(filename, "w")
      if file then
        file:write(M.current_response.body)
        file:close()
        vim.api.nvim_echo({{"Response saved to " .. filename, ""}}, true, {})
      else
        vim.api.nvim_echo({{"Failed to save file", "ErrorMsg"}}, true, {})
      end
    end
  end)
end

local function encode(payload)
  if type(payload) == "string" then
    return payload
  elseif type(payload) == "table" then
    return vim.fn.json_encode(payload)
  else
    return tostring(payload)
  end
end

-- Process template strings with environment variables
local function process_template(template)
  if type(template) ~= "string" then
    return template
  end
  
  return (template:gsub("{{([^}]+)}}", function(var_name)
    local val = M.env_variables[var_name]
    if val ~= nil then
      if type(val) == "table" then
        return vim.fn.json_encode(val)
      else
        return tostring(val)
      end
    end
    return "{{" .. var_name .. "}}"
  end))
end

local function make_request(request, callback)
  local url = process_template(request.url)
  local method = request.method
  local headers = request.headers or {
    ["User-Agent"] = "Mailwoman/0.2",
    ["Accept"] = "application/json",
    ["Content-Type"] = "application/json"
  }
  local payload = process_template(request.body or "")
  
  -- Process headers for template variables
  for k, v in pairs(headers) do
    headers[k] = process_template(v)
  end
  
  -- Store the request for history
  M.last_request = {
    url = url,
    method = method,
    headers = headers,
    body = payload
  }
  
  -- Set active request flag
  M.active_request = {
    started = os.time()
  }
  
  -- Update status line
  vim.cmd("redrawstatus")
  
  local enc = encode(payload)
  async.run(function()
    local response = curl.request({
      url = url,
      method = method,
      headers = headers,
      body = enc
    })
    
    callback(response)
    vim.cmd("redrawstatus")
  end)
end

-- Chain request execution
function M.create_chain()
  create_form_buffer({
    {id = "name", label = "Chain Name", default = "my_chain"}
  }, function(values)
    local chain_name = values.name
    
    -- Create a new chain
    M.request_chains[chain_name] = {
      name = chain_name,
      requests = {}
    }
    
    vim.api.nvim_echo({{"Created request chain '" .. chain_name .. "'", ""}}, true, {})
    
    -- Open chain management UI
    M.manage_chain(chain_name)
  end)
end

function M.manage_chain(chain_name)
  local chain = M.request_chains[chain_name]
  if not chain then
    vim.api.nvim_echo({{"Chain not found", "ErrorMsg"}}, true, {})
    return
  end
  
  local content = {"Request Chain: " .. chain_name, ""}
  
  -- List all requests in the chain
  for i, req in ipairs(chain.requests) do
    table.insert(content, string.format("%d. %s %s", i, req.method, req.url))
  end
  
  table.insert(content, "")
  table.insert(content, "[a] Add Request  [d] Delete Request  [r] Run Chain  [e] Edit Request")
  
  create_enhanced_buffer({
    title = "Chain Manager",
    content = content,
    modifiable = false,
    callback = function(bufnr)
      -- Add action keymaps
      vim.api.nvim_buf_set_keymap(bufnr, 'n', 'a', string.format(':lua require("mailwoman").add_chain_request("%s")<CR>', chain_name), { noremap = true, silent = true })
      vim.api.nvim_buf_set_keymap(bufnr, 'n', 'd', string.format(':lua require("mailwoman").delete_chain_request("%s")<CR>', chain_name), { noremap = true, silent = true })
      vim.api.nvim_buf_set_keymap(bufnr, 'n', 'r', string.format(':lua require("mailwoman").run_chain("%s")<CR>', chain_name), { noremap = true, silent = true })
      vim.api.nvim_buf_set_keymap(bufnr, 'n', 'e', string.format(':lua require("mailwoman").edit_chain_request("%s")<CR>', chain_name), { noremap = true, silent = true })
    end
  })
end

function M.add_chain_request(chain_name)
  local chain = M.request_chains[chain_name]
  if not chain then return end
  
  create_form_buffer({
    {id = "url", label = "URL", default = "", validator = validate_url},
    {id = "method", label = "Method", default = "GET", validator = validate_method},
    {id = "headers", label = "Headers", default = "Content-Type: application/json"},
    {id = "body", label = "Body", default = ""},
    {id = "extract_path", label = "Extract Path", default = ""},
    {id = "extract_var", label = "Save to Variable", default = ""}
  }, function(values)
    local headers = parse_headers(values.headers)
    
    -- Add request to chain
    table.insert(chain.requests, {
      url = values.url,
      method = values.method,
      headers = headers,
      body = values.body,
      extract = {
        path = values.extract_path,
        var = values.extract_var
      }
    })
    
    -- Refresh chain management UI
    M.manage_chain(chain_name)
  end)
end

function M.delete_chain_request(chain_name)
  local chain = M.request_chains[chain_name]
  if not chain then return end
  
  create_form_buffer({
    {id = "index", label = "Request Number", default = "1", validator = function(val)
      local num = tonumber(val)
      return num and num > 0 and num <= #chain.requests
    end}
  }, function(values)
    local index = tonumber(values.index)
    
    -- Remove the request
    table.remove(chain.requests, index)
    
    -- Refresh chain management UI
    M.manage_chain(chain_name)
  end)
end

function M.edit_chain_request(chain_name)
  local chain = M.request_chains[chain_name]
  if not chain then return end
  
  create_form_buffer({
    {id = "index", label = "Request Number", default = "1", validator = function(val)
      local num = tonumber(val)
      return num and num > 0 and num <= #chain.requests
    end}
  }, function(values)
    local index = tonumber(values.index)
    local request = chain.requests[index]
    
    -- Convert headers to string format
    local headers_str = ""
    for k, v in pairs(request.headers) do
      headers_str = headers_str .. k .. ": " .. v .. "\n"
    end
    
    -- Create form to edit the request
    create_form_buffer({
      {id = "url", label = "URL", default = request.url, validator = validate_url},
      {id = "method", label = "Method", default = request.method, validator = validate_method},
      {id = "headers", label = "Headers", default = headers_str},
      {id = "body", label = "Body", default = request.body or ""},
      {id = "extract_path", label = "Extract Path", default = request.extract and request.extract.path or ""},
      {id = "extract_var", label = "Save to Variable", default = request.extract and request.extract.var or ""}
  }, function(edit_values)
      -- Update the request with new values
      request.url = edit_values.url
      request.method = edit_values.method
      request.headers = parse_headers(edit_values.headers)
      request.body = edit_values.body
      request.extract = {
          path = edit_values.extract_path,
          var = edit_values.extract_var
      }
      -- Refresh chain management UI
      M.manage_chain(chain_name)
  end)

end)
end

function M.run_chain(chain_name)
    local chain = M.request_chains[chain_name]
    if not chain then return end

    -- Initialize chain execution state
    M.current_chain = {
        name = chain_name,
        requests = chain.requests,
        current_index = 1
    }

    -- Start the chain
    M.continue_chain()
end

function M.continue_chain()
    if not M.current_chain then return end

    local chain = M.current_chain
    local request = chain.requests[chain.current_index]

    -- Make the request
    make_request(request, function(response)
        -- Display the response
        display_response(response)
        -- If there's an extraction path, extract the value
        if request.extract and request.extract.path ~= "" then
            M.extract_value()
        else
            -- Move to the next request in the chain
            chain.current_index = chain.current_index + 1
            if chain.current_index <= #chain.requests then
                M.continue_chain()
            else
                -- Chain completed
                vim.api.nvim_echo({{"Chain '" .. chain.name .. "' completed", ""}}, true, {})
                M.current_chain = nil
            end
        end
    end)
end

function M.open_ui()
  -- Create a menu for the user to choose an action
  local actions = {
    "Create New Chain",
    "Manage Existing Chains",
    "Run a Chain",
    "View History",
    "Exit"
  }

  -- Display the menu in a floating window
  create_enhanced_buffer({
    title = "Mailwoman - API Testing",
    content = actions,
    modifiable = false,
    callback = function(bufnr)
      -- Add keymaps for selecting an action
      vim.api.nvim_buf_set_keymap(bufnr, 'n', '1', ':lua require("mailwoman").create_chain()<CR>', { noremap = true, silent = true })
      vim.api.nvim_buf_set_keymap(bufnr, 'n', '2', ':lua require("mailwoman").manage_chain_ui()<CR>', { noremap = true, silent = true })
      vim.api.nvim_buf_set_keymap(bufnr, 'n', '3', ':lua require("mailwoman").run_chain_ui()<CR>', { noremap = true, silent = true })
      vim.api.nvim_buf_set_keymap(bufnr, 'n', '4', ':lua require("mailwoman").view_history()<CR>', { noremap = true, silent = true })
      vim.api.nvim_buf_set_keymap(bufnr, 'n', '5', ':close<CR>', { noremap = true, silent = true })
    end
  })
end

function M.manage_chain_ui()
  local chains = {}
  for name, _ in pairs(M.request_chains) do
    table.insert(chains, name)
  end

  create_enhanced_buffer({
    title = "Mailwoman - Manage Chains",
    content = chains,
    modifiable = false,
    callback = function(bufnr)
      -- Add keymaps for selecting a chain
      for i, name in ipairs(chains) do
        vim.api.nvim_buf_set_keymap(bufnr, 'n', tostring(i), string.format(':lua require("mailwoman").manage_chain("%s")<CR>', name), { noremap = true, silent = true })
      end
    end
  })
end

function M.run_chain_ui()
  local chains = {}
  for name, _ in pairs(M.request_chains) do
    table.insert(chains, name)
  end

  create_enhanced_buffer({
    title = "Mailwoman - Run Chain",
    content = chains,
    modifiable = false,
    callback = function(bufnr)
      -- Add keymaps for selecting a chain
      for i, name in ipairs(chains) do
        vim.api.nvim_buf_set_keymap(bufnr, 'n', tostring(i), string.format(':lua require("mailwoman").run_chain("%s")<CR>', name), { noremap = true, silent = true })
      end
    end
  })
end

function M.view_history()
  local content = {}
  for i, entry in ipairs(M.history) do
    table.insert(content, string.format("%d. %s %s", i, entry.method, entry.url))
  end

  create_enhanced_buffer({
    title = "Mailwoman - Request History",
    content = content,
    modifiable = false
})
end

-- Define a command to open the Mailwoman UI
vim.api.nvim_create_user_command("Mailwoman", function()
  require("mailwoman").open_ui()
end, {})

-- Export the module
return M
