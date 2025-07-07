-- Prophet X Patch Manager
-- K1 to reconnect
-- K2 to erase
-- K3 to rename

local textentry = require 'textentry'

local midi_dev
local grid_dev
local patches = {}
local press_times = {}
local awaiting_patch_from = {}
local sysex_buffer = {}
local flash_state = {}
local deleting_patch = {}
local sysex_active = false
local last_pressed_index = nil
local timeout_clock = nil
local erase_mode = false
local renaming_mode = false
local renaming_index = nil
local k2_held = false
local last_displayed_patch_name = ""

local midi_channel = 2
local sysex_request = {0xF0, 0x01, 0x30, 0x06, 0xF7}
local patch_name_start = 0x000001E2
local forbidden_positions = {0x000001E5, 0x000001ED, 0x000001F5}
local patch_name_length = 20

-- Helper function to check if a value exists in a table
local function contains(tbl, val)
  for _, v in ipairs(tbl) do
    if v == val then return true end
  end
  return false
end

function init_midi()
  midi_dev = nil
  for _, dev in pairs(midi.devices) do
    if dev.port and dev.name and dev.name:find("Prophet") then

      midi_dev = midi.connect(dev.port)
      midi_dev.event = midi_event
      midi_dev.channel = midi_channel  -- Set the MIDI channel
      
   
      redraw("Reconnected!")
      clock.run(function()
        clock.sleep(0.5)
        redraw("")
      end)
      return
    end
  end
  redraw("Connection Failed")
  clock.run(function()
    clock.sleep(0.5)
    redraw("")
  end)
end

-- Extract patch name from SYSEX data
function extract_patch_name(sysex_data)
  if not sysex_data or #sysex_data < patch_name_start + patch_name_length then
    return "Unnamed"
  end

  local name = ""
  local pos = patch_name_start
  local chars_read = 0

  while chars_read < patch_name_length do
    if not contains(forbidden_positions, pos) then
      name = name .. string.char(sysex_data[pos])
      chars_read = chars_read + 1
    end
    pos = pos + 1
  end

  return name
end

-- Get patch name from SYSEX data by index
function get_patch_name_from_sysex(index)
  if not patches[index] then return "Unnamed" end
  local patch_name = extract_patch_name(patches[index])
  return patch_name
end

