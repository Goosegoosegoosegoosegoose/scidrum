-- scidrum
-- S.C.I.E.N.C.E. drum machine
-- norns + ZOIA + Alecto
-- + nanoPAD2
--
-- ZOIA is the master clock.
-- nanoPAD2 plays everything.
-- grid optional (16x8):
-- r1-2 steps, r3-4 values,
-- r5-6 lengths, r7 patterns
-- + controls, r8 perf holds
--
-- K2: next pad mode
-- K3: run / stop
-- K1+K2: rec arm
-- K1+K3: clear (again = undo)
-- E1: tempo req (K1: swing)
-- E2/E3: depend on mode
--
-- v1.2

local NUM_STEPS = 16
local NUM_PATTERNS = 8
local MODE_NAMES = {"PLAY", "STEP V1", "STEP V2", "PERF"}
local DATA_DIR = _path.data .. "scidrum/"

-- softcut ring buffer (for audio repeat / tape stop)
local REC_START = 1
local REC_LEN = 60

local pads_dev, zoia_dev
local patterns = {}
local backup = nil
local cur_pat = 1
local queued_pat = nil
local pos = {0, 0}
local tick = 0
local running = true
local rec = false
local mode = 1
local shift = false
local sel_step = {1, 1}
local mutes = {false, false}
local flash = {0, 0}
local last_hits = {false, false}
local rec_skip = {nil, nil}
local last_step_time = 0
local rec_pos = REC_START
local tempo_req = 120
local last_mod_sent = -1
local msg, msg_t = "", 0
local last_in = "--"

-- held performance states
local perf = {
  half = false, double = false, reverse = false, glitch = false,
  fill = false, drop = false, tapestop = false,
  mute1 = false, mute2 = false, beatrep = false,
  ratchet = 0, -- >0 while a ratchet hold is down
}
local rolls = {}      -- clock ids for held rolls (PLAY pads 3/4)
local repeat_id = nil -- clock id for MIDI beat repeat

---------------------------------------------------------------
-- data
---------------------------------------------------------------

local function new_voice()
  local v = {len = 16, fill = 0, rot = 0, steps = {}}
  for i = 1, NUM_STEPS do
    v.steps[i] = {on = false, acc = false, prob = 100, rat = 1, mod = -1}
  end
  return v
end

local function new_pattern() return {new_voice(), new_voice()} end

local function deep_copy(t)
  if type(t) ~= "table" then return t end
  local c = {}
  for k, v in pairs(t) do c[k] = deep_copy(v) end
  return c
end

local function init_patterns()
  for p = 1, NUM_PATTERNS do patterns[p] = new_pattern() end
  -- a starter groove in pattern 1
  local p = patterns[1]
  for _, i in ipairs({1, 5, 9, 13}) do p[1].steps[i].on = true end
  p[1].steps[1].acc = true
  for _, i in ipairs({5, 13}) do p[2].steps[i].on = true end
  p[2].steps[16].on = true
  p[2].steps[16].prob = 50
end

local function save_patterns(file)
  util.make_dir(DATA_DIR)
  tab.save(patterns, DATA_DIR .. file)
end

local function load_patterns(file)
  local path = DATA_DIR .. file
  if util.file_exists(path) then
    local t = tab.load(path)
    if t and #t == NUM_PATTERNS then patterns = t; return true end
  end
  return false
end

local function notify(s) msg = s; msg_t = 30 end

---------------------------------------------------------------
-- euclid
---------------------------------------------------------------

local function apply_euclid(v)
  local vd = patterns[cur_pat][v]
  local n, k, r = vd.len, vd.fill, vd.rot
  for i = 1, NUM_STEPS do vd.steps[i].on = false end
  if k <= 0 then return end
  for i = 0, n - 1 do
    if ((i * k) % n) < k then
      vd.steps[((i + r) % n) + 1].on = true
    end
  end
end

---------------------------------------------------------------
-- MIDI out to ZOIA
---------------------------------------------------------------

local function zoia_cc(cc_param, val)
  if zoia_dev then
    zoia_dev:cc(params:get(cc_param), util.clamp(math.floor(val), 0, 127), params:get("ctl_ch"))
  end
end

local function trig(v, vel)
  flash[v] = 4
  if not zoia_dev then return end
  local ch = params:get("v" .. v .. "_ch")
  zoia_dev:note_on(60, util.clamp(vel, 1, 127), ch)
  clock.run(function()
    clock.sleep(params:get("gate_ms") / 1000)
    zoia_dev:note_off(60, 0, ch)
  end)
