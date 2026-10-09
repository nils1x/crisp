-- Native macOS Spaces; Space Rabbit handles the system Space shortcuts.
require("hs.ipc") -- enables the `hs` CLI for reloads and status checks
local hyper = { "cmd", "ctrl", "alt", "shift" }
local step = 50
local helper = os.getenv("HOME") .. "/dev/utils/focus-or-launch.sh"

hs.window.animationDuration = 0

local apps = {
  g = "com.mitchellh.ghostty",
  r = "com.apple.reminders",
  m = "com.apple.mail",
  f = "com.apple.finder",
  o = "md.obsidian",
  z = "dev.zed.Zed",
  s = "com.officecommun.search",
}

for key, bundleID in pairs(apps) do
  hs.hotkey.bind({ "alt" }, key, function()
    hs.task.new(helper, function(code, _, err)
      if code ~= 0 then hs.alert.show(err ~= "" and err or ("Could not focus " .. bundleID)) end
    end, { bundleID }):start()
  end)
end

-- Move a window edge by 50 px. At a screen boundary, move the opposite edge
-- instead (like the old yabai fallback). No other windows are resized.
local function resize(edge)
  local w = hs.window.focusedWindow()
  if not w or w:isFullScreen() then return end
  local f, b = w:frame(), w:screen():frame()
  if edge == "left" then
    if f.x > b.x + 1 then
      local d = math.min(step, f.x - b.x)
      f.x, f.w = f.x - d, f.w + d
    else
      f.w = math.max(150, f.w - step)
    end
  elseif edge == "right" then
    local room = b.x + b.w - f.x - f.w
    if room > 1 then
      f.w = f.w + math.min(step, room)
    else
      local d = math.min(step, math.max(0, f.w - 150))
      f.x, f.w = f.x + d, f.w - d
    end
  elseif edge == "up" then
    if f.y > b.y + 1 then
      local d = math.min(step, f.y - b.y)
      f.y, f.h = f.y - d, f.h + d
    else
      f.h = math.max(100, f.h - step)
    end
  else
    local room = b.y + b.h - f.y - f.h
    if room > 1 then
      f.h = f.h + math.min(step, room)
    else
      local d = math.min(step, math.max(0, f.h - 100))
      f.y, f.h = f.y + d, f.h - d
    end
  end
  w:setFrame(f, 0)
end

for _, edge in ipairs({ "left", "right", "up", "down" }) do
  hs.hotkey.bind({ "ctrl", "alt" }, edge,
    function() resize(edge) end, nil, function() resize(edge) end)
end

local previous = {}
hs.hotkey.bind(hyper, "return", function()
  local w = hs.window.focusedWindow()
  if not w or w:isFullScreen() then return end
  local id = w:id()
  if previous[id] then
    w:setFrame(previous[id], 0)
    previous[id] = nil
  else
    previous[id] = w:frame()
    w:setFrame(w:screen():frame(), 0)
  end
end)

-- Swap frames with the nearest standard window on the visible Space/display.
local directions = {
  left = { -1, 0 }, right = { 1, 0 }, up = { 0, -1 }, down = { 0, 1 },
}
for key, direction in pairs(directions) do
  hs.hotkey.bind(hyper, key, function()
    local focused = hs.window.focusedWindow()
    if not focused then return end
    local f = focused:frame()
    local x, y = f.x + f.w / 2, f.y + f.h / 2
    local best, bestScore
    for _, candidate in ipairs(hs.window.visibleWindows()) do
      if candidate:id() ~= focused:id() and candidate:isStandard()
          and not candidate:isFullScreen()
          and candidate:screen():id() == focused:screen():id() then
        local c = candidate:frame()
        local dx, dy = c.x + c.w / 2 - x, c.y + c.h / 2 - y
        local along = dx * direction[1] + dy * direction[2]
        local across = math.abs(dx * direction[2] - dy * direction[1])
        if along > 0 and across <= along and (not bestScore or along + across < bestScore) then
          best, bestScore = candidate, along + across
        end
      end
    end
    if best then
      local otherFrame = best:frame()
      best:setFrame(f, 0)
      focused:setFrame(otherFrame, 0)
      focused:focus()
    end
  end)
end