-- Handle MIDI events
function midi_event(data)
  if not data or #data == 0 then return end

  if sysex_active then
    if data[1] == 0xF0 then
      sysex_buffer = data
    elseif data[#data] == 0xF7 then
      for _, byte in ipairs(data) do
        table.insert(sysex_buffer, byte)
      end

      if last_pressed_index then
        patches[last_pressed_index] = sysex_buffer
        save_patch(last_pressed_index, sysex_buffer)
        awaiting_patch_from[last_pressed_index] = nil
        flash_state[last_pressed_index] = nil

        if timeout_clock then
          clock.cancel(timeout_clock)
          timeout_clock = nil
        end

        local patch_name = get_patch_name_from_sysex(last_pressed_index)
        local cleaned_patch_name = ""
        for i = 1, #patch_name do
          local char = string.sub(patch_name, i, i)
          if string.byte(char) >= 32 and string.byte(char) <= 126 then  -- Printable ASCII range
            cleaned_patch_name = cleaned_patch_name .. char
          end
        end

        last_displayed_patch_name = cleaned_patch_name
        redraw()
      end

      sysex_active = false
      sysex_buffer = {}
    else
      for _, byte in ipairs(data) do
        table.insert(sysex_buffer, byte)
      end
    end
  end
end

-- Redraw the screen
function redraw(message)
  screen.clear()

if k2_held then
    -- Display erase instructions when K2 is held
    screen.move(64, 32)
    screen.text_center("Erase")
    screen.move(64, 42)
    screen.text_center("K3: Erase All")
  else
    -- Display patch name and index when K2 is not held
    if last_displayed_patch_name ~= "" then
      screen.move(64, 32)
      screen.text_center(last_displayed_patch_name)
    end

    if last_pressed_index then
      screen.move(120, 60)
      screen.text_right(tostring(last_pressed_index))
    end
  end

  if message then
    screen.move(64, 52)
    screen.text_center(message)
  end

  screen.update()

  if grid_dev then
    grid_dev:all(0)
    for i = 1, 128 do
      if patches[i] then
        if i == last_pressed_index then
          grid_led(i, 15)
        else
          grid_led(i, 5)
        end
      end
    end
    grid_dev:refresh()
  end
end

-- Send SYSEX data
function send_sysex(data)
  if midi_dev then
    midi_dev:send(data)
  end
end

-- Initialize grid connection
function init_grid()
  grid_dev = grid.connect()
  if grid_dev then
    grid_dev.key = grid_key
  end
end

-- Handle grid key events
function grid_key(x, y, z)
  if sysex_active or not x or not y then return end
  local index = (y - 1) * 16 + x

  if renaming_mode and not k2_held then
    if z == 1 then
      start_text_input(index)
    end
    return
  end

  if erase_mode then
    if z == 1 then
      patches[index] = nil
      os.remove(norns.state.data .. "patch_" .. index .. ".syx")
      redraw("Patch deleted")
    end
    return
  end

  if z == 1 then
    press_times[index] = util.time()
    last_pressed_index = index

    if patches[index] then
      send_sysex(patches[index])
      local patch_name = get_patch_name_from_sysex(index)
      local cleaned_patch_name = ""
      for i = 1, #patch_name do
        local char = string.sub(patch_name, i, i)
        if string.byte(char) >= 32 and string.byte(char) <= 126 then  -- Printable ASCII range
          cleaned_patch_name = cleaned_patch_name .. char
        end
      end

      last_displayed_patch_name = cleaned_patch_name
      redraw()
    else
      awaiting_patch_from[index] = true
      flash_state[index] = true
      clock.run(flash_indicator, index)
      sysex_active = true
      redraw("Receiving...")
      if timeout_clock then clock.cancel(timeout_clock) end
      timeout_clock = clock.run(sysex_timeout, 2)
      send_sysex(sysex_request)
    end
  end
end

-- Handle key events
function key(n, z)
  if n == 1 then
    -- Holding K1 now triggers Reconnect (was previously used for renaming)
    if z == 1 then
      redraw("Reconnecting...")
      init_midi()
    else
      redraw()  -- Reset the screen when K1 is released
    end
  elseif n == 2 then
    k2_held = (z == 1)
    erase_mode = k2_held
    redraw()
  elseif n == 3 and z == 1 then
    -- Pressing K3 now brings up the textentry screen for renaming
    if k2_held then
      -- K2 + K3 should erase all patches
      erase_all_patches()
    elseif last_pressed_index then
      -- Ensure last_pressed_index is valid and a patch exists before renaming
      if patches[last_pressed_index] then
        renaming_mode = true
        start_text_input(last_pressed_index)
      else
        redraw("No patch selected!")
      end
    else
      redraw("No patch selected!")
    end
  end
end

-- Handle encoder events
function enc(n, delta)
  -- No MIDI channel selection functionality
end

-- Flash indicator for awaiting patches
function flash_indicator(index)
  while awaiting_patch_from[index] do
    grid_led(index, flash_state[index] and 15 or 0)
    grid_dev:refresh()
    flash_state[index] = not flash_state[index]
    clock.sleep(0.1)
  end
end

-- Save patch to file
function save_patch(index, data)
  local filename = norns.state.data .. "patch_" .. index .. ".syx"
  local file = io.open(filename, "wb")
  if file then
    for _, byte in ipairs(data) do
      file:write(string.char(byte))
    end
    file:close()
  end
end

-- Load patches from files
function load_patches()
  for i = 1, 128 do
    local filename = norns.state.data .. "patch_" .. i .. ".syx"
    local file = io.open(filename, "rb")
    if file then
      patches[i] = {}
      for byte in file:read("*a"):gmatch(".") do
        table.insert(patches[i], string.byte(byte))
      end
      file:close()
    end
  end
end

-- Erase all patches
function erase_all_patches()
  for i = 1, 128 do
    patches[i] = nil
    os.remove(norns.state.data .. "patch_" .. i .. ".syx")
  end
  redraw("All patches erased!")
end

-- SYSEX timeout handler
function sysex_timeout(duration)
  clock.sleep(duration)
  if sysex_active then
    redraw("Timeout!")
    clock.sleep(1)
    redraw()
    sysex_active = false
    awaiting_patch_from[last_pressed_index] = nil
    last_pressed_index = nil
  end
end

-- Set grid LED state
function grid_led(index, state)
  if not grid_dev then return end
  local x = ((index - 1) % 16) + 1
  local y = math.floor((index - 1) / 16) + 1
  grid_dev:led(x, y, state)
end

-- Start text input using norns textentry
function start_text_input(index)
  local current_name = get_patch_name_from_sysex(index)
  if not current_name or type(current_name) ~= "string" or current_name == "" then
    current_name = "Unnamed"
  end

  local cleaned_patch_name = ""
  for i = 1, #current_name do
    local char = string.sub(current_name, i, i)
    if string.byte(char) >= 32 and string.byte(char) <= 126 then
      cleaned_patch_name = cleaned_patch_name .. char
    end
  end

  local trimmed_name = cleaned_patch_name:match("^(.-)%s*$")

  local function textentry_callback(new_name)
    if new_name then
      update_patch_name(index, new_name)
    end
    renaming_mode = false
    renaming_index = nil
    redraw()
  end

  textentry.enter(textentry_callback, trimmed_name, "Enter new patch name:")
end

-- Update the patch name in the SYSEX data
function update_patch_name(index, new_name)
  if not patches[index] then return end

  local sysex_data = patches[index]
  new_name = new_name:sub(1, patch_name_length) -- Ensure name length is within bounds

  local name_index = 1
  local written = 0
  -- Add 1 to the start so the first character lands at the correct file address
  local pos = patch_name_start + 1

  -- Write exactly patch_name_length characters to non-forbidden positions
  while written < patch_name_length do
    if not contains(forbidden_positions, pos) then
      if name_index <= #new_name then
        sysex_data[pos] = string.byte(new_name, name_index)
        name_index = name_index + 1
      else
        sysex_data[pos] = 0x20  -- Fill remaining space with spaces
      end
      written = written + 1
    end
    pos = pos + 1
  end

  save_patch(index, sysex_data)
  last_displayed_patch_name = new_name
  redraw("Patch renamed!")
end



-- Initialize the script
function init()
  init_midi()
  init_grid()
  load_patches()
  redraw("Patch Librarian")
end

-- Run the script
init()