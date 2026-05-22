-----------------------------------------------------------------------
-- Mystrix Pro (203 Systems) support for midigrid
--
-- Requires the MatrixOS Performance application to be active on the
-- device.
--
-- The Mystrix Pro appears as a USB MIDI device named "Mystrix Pro <N>"
-- where N is the MIDI port number.
--
-- LED output uses the Apollo-compatible SysEx protocol implemented by
-- the MatrixOS Performance app.  This is the same protocol used by the
-- Launchpad Pro MK3 performance firmware (mat1jaczyyy/lpp-performance-cfw).
--
-- Two SysEx commands are supported:
--   0x5F — Apollo "batch fill": groups LEDs that share the same color
--   0x5E — Apollo "regular fill": per-LED RGB, one index + RGB per LED
--
-- This driver uses 0x5E (regular fill) for simplicity and
-- compatibility.  The SysEx format is:
--
--   F0 00 02 03 4D 58 5E <index><R6><G6><B6> … F7
--   └── MatrixOS header ──┘ └ cmd ┘
--
-- Each colour byte uses 6-bit colour (0–63).  The index maps to the
-- 10×10 Apollo keymap:
--
--   x = index % 10 - 1
--   y = 8 - (index / 10)
--
-- Grid indices (x=0..7, y=0..7) → 11..18, 21..28, …, 81..88
--
-- Input (key presses) still arrive as MIDI NoteOn on channel 0 using
-- the drum-rack keymap, and are handled by generic_device.
--
-- Touch bar LEDs (side lights) are NOT driven via SysEx here; they
-- remain off.  The 8×8 grid is the focus.
-----------------------------------------------------------------------

local mystrix = include('midigrid/lib/devices/generic_device')

-----------------------------------------------------------------------
-- Drum Rack note mapping for input (keymap 0 in Performance8x8)
-- This is only for the reverse lookup: received note → (x, y).
-----------------------------------------------------------------------
mystrix.grid_notes = {
  {64, 65, 66, 67, 96, 97, 98, 99},
  {60, 61, 62, 63, 92, 93, 94, 95},
  {56, 57, 58, 59, 88, 89, 90, 91},
  {52, 53, 54, 55, 84, 85, 86, 87},
  {48, 49, 50, 51, 80, 81, 82, 83},
  {44, 45, 46, 47, 76, 77, 78, 79},
  {40, 41, 42, 43, 72, 73, 74, 75},
  {36, 37, 38, 39, 68, 69, 70, 71}
}

-----------------------------------------------------------------------
-- Apollo keymap: convert (x, y) grid position to SysEx index.
--   index = (8 - y) * 10 + (x + 1)
-----------------------------------------------------------------------
local function xy_to_apollo_index(x, y)
  return (8 - y) * 10 + (x + 1)
end

-----------------------------------------------------------------------
-- MatrixOS SysEx header + Apollo regular-fill command byte
-- Full RGB header: F0 00 02 03 4D 58 5E
-----------------------------------------------------------------------
local SYX_RGB_HEADER = { 0xF0, 0x00, 0x02, 0x03, 0x4D, 0x58, 0x5E }

-----------------------------------------------------------------------
-- RGB colour LUT — 16 brightness levels (z=0..15)
--
-- Warm amber/yellow/white gradient matching the visual style of other
-- midigrid devices.  Values are 6-bit (0–63) for Apollo SysEx.
-----------------------------------------------------------------------
local rgb6_lut = {
  { 0,  0,  0},  -- z=0:  off
  {15,  0,  0},  -- z=1:  very dim red
  {15,  3,  0},  -- z=2:  very dim orange
  {15,  7,  0},  -- z=3:  dark amber
  {31,  7,  0},  -- z=4:  dim orange
  {31, 15,  0},  -- z=5:  medium amber
  {31, 23,  0},  -- z=6:  warm yellow
  {47, 23,  0},  -- z=7:  amber
  {47, 35,  0},  -- z=8:  warm yellow
  {63, 31,  0},  -- z=9:  orange-amber
  {47, 47,  0},  -- z=10: yellow
  {63, 47,  0},  -- z=11: amber-yellow
  {63, 47, 31},  -- z=12: light amber
  {63, 63,  0},  -- z=13: bright yellow
  {63, 63, 31},  -- z=14: yellow-white
  {63, 63, 63},  -- z=15: white
}

