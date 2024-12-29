local Job = require("plenary.job")
local api = vim.api
local log_path = vim.fn.stdpath("data") .. "/claude.log"

local function log_info(msg)
  local file = io.open(log_path, "a")
  if file then
    local log_entry = string.format("[%s] %s\n", os.date("%Y-%m-%d %H:%M:%S"), msg)
    file:write(log_entry)
    file:close()
  end
end

local function get_api_key()
  return os.getenv("ANTHROPIC_API_KEY")
end

local M = {}

local config = {
  api_key = vim.fn.getenv("ANTHROPIC_API_KEY"),
  api_url = "https://api.anthropic.com/v1/messages",
  model = "claude-3-5-sonnet-20241022",
  keymaps = {
    open_chat = "<leader>cc",
    send_chat = "<C-]>",
  },
  window = {
    width = 80,
    height = 20,
    border = "single",
  },
}

local state = {
  win = nil,
  buf = nil,
  current_job = nil,
  content = {},
}

local function create_window()
  -- Get editor dimensions
  local width = api.nvim_get_option_value("columns", {})
  local height = api.nvim_get_option_value("lines", {})

  -- Calculate floating window size
  local win_width = math.min(config.window.width, width - 4)
  local win_height = math.min(config.window.height, height - 4)

  -- Calculate starting position
  local row = math.floor((height - win_height) / 2)
  local col = math.floor((width - win_width) / 2)

  -- Create buffer
  local buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_option(buf, "buftype", "nofile")
  api.nvim_buf_set_option(buf, "bufhidden", "hide")
  api.nvim_buf_set_option(buf, "swapfile", false)
  api.nvim_buf_set_name(buf, "Claude Chat")

  -- Set initial content
  api.nvim_buf_set_lines(buf, 0, -1, false, {
    "Welcome to Claude Chat!",
    "Type your message and press " .. config.keymaps.send_chat .. " to send.",
    "",
    "You: ",
  })

  -- Create window
  local opts = {
    relative = "editor",
    row = row,
    col = col,
    width = win_width,
    height = win_height,
    style = "minimal",
    border = config.window.border,
    title = "Claude Chat",
    title_pos = "center",
  }

  local win = api.nvim_open_win(buf, true, opts)

  -- Set window options
  api.nvim_win_set_option(win, "wrap", true)
  api.nvim_win_set_option(win, "cursorline", true)

  return win, buf
end

local function update_window_content(text)
  if not state.buf or not api.nvim_buf_is_valid(state.buf) then
    log_info("Invalid buffer state when trying to update")
    return
  end

  local last_line_idx = api.nvim_buf_line_count(state.buf) - 1
  local last_line = api.nvim_buf_get_lines(state.buf, last_line_idx, last_line_idx + 1, false)[1]

  api.nvim_buf_set_lines(state.buf, last_line_idx, last_line_idx + 1, false, { last_line .. text })
end

local function parse_messages()
  local lines = api.nvim_buf_get_lines(state.buf, 0, -1, false)
  local messages = {}
  local current = { role = nil, content = {} }

  for _, line in ipairs(lines) do
    if line:match("^You: ") then
      if current.role then
        table.insert(messages, current)
      end
      current = { role = "user", content = line:gsub("^You: ", "") }
    elseif line:match("^Claude: ") then
      if current.role then
        table.insert(messages, current)
      end
      current = { role = "assistant", content = line:gsub("^Claude: ", "") }
    elseif current.role and #line > 0 then
      current.content = current.content .. "\n" .. line
    end
  end

  if current.role then
    table.insert(messages, current)
  end

  log_info("Parsed messages: " .. vim.inspect(messages))
  return messages
end

local function stream_response(messages)
  local api_key = get_api_key()
  if not api_key then
    log_info("API key not found")
    return
  end

  local data = {
    -- system = system_prompt,
    model = config.model,
    messages = messages,
    stream = true,
    max_tokens = 4096,
  }

  local headers = {
    "-H",
    "Content-Type: application/json",
    "-H",
    "x-api-key: " .. api_key,
    "-H",
    "anthropic-version: 2023-06-01",
  }

  local args = { "-s", "-N", "-X", "POST" }
  vim.list_extend(args, headers)
  table.insert(args, "-d")
  table.insert(args, vim.json.encode(data))
  table.insert(args, config.api_url)

  local function handle_stream_output(_, out)
    if out:match("^data:") then
      local json_str = out:gsub("^data:%s*", "")
      local ok, json = pcall(vim.json.decode, json_str)
      if ok and json.type == "content_block_delta" and json.delta.text then
        vim.schedule(function()
          -- log_info("Received delta: " .. json.delta.text)
          update_window_content(json.delta.text)
        end)
      end
    end
  end

  state.current_job = Job:new({
    command = "curl",
    args = args,
    on_stdout = handle_stream_output,
    on_stderr = function(_, err)
      if err and #err > 0 then
        log_info("stderr: " .. vim.inspect(err))
      end
    end,
    on_exit = function(_, code)
      vim.schedule(function()
        if code == 0 then
          api.nvim_buf_set_lines(state.buf, -1, -1, false, { "", "You: " })
        else
          api.nvim_buf_set_lines(state.buf, -1, -1, false, { "[API Error - Check logs]", "", "You: " })
        end
        state.current_job = nil
      end)
    end,
  })

  state.current_job:start()
end

function M.open_chat()
  if state.win and api.nvim_win_is_valid(state.win) then
    api.nvim_set_current_win(state.win)
    return
  end

  local win, buf = create_window()
  state.win = win
  state.buf = buf

  local opts = { buffer = buf, silent = true }
  vim.keymap.set("n", config.keymaps.send_chat, M.send_message, opts)
  vim.keymap.set("n", "q", M.close_chat, opts)

  api.nvim_win_set_cursor(win, { api.nvim_buf_line_count(buf), 0 })
end

function M.send_message()
  if state.current_job then
    state.current_job:shutdown()
  end

  local messages = parse_messages()
  api.nvim_buf_set_lines(state.buf, -1, -1, false, { "Claude: " })
  stream_response(messages)
end

function M.close_chat()
  if state.win and api.nvim_win_is_valid(state.win) then
    api.nvim_win_close(state.win, true)
    state.win = nil
    state.buf = nil
  end
end

function M.setup(opts)
  config = vim.tbl_deep_extend("force", config, opts or {})

  if config.api_key == "" then
    config.api_key = vim.env.CLAUDE_API_KEY or ""
  end

  vim.notify("Claude: Logs will be written to: " .. log_path, vim.log.levels.INFO)

  if not get_api_key() then
    log_info("No API key found in ANTHROPIC_API_KEY")
    vim.notify("Claude: No API key found in ANTHROPIC_API_KEY", vim.log.levels.ERROR)
    return
  end

  api.nvim_create_user_command("ClaudeChat", M.open_chat, {})
  api.nvim_create_user_command("ClaudeClose", M.close_chat, {})
  vim.keymap.set("n", config.keymaps.open_chat, M.open_chat, {})
end

return M