end

local function send_tap()
  if zoia_dev then
    local ch = params:get("tap_ch")
    zoia_dev:note_on(60, 127, ch)
    clock.run(function() clock.sleep(0.02); zoia_dev:note_off(60, 0, ch) end)
  end
  notify("tap")
end

local function send_tempo_req()
  -- maps 40..240 bpm onto 0..127 (ZOIA side must use the same range)
  zoia_cc("tempo_cc", (tempo_req - 40) / 200 * 127)
end

---------------------------------------------------------------
-- sequencer
---------------------------------------------------------------

local function step_rate()
  local r = 1 / 4 -- 16th notes
  if perf.half then r = r * 2 end
  if perf.double then r = r / 2 end
  return r
end

local function step_dur() return clock.get_beat_sec() * step_rate() end

local function voice_silenced(v)
  if perf.drop or perf.tapestop or perf.beatrep then return true end
  if mutes[v] then return true end
  if v == 1 and perf.mute1 then return true end
  if v == 2 and perf.mute2 then return true end
  return false
end

local function play_step(v, s)
  local vel = s.acc and params:get("acc_vel") or params:get("base_vel")
  if s.rat <= 1 then
    trig(v, vel)
  else
    local n = s.rat
    clock.run(function()
      for i = 1, n do
        trig(v, vel)
        if i < n then clock.sleep(step_dur() / n) end
      end
    end)
  end
end

local function advance()
  -- pattern change on the bar line
  if queued_pat and tick % 16 == 0 then
    cur_pat = queued_pat
    queued_pat = nil
    pos = {0, 0}
    notify("pattern " .. cur_pat)
  end
  tick = tick + 1
  last_step_time = util.time()

  local p = patterns[cur_pat]
  local hits = {}
  for v = 1, 2 do
    local vd = p[v]
    if perf.reverse then
      pos[v] = pos[v] - 1
      if pos[v] < 1 then pos[v] = vd.len end
    elseif perf.glitch and math.random() < 0.3 then
      pos[v] = math.random(vd.len)
    else
      pos[v] = pos[v] % vd.len + 1
    end

    local s = vd.steps[pos[v]]
    local hit = s.on and (math.random(100) <= s.prob)
    if perf.fill then
      if s.on then hit = true
      elseif math.random() < 0.25 then
        hit = true
        s = {on = true, acc = false, prob = 100, rat = (math.random() < 0.3) and 2 or 1, mod = -1}
      end
    end
    if rec_skip[v] == pos[v] then hit = false; rec_skip[v] = nil end

    -- mod lane (CV4) p-locks: voice 2 overrides voice 1
    if s.mod and s.mod >= 0 then hits.mod = s.mod end

    if hit and perf.ratchet > 0 and s.rat < perf.ratchet then
      s = {on = s.on, acc = s.acc, prob = s.prob, rat = perf.ratchet, mod = s.mod}
    end
    if hit and not voice_silenced(v) then hits[v] = s end
  end

  local mod = hits.mod or params:get("mod_default")
  if mod ~= last_mod_sent then zoia_cc("mod_cc", mod); last_mod_sent = mod end

  if hits[1] or hits[2] then last_hits = {hits[1] ~= nil, hits[2] ~= nil} end

  local swing = params:get("swing")
  local delay = (tick % 2 == 0 and swing > 0) and (step_dur() * swing / 100) or 0
  local function fire()
    for v = 1, 2 do if hits[v] then play_step(v, hits[v]) end end
  end
  if delay > 0 then clock.run(function() clock.sleep(delay); fire() end) else fire() end
end

local function seq_loop()
  while true do
    clock.sync(step_rate())
    if running then advance() end
  end
end

local function reset_pos() pos = {0, 0}; tick = 0 end

---------------------------------------------------------------
-- softcut: audio repeat + tape stop on the ZOIA return
---------------------------------------------------------------

local function sc_init()
  audio.level_adc_cut(1)
  softcut.buffer_clear()
  for i = 1, 4 do softcut.enable(i, 1) end
  -- 1/2 = record heads (silent), L/R
  for i = 1, 2 do
    softcut.buffer(i, i)
    softcut.level(i, 0)
    softcut.level_input_cut(1, i, i == 1 and 1 or 0)
    softcut.level_input_cut(2, i, i == 2 and 1 or 0)
    softcut.rec_level(i, 1)
    softcut.pre_level(i, 0)
    softcut.rate(i, 1)
    softcut.loop(i, 1)
    softcut.loop_start(i, REC_START)
    softcut.loop_end(i, REC_START + REC_LEN)
    softcut.position(i, REC_START)
    softcut.fade_time(i, 0.01)
    softcut.play(i, 1)
    softcut.rec(i, 1)
  end
  -- 3/4 = play heads, L/R
  for i = 3, 4 do
    softcut.buffer(i, i - 2)
    softcut.level(i, 0)
    softcut.pan(i, i == 3 and -1 or 1)
    softcut.level_input_cut(1, i, 0)
    softcut.level_input_cut(2, i, 0)
    softcut.rec(i, 0)
    softcut.rate(i, 1)
    softcut.loop(i, 1)
    softcut.loop_start(i, REC_START)
    softcut.loop_end(i, REC_START + 1)
    softcut.position(i, REC_START)
    softcut.fade_time(i, 0.005)
    softcut.play(i, 1)
  end
  softcut.phase_quant(1, 0.01)
  softcut.event_phase(function(v, p) if v == 1 then rec_pos = p end end)
  softcut.poll_start_phase()
end

local function dry_on() audio.level_monitor(params:get("dry")) end

local function audio_repeat(div)
  local slice = clock.get_beat_sec() * div
  local s = math.max(rec_pos - slice, REC_START)
  for i = 3, 4 do
    softcut.rate_slew_time(i, 0)
    softcut.rate(i, 1)
    softcut.loop_start(i, s)
    softcut.loop_end(i, s + slice)
    softcut.position(i, s)
    softcut.level(i, 1)
  end
  audio.level_monitor(0)
end

local function tape_stop()
  local s = math.max(rec_pos - 0.02, REC_START)
  for i = 3, 4 do
    softcut.rate_slew_time(i, 0)
    softcut.rate(i, 1)
    softcut.loop_start(i, REC_START)
    softcut.loop_end(i, REC_START + REC_LEN)
    softcut.position(i, s)
    softcut.level(i, 1)
  end
  audio.level_monitor(0)
  clock.run(function()
    clock.sleep(0.03)
    for i = 3, 4 do
      softcut.rate_slew_time(i, params:get("tape_time"))
      softcut.rate(i, 0)
    end
  end)
end

local function audio_release()
  for i = 3, 4 do softcut.level(i, 0); softcut.rate_slew_time(i, 0); softcut.rate(i, 1) end
  dry_on()
end

---------------------------------------------------------------
-- pads
---------------------------------------------------------------

local function record_hit(v, vel)
  local vd = patterns[cur_pat][v]
  local target = math.max(pos[v], 1)
  if util.time() - last_step_time > step_dur() / 2 then
    target = target % vd.len + 1
    rec_skip[v] = target -- we already heard it live
  end
  vd.steps[target].on = true
  vd.steps[target].acc = vel >= 100
end

local function start_roll(v, vel)
  local rates = {1 / 2, 1 / 4, 1 / 8}
  rolls[v] = clock.run(function()
    while true do
      clock.sync(rates[params:get("roll_rate")])
      trig(v, vel)
      if rec and running then record_hit(v, vel) end
    end
  end)
end

local function stop_roll(v)
  if rolls[v] then clock.cancel(rolls[v]); rolls[v] = nil end
end

local function start_beat_repeat(div)
  if repeat_id then clock.cancel(repeat_id) end
  perf.beatrep = true
  local who = last_hits
  if not who[1] and not who[2] then who = {true, false} end
  repeat_id = clock.run(function()
    local vel = params:get("acc_vel")
    while true do
      clock.sync(div)
      for v = 1, 2 do if who[v] then trig(v, vel) end end
      vel = math.max(vel - 4, 40)
    end
  end)
end

local function stop_beat_repeat()
  if repeat_id then clock.cancel(repeat_id); repeat_id = nil end
  perf.beatrep = false
end

local PERF_NAMES = {
  "rpt 1/4", "rpt 1/8", "rpt 1/16", "rpt 1/32",
  "aud 1/4", "aud 1/8", "aud 1/16", "tape stop",
  "half", "double", "reverse", "glitch",
  "fill", "mute 1", "mute 2", "DROP",
}
local RATCHET_N = {2, 3, 4, 6}
local perf_held = {}

local function rpt_is_ratchet() return params:get("rpt_mode") == 2 end

local function perf_name(i)
  if i <= 4 and rpt_is_ratchet() then return "ratchet x" .. RATCHET_N[i] end
  return PERF_NAMES[i]
end

local function release_ratchet()
  -- fall back to whichever ratchet hold is still down
  perf.ratchet = 0
  if not rpt_is_ratchet() then return end
  for j = 1, 4 do if perf_held[j] then perf.ratchet = math.max(perf.ratchet, RATCHET_N[j]) end end
end

local function perf_down(i)
  perf_held[i] = true
  if i <= 4 and rpt_is_ratchet() then perf.ratchet = math.max(perf.ratchet, RATCHET_N[i])
  elseif i <= 4 then start_beat_repeat(({1, 1 / 2, 1 / 4, 1 / 8})[i])
  elseif i <= 7 then audio_repeat(({1, 1 / 2, 1 / 4})[i - 4])
  elseif i == 8 then perf.tapestop = true; tape_stop()
  elseif i == 9 then perf.half = true
  elseif i == 10 then perf.double = true
  elseif i == 11 then perf.reverse = true
  elseif i == 12 then perf.glitch = true
  elseif i == 13 then perf.fill = true
  elseif i == 14 then perf.mute1 = true
  elseif i == 15 then perf.mute2 = true
  elseif i == 16 then perf.drop = true
  end
  notify(perf_name(i))
end

local function perf_up(i)
  perf_held[i] = nil
  if i <= 4 then
    release_ratchet()
    stop_beat_repeat()
  elseif i <= 7 then audio_release()
  elseif i == 8 then perf.tapestop = false; audio_release()
  elseif i == 9 then perf.half = false
  elseif i == 10 then perf.double = false
  elseif i == 11 then perf.reverse = false
  elseif i == 12 then perf.glitch = false
  elseif i == 13 then perf.fill = false
  elseif i == 14 then perf.mute1 = false
  elseif i == 15 then perf.mute2 = false
  elseif i == 16 then perf.drop = false; reset_pos() -- slam back in on step 1
  end
end

local function pad_down(i, vel)
  if mode == 1 then -- PLAY
    if i == 1 or i == 2 then
      trig(i, vel)
      if rec and running then record_hit(i, vel) end
    elseif i == 3 or i == 4 then start_roll(i - 2, vel)
    elseif i == 5 or i == 6 then
      local v = i - 4
      mutes[v] = not mutes[v]
      notify("voice " .. v .. (mutes[v] and " muted" or " on"))
    elseif i == 7 then send_tap()
    elseif i == 8 then rec = not rec; notify(rec and "REC armed" or "rec off")
    else
      local slot = i - 8
      if shift then
        patterns[slot] = deep_copy(patterns[cur_pat])
        notify("copied to " .. slot)
      elseif not running then
        cur_pat = slot; notify("pattern " .. slot)
      else
        queued_pat = slot; notify("next: " .. slot)
      end
    end
  elseif mode == 2 or mode == 3 then -- STEP
    local v = mode - 1
    local s = patterns[cur_pat][v].steps[i]
    sel_step[v] = i
    if shift then
      s.acc = not s.acc; s.on = true
    elseif s.on then
      s.on = false
    else
      s.on = true; s.acc = vel >= 100
    end
  else -- PERF
    perf_down(i)
  end
end

local function pad_up(i)
  if mode == 1 then
    if i == 3 or i == 4 then stop_roll(i - 2) end
  elseif mode == 4 then
    if perf_held[i] then perf_up(i) end
  end
end

local function release_all()
  for i = 1, 16 do if perf_held[i] then perf_up(i) end end
  stop_roll(1); stop_roll(2)
end

local function set_mode(m)
  release_all()
  mode = m
end

-- what the Y axis drives (index matches the "y_target" param)
local Y_TARGETS = {"y_out_cc", "lfo_rate_cc", "lfo_cc", "wet_cc"}

local function xy_in(axis, val) -- val 0..127
  -- "from center": resting in the middle = 0, either edge = 127.
  -- use this with X-Y HOLD off so letting go snaps back to clean.
  if params:get(axis .. "_shape") == 2 then
    val = math.abs(val - 63.5) / 63.5 * 127
  end
  if axis == "x" then zoia_cc("x_out_cc", val)
  else zoia_cc(Y_TARGETS[params:get("y_target")], val) end
end

local function pad_event(data)
  local m = midi.to_msg(data)
  if params:get("scene_mode") == 2 and m.ch and m.ch >= 1 and m.ch <= 4 and m.ch ~= mode
    and (m.type == "note_on" or m.type == "note_off") then
    set_mode(m.ch)
  end
  if m.type == "note_on" or m.type == "note_off" then
    local i = m.note - params:get("pad_base") + 1
    if i < 1 or i > 16 then return end
    if m.type == "note_on" and m.vel > 0 then pad_down(i, m.vel) else pad_up(i) end
  elseif m.type == "cc" then
    last_in = "cc" .. m.cc
    if params:get("x_src") == 2 and m.cc == params:get("x_in_cc") then xy_in("x", m.val) end
    if m.cc == params:get("y_in_cc") then xy_in("y", m.val) end
  elseif m.type == "pitchbend" then
    last_in = "bend"
    if params:get("x_src") == 1 then xy_in("x", m.val / 16383 * 127) end
  end
end

---------------------------------------------------------------
-- grid (optional; 16x8)
-- r1/r2 steps v1/v2   r3/r4 step value v1/v2
-- r5/r6 length v1/v2  r7 patterns+controls  r8 perf
---------------------------------------------------------------

local g = grid.connect()
local grid_view = 1 -- rows 3/4 show: 1 prob, 2 ratchet, 3 mod
local GRID_VIEW_NAMES = {"prob", "ratchet", "mod"}
local step_on_time = {{}, {}}
local pat_held = nil
local grid_perf_held = {}

local function cycle(list, cur)
  for i, v in ipairs(list) do
    if v == cur then return list[i % #list + 1] end
  end
  return list[1]
end

local function grid_key(x, y, z)
  if y == 8 then -- perf row, momentary
    if z == 1 then grid_perf_held[x] = true; perf_down(x)
    elseif grid_perf_held[x] then grid_perf_held[x] = nil; perf_up(x) end
    return
  end

  if y == 7 and x <= 8 then -- pattern slots
    if z == 0 then
      if pat_held == x then pat_held = nil end
      return
    end
    if pat_held and pat_held ~= x then
      patterns[x] = deep_copy(patterns[pat_held]); notify(pat_held .. " copied to " .. x)
      return
    end
    pat_held = x
    if shift then
      patterns[x] = deep_copy(patterns[cur_pat]); notify("copied to " .. x)
    elseif not running then
      cur_pat = x; notify("pattern " .. x)
    else
      queued_pat = x; notify("next: " .. x)
    end
    return
  end

  if z == 0 then return end
  local p = patterns[cur_pat]

  if y == 1 or y == 2 then -- steps
    local v = y
    local s = p[v].steps[x]
    sel_step[v] = x
    local now = util.time()
    if s.on and step_on_time[v][x] and now - step_on_time[v][x] < 0.35 then
      s.acc = not s.acc -- quick second tap = accent
      step_on_time[v][x] = nil
    elseif s.on then
      s.on = false
    else
      s.on = true; s.acc = false; step_on_time[v][x] = now
    end
  elseif y == 3 or y == 4 then -- per-step value
    local v = y - 2
    local s = p[v].steps[x]
    sel_step[v] = x
    if grid_view == 1 then s.prob = cycle({100, 75, 50, 25}, s.prob)
    elseif grid_view == 2 then s.rat = cycle({1, 2, 3, 4}, s.rat)
    else s.mod = cycle({-1, 0, 32, 64, 96, 127}, s.mod) end
    notify("v" .. v .. " s" .. x .. " " .. GRID_VIEW_NAMES[grid_view])
  elseif y == 5 or y == 6 then -- lengths
    local v = y - 4
    p[v].len = x
    if pos[v] > x then pos[v] = 0 end
    notify("v" .. v .. " length " .. x)
  elseif y == 7 then
    if x == 9 or x == 10 then
      local v = x - 8
      mutes[v] = not mutes[v]
      notify("voice " .. v .. (mutes[v] and " muted" or " on"))
    elseif x == 11 then rec = not rec; notify(rec and "REC armed" or "rec off")
    elseif x == 12 then
      running = not running
      if running then reset_pos() end
      notify(running and "run" or "stop")
    elseif x == 13 then send_tap()
    elseif x >= 14 then grid_view = x - 13; notify("grid shows " .. GRID_VIEW_NAMES[grid_view])
    end
  end
end

local function grid_redraw()
  if not g.device then return end
  g:all(0)
  local p = patterns[cur_pat]
  for v = 1, 2 do
    local vd = p[v]
    for x = 1, NUM_STEPS do
      local s = vd.steps[x]
      if x <= vd.len then
        -- steps
        local l = 2
        if s.on then l = s.acc and 12 or 7 end
        if running and x == pos[v] then l = s.on and 15 or 5 end
        g:led(x, v, l)
        -- per-step value
        local val = 0
        if grid_view == 1 then val = s.on and math.floor(s.prob / 100 * 13) + 2 or 0
        elseif grid_view == 2 then val = s.on and s.rat * 3 or 0
        else val = s.mod >= 0 and math.floor(s.mod / 127 * 13) + 2 or 0 end
        g:led(x, v + 2, val)
      end
      -- length bars
      g:led(x, v + 4, x <= vd.len and (x == vd.len and 12 or 4) or 0)
    end
  end
  -- row 7
  for x = 1, 8 do
    local l = 3
    if x == cur_pat then l = 15 elseif x == queued_pat then l = 9 end
    g:led(x, 7, l)
  end
  g:led(9, 7, mutes[1] and 15 or (flash[1] > 0 and 8 or 3))
  g:led(10, 7, mutes[2] and 15 or (flash[2] > 0 and 8 or 3))
  g:led(11, 7, rec and 15 or 3)
  g:led(12, 7, running and 12 or 3)
  g:led(13, 7, (math.floor(clock.get_beats()) ~= math.floor(clock.get_beats() - 0.1)) and 15 or 4)
  for x = 14, 16 do g:led(x, 7, grid_view == x - 13 and 12 or 3) end
  -- row 8 perf
  for x = 1, 16 do g:led(x, 8, perf_held[x] and 15 or 3) end
  g:refresh()
end

local function grid_init()
  g.key = grid_key
  grid.add = function()
    g = grid.connect()
    g.key = grid_key
  end
end

---------------------------------------------------------------
-- params
---------------------------------------------------------------

local function port_names()
  local t = {}
  for i = 1, #midi.vports do
    t[i] = i .. ": " .. util.trim_string_to_width(midi.vports[i].name, 60)
  end
  return t
end

local function add_params()
  local names = port_names()
  params:add_separator("scidrum")

  params:add_group("devices + clock", 6)
  params:add_option("pad_port", "nanoPAD2 port", names, 1)
  params:set_action("pad_port", function(x)
    if pads_dev then pads_dev.event = nil end
    pads_dev = midi.connect(x)
    pads_dev.event = pad_event
  end)
  params:add_option("zoia_port", "ZOIA port (TRS)", names, math.min(2, #names))
  params:set_action("zoia_port", function(x) zoia_dev = midi.connect(x) end)
  params:add_option("zoia_clock", "clock from ZOIA", {"no", "yes"}, 2)
  params:set_action("zoia_clock", function(x)
    if x == 2 then params:set("clock_source", 2) end -- 2 = midi
  end)
  params:add_option("zoia_stop", "ZOIA stop msg", {"ignore", "back to step 1", "stop"}, 2)
  params:add_number("pad_base", "pad 1 note", 0, 112, 36)
  params:add_option("scene_mode", "nanoPAD scenes", {"off", "scene ch = mode"}, 1)

  params:add_group("channels + CCs", 11)
  params:add_number("v1_ch", "voice 1 ch", 1, 16, 10)
  params:add_number("v2_ch", "voice 2 ch", 1, 16, 11)
  params:add_number("tap_ch", "tap tempo ch", 1, 16, 15)
  params:add_number("ctl_ch", "control CC ch", 1, 16, 16)
  params:add_number("tempo_cc", "tempo CC", 0, 127, 14)
  params:add_number("mod_cc", "mod lane CC", 0, 127, 20)
  params:add_number("lfo_cc", "LFO depth CC", 0, 127, 21)
  params:add_number("x_out_cc", "crush CC (X)", 0, 127, 22)
  params:add_number("y_out_cc", "decimate CC (Y)", 0, 127, 23)
  params:add_number("wet_cc", "delay send CC", 0, 127, 24)
  params:add_number("lfo_rate_cc", "LFO rate CC", 0, 127, 25)

  params:add_group("xy pad in", 6)
  params:add_option("x_src", "X axis sends", {"pitchbend", "cc"}, 1)
  params:add_number("x_in_cc", "X cc (if cc)", 0, 127, 16)
  params:add_number("y_in_cc", "Y cc", 0, 127, 1)
  params:add_option("y_target", "Y axis drives", {"decimate", "LFO rate", "LFO depth", "delay send"}, 1)
  params:add_option("x_shape", "X response", {"raw", "from center"}, 1)
  params:add_option("y_shape", "Y response", {"raw", "from center"}, 1)

  params:add_group("feel", 7)
  params:add_number("gate_ms", "trigger length ms", 1, 50, 10)
  params:add_number("base_vel", "normal velocity", 1, 127, 80)
  params:add_number("acc_vel", "accent velocity", 1, 127, 127)
  params:add_number("swing", "swing %", 0, 50, 0)
  params:add_option("roll_rate", "roll rate", {"1/8", "1/16", "1/32"}, 2)
  params:add_number("mod_default", "mod lane resting", 0, 127, 64)
  params:add_option("rpt_mode", "perf holds 1-4", {"beat repeat", "ratchet x2/3/4/6"}, 1)
  params:set_action("rpt_mode", function() release_all() end)

  params:add_group("audio", 2)
  params:add_control("dry", "dry level", controlspec.new(0, 1, "lin", 0.01, 1))
  params:set_action("dry", function() dry_on() end)
  params:add_control("tape_time", "tape stop time", controlspec.new(0.05, 3, "lin", 0.05, 0.6, "s"))

  -- knob values that live on the ZOIA
  params:add_group("zoia knobs", 5)
  params:add_number("k_crush", "crush", 0, 127, 0)
  params:set_action("k_crush", function(x) zoia_cc("x_out_cc", x) end)
  params:add_number("k_dec", "decimate", 0, 127, 0)
  params:set_action("k_dec", function(x) zoia_cc("y_out_cc", x) end)
  params:add_number("k_wet", "delay send", 0, 127, 0)
  params:set_action("k_wet", function(x) zoia_cc("wet_cc", x) end)
  params:add_number("k_lfo", "LFO depth", 0, 127, 0)
  params:set_action("k_lfo", function(x) zoia_cc("lfo_cc", x) end)
  params:add_number("k_lfo_rate", "LFO rate", 0, 127, 64)
  params:set_action("k_lfo_rate", function(x) zoia_cc("lfo_rate_cc", x) end)

  params.action_write = function(_, _, number) save_patterns("pset-" .. number .. ".data") end
  params.action_read = function(_, _, number) load_patterns("pset-" .. number .. ".data") end
end

---------------------------------------------------------------
-- keys + encoders
---------------------------------------------------------------

function key(n, z)
  if n == 1 then shift = (z == 1); return end
  if z == 0 then return end
  if n == 2 then
    if shift then
      rec = not rec; notify(rec and "REC armed" or "rec off")
    else
      set_mode(mode % 4 + 1)
    end
  elseif n == 3 then
    if shift then
      local function empty(p)
        for v = 1, 2 do for i = 1, NUM_STEPS do if p[v].steps[i].on then return false end end end
        return true
      end
      local p = patterns[cur_pat]
      if empty(p) and backup then
        patterns[cur_pat] = backup; backup = nil; notify("undo")
      elseif mode == 2 or mode == 3 then
        backup = deep_copy(p); p[mode - 1] = new_voice(); notify("cleared voice " .. (mode - 1))
      else
        backup = deep_copy(p); patterns[cur_pat] = new_pattern(); notify("cleared pattern")
      end
    else
      running = not running
      if running then reset_pos() end
      notify(running and "run" or "stop")
    end
  end
end

function enc(n, d)
  if n == 1 then
    if shift then
      params:delta("swing", d)
    else
      tempo_req = util.clamp(tempo_req + d, 40, 240)
      send_tempo_req()
    end
    return
  end
  if mode == 1 then
    local v = n - 1
    local vd = patterns[cur_pat][v]
    if shift then
      vd.rot = (vd.rot + d) % vd.len
    else
      vd.fill = util.clamp(vd.fill + d, 0, vd.len)
    end
    apply_euclid(v)
  elseif mode == 2 or mode == 3 then
    local v = mode - 1
    local vd = patterns[cur_pat][v]
    local s = vd.steps[sel_step[v]]
    if n == 2 then
      if shift then s.rat = util.clamp(s.rat + d, 1, 4)
      else s.prob = util.clamp(s.prob + d * 5, 0, 100) end
    else
      if shift then vd.len = util.clamp(vd.len + d, 1, NUM_STEPS)
      else s.mod = util.clamp(s.mod + d, -1, 127) end
    end
  else -- PERF
    if n == 2 then params:delta(shift and "k_lfo" or "k_crush", d)
    else params:delta(shift and "k_wet" or "k_dec", d) end
  end
end

---------------------------------------------------------------
-- screen
---------------------------------------------------------------

local function draw_lane(v, y)
  local vd = patterns[cur_pat][v]
  screen.level(flash[v] > 0 and 15 or 4)
  screen.move(0, y + 6)
  screen.text(v)
  for i = 1, NUM_STEPS do
    local x = 6 + (i - 1) * 7.6
    local s = vd.steps[i]
    if i <= vd.len then
      if s.on then
        screen.level(s.acc and 15 or (s.prob < 100 and 5 or 9))
        screen.rect(x, y, 6, 7); screen.fill()
        if s.rat > 1 then screen.level(0); screen.rect(x + 2, y + 2, 2, 3); screen.fill() end
      else
        screen.level(2); screen.rect(x + 0.5, y + 0.5, 5, 6); screen.stroke()
      end
      if s.mod and s.mod >= 0 then screen.level(10); screen.pixel(x + 2, y - 2); screen.fill() end
      if i == pos[v] and running then screen.level(15); screen.rect(x, y + 8, 6, 1); screen.fill() end
      if (mode - 1) == v and sel_step[v] == i then
        screen.level(12); screen.rect(x - 1, y - 1, 8, 9); screen.stroke()
      end
    end
  end
end

function redraw()
  screen.clear()
  screen.font_size(8)
  screen.level(15)
  screen.move(0, 7)
  screen.text(MODE_NAMES[mode])
  screen.level(6)
  screen.move(44, 7)
  screen.text(string.format("%d bpm", math.floor(clock.get_tempo() + 0.5)))
  screen.move(84, 7)
  screen.text("P" .. cur_pat .. (queued_pat and (">" .. queued_pat) or ""))
  screen.level(rec and 15 or 2)
  screen.move(108, 7); screen.text("R")
  screen.level(running and 15 or 2)
  screen.move(118, 7); screen.text(running and ">" or "||")

  draw_lane(1, 16)
  draw_lane(2, 32)

  screen.level(5)
  screen.move(0, 62)
  if msg_t > 0 then
    screen.level(15); screen.text(msg)
  elseif mode == 1 then
    local p = patterns[cur_pat]
    screen.text(string.format("fill %d/%d  %d/%d  sw%d", p[1].fill, p[1].len, p[2].fill, p[2].len, params:get("swing")))
  elseif mode == 2 or mode == 3 then
    local v = mode - 1
    local s = patterns[cur_pat][v].steps[sel_step[v]]
    screen.text(string.format("s%d p%d r%d m%s L%d", sel_step[v], s.prob, s.rat,
      s.mod < 0 and "--" or tostring(s.mod), patterns[cur_pat][v].len))
  else
    screen.text(string.format("cr%d dc%d  in:%s", params:get("k_crush"), params:get("k_dec"), last_in))
  end
  screen.update()
end

---------------------------------------------------------------
-- lifecycle
---------------------------------------------------------------

function init()
  init_patterns()
  load_patterns("last.data")
  add_params()
  params:bang()
  sc_init()
  dry_on()
  grid_init()

  clock.transport.start = function() reset_pos(); running = true end
  clock.transport.stop = function()
    local s = params:get("zoia_stop")
    if s == 2 then reset_pos() elseif s == 3 then running = false; reset_pos() end
  end

  clock.run(seq_loop)
  clock.run(function()
    while true do
      clock.sleep(1 / 15)
      for v = 1, 2 do if flash[v] > 0 then flash[v] = flash[v] - 1 end end
      if msg_t > 0 then msg_t = msg_t - 1 end
      redraw()
      grid_redraw()
    end
  end)
end

function cleanup()
  save_patterns("last.data")
  softcut.poll_stop_phase()
  audio.level_monitor(1)
end