-- The brightness_map is unused for output (we use SysEx RGB), but
-- generic_device still references it for aux button helpers.  Provide a
-- no-op table.
mystrix.brightness_map = {0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15}

-- No init_device_msg needed: the Performance app is always ready.
mystrix.rotate_second_device = false

-----------------------------------------------------------------------
-- Clamp z to valid rgb6_lut index (1–16)
-----------------------------------------------------------------------
local function clamp_rgb_index(z)
  if type(z) ~= "number" then return 1 end
  if z < 0 then return 1 end
  if z > 15 then return 16 end
  return z + 1
end

-----------------------------------------------------------------------
-- Build a "clear all grid LEDs" SysEx (regular fill with black).
-----------------------------------------------------------------------
-- Force-clear using batch fill (0x5F) with black, per Apollo Studio
-- ForceClearMessage for MystrixPro
local clear_all_sysx = { 0xF0, 0x00, 0x02, 0x03, 0x4D, 0x58, 0x5F, 0x00, 0x00, 0x40, 0x00, 0xF7 }

-----------------------------------------------------------------------
-- Override _reset: clear all LEDs via Apollo SysEx
-----------------------------------------------------------------------
local _parent_reset = mystrix._reset
function mystrix:_reset()
  local dev = midi.devices[self.midi_id]
  if dev then
    dev:send(clear_all_sysx)
  end
end

-----------------------------------------------------------------------
-- Override _update_led: send single LED via Apollo regular-fill SysEx
-----------------------------------------------------------------------
function mystrix._update_led(self, x, y, z)
  if y < 1 or #self.grid_notes < y or x < 1 or #self.grid_notes[y] < x then
    return
  end
  -- Convert from midigrid 1-based coords to 0-based for Apollo
  local idx = xy_to_apollo_index(x - 1, y - 1)
  local rgb = rgb6_lut[clamp_rgb_index(z)]
  local dev = midi.devices[self.midi_id]
  if dev then
    dev:send({
      table.unpack(SYX_RGB_HEADER),
      idx,
      rgb[1], rgb[2], rgb[3],
      0xF7
    })
  end
end

-----------------------------------------------------------------------
-- Override refresh: batch all dirty/full-refresh LEDs into one SysEx
-----------------------------------------------------------------------
function mystrix:refresh(quad)
  if quad.id ~= self.current_quad then return end

  if self.refresh_counter > 9 then
    self.force_full_refresh = true
    self.refresh_counter = 0
  end

  local dev = midi.devices[self.midi_id]
  if not dev then return end

  if self.force_full_refresh then
    local m = { table.unpack(SYX_RGB_HEADER) }
    for y = 1, quad.height do
      for x = 1, quad.width do
        local idx = xy_to_apollo_index(x - 1, y - 1)
        local rgb = rgb6_lut[clamp_rgb_index(quad.buffer[x][y])]
        m[#m + 1] = idx
        m[#m + 1] = rgb[1]
        m[#m + 1] = rgb[2]
        m[#m + 1] = rgb[3]
      end
    end
    m[#m + 1] = 0xF7
    dev:send(m)
    self.force_full_refresh = false
  else
    if quad.frozen_update and quad.frozen_update.update_count > 0 then
      local m = { table.unpack(SYX_RGB_HEADER) }
      for u = 1, quad.frozen_update.update_count do
        local x = quad.frozen_update.updates_x[u]
        local y = quad.frozen_update.updates_y[u]
        local idx = xy_to_apollo_index(x - 1, y - 1)
        local rgb = rgb6_lut[clamp_rgb_index(quad.buffer[x][y])]
        m[#m + 1] = idx
        m[#m + 1] = rgb[1]
        m[#m + 1] = rgb[2]
        m[#m + 1] = rgb[3]
      end
      m[#m + 1] = 0xF7
      dev:send(m)
    end
    self.refresh_counter = self.refresh_counter + 1
  end
end

return mystrix
