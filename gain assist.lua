-- @description Gain Assist
-- @author ChimRichalds
-- @version 1.0

local reaper = reaper

-- Math compatibility
if not math.log10 then
  math.log10 = function(x) return math.log(x) / math.log(10) end
end

-- DEFAULT CONFIG
local SCRIPT_NAME = "Gain Assist"
local DEFAULT_PEAK_CEILING = 0
local DEFAULT_CORRECTION_STRENGTH = 0
local DEFAULT_SEPARATION_SENSITIVITY = 0.00
local DEFAULT_TRIM = 0
local DEFAULT_PRE_LIMIT_BOOST = 0
local DEFAULT_NUM_BARS = 10000
local DEFAULT_MIN_DB = -150
local DEFAULT_MAX_DB = -11
local DEFAULT_CURVE_POWER = 14.0
local DEFAULT_RESOLUTION_MS = 10
local DEFAULT_REDUCE_POINTS = true
local DEFAULT_RAW_WAVEFORM_OPACITY = 30
local DEFAULT_GATE_OVERLAY_OPACITY = 20

-- NEW: Gate defaults
local DEFAULT_GATE_ENABLED = false
local DEFAULT_GATE_THRESHOLD = -40
local DEFAULT_GATE_HOLD_TIME = 0.3
local DEFAULT_GATE_REDUCTION = -60
local DEFAULT_GATE_ONSET_TIME = 0.04

-- Debug toggle
local showDebug = false
local function debugMsg(msg) if showDebug then reaper.ShowConsoleMsg(msg) end end

-- Persistent State
local function getExtState(key, default)
  local state = reaper.GetExtState(SCRIPT_NAME, key)
  if state == "" then return default end
  local num = tonumber(state)
  if num ~= nil then return num end
  return state
end
local function setExtState(key, value)
  reaper.SetExtState(SCRIPT_NAME, key, tostring(value), true)
end

-- Load/Save Settings
local function loadSettings()
  local peakCeiling = getExtState("peakCeiling", DEFAULT_PEAK_CEILING)
  local correctionStrength = getExtState("correctionStrength", DEFAULT_CORRECTION_STRENGTH)
  local separationSensitivity = getExtState("separationSensitivity", DEFAULT_SEPARATION_SENSITIVITY)
  local trim = getExtState("trim", DEFAULT_TRIM)
  local preLimitBoost = getExtState("preLimitBoost", DEFAULT_PRE_LIMIT_BOOST)
  local numBars = getExtState("numBars", DEFAULT_NUM_BARS)
  local minDB = getExtState("minDB", DEFAULT_MIN_DB)
  local maxDB = getExtState("maxDB", DEFAULT_MAX_DB)
  local curvePower = getExtState("curvePower", DEFAULT_CURVE_POWER)
  local resolutionMs = getExtState("resolutionMs", DEFAULT_RESOLUTION_MS)
  local reducePoints = true
  local showDisplaySettings = getExtState("showDisplaySettings", 0) == 1
  local rawWaveformOpacity = getExtState("rawWaveformOpacity", DEFAULT_RAW_WAVEFORM_OPACITY)
  local showTooltips = getExtState("showTooltips", 1) == 1
  local gateEnabled = getExtState("gateEnabled", DEFAULT_GATE_ENABLED and 1 or 0) == 1
  local gateThreshold = getExtState("gateThreshold", DEFAULT_GATE_THRESHOLD)
  local gateHoldTime = getExtState("gateHoldTime", DEFAULT_GATE_HOLD_TIME)
  local gateReduction = getExtState("gateReduction", DEFAULT_GATE_REDUCTION)
  local gateOnsetTime = getExtState("gateOnsetTime", DEFAULT_GATE_ONSET_TIME)
  local gateOverlayOpacity = tonumber(getExtState("gateOverlayOpacity", DEFAULT_GATE_OVERLAY_OPACITY)) or DEFAULT_GATE_OVERLAY_OPACITY
  return peakCeiling, correctionStrength, separationSensitivity, trim, preLimitBoost, numBars, minDB, maxDB, curvePower, resolutionMs, reducePoints, showDisplaySettings, rawWaveformOpacity, showTooltips, gateEnabled, gateThreshold, gateHoldTime, gateReduction, gateOnsetTime, gateOverlayOpacity
end

local function saveSettings(peakCeiling, correctionStrength, separationSensitivity, trim, preLimitBoost, resolutionMs, reducePoints, rawWaveformOpacity, showTooltips, gateEnabled, gateThreshold, gateHoldTime, gateReduction, gateOnsetTime, gateOverlayOpacity)
  setExtState("peakCeiling", peakCeiling)
  setExtState("correctionStrength", correctionStrength)
  setExtState("separationSensitivity", separationSensitivity)
  setExtState("trim", trim)
  setExtState("preLimitBoost", preLimitBoost)
  setExtState("resolutionMs", resolutionMs)
  setExtState("reducePoints", 1)
  setExtState("rawWaveformOpacity", rawWaveformOpacity)
  setExtState("showTooltips", showTooltips and 1 or 0)
  setExtState("gateEnabled", gateEnabled and 1 or 0)
  setExtState("gateThreshold", gateThreshold)
  setExtState("gateHoldTime", gateHoldTime)
  setExtState("gateReduction", gateReduction)
  setExtState("gateOnsetTime", gateOnsetTime)
  setExtState("gateOverlayOpacity", gateOverlayOpacity)
end

-- Conversion
local function dBToLinear(dB) 
  if not dB or dB ~= dB then return 1.0 end
  return 10^(dB/20) 
end

local function linearTodB(linear) 
  if not linear or linear ~= linear then return -150 end
  if linear <= 0.00001 then return -150 end 
  return 20 * math.log10(linear) 
end

-- Helper function to detect channel count from source
local function getSourceChannelCount(take)
  local src = reaper.GetMediaItemTake_Source(take)
  if not src then return 1 end
  local numChannels = reaper.GetMediaSourceNumChannels(src)
  return math.max(1, numChannels)
end

-- ===== Audio accessor mgmt =====
local audioAccessors, audioBuffers = {}, {}

local function getAudioAccessor(take)
  if not take then return nil end
  if audioAccessors[take] then return audioAccessors[take] end
  local aa = reaper.CreateTakeAudioAccessor(take)
  audioAccessors[take] = aa
  return aa
end

local function releaseAudioAccessor(take)
  if audioAccessors[take] then reaper.DestroyAudioAccessor(audioAccessors[take]); audioAccessors[take] = nil end
  if audioBuffers[take] then audioBuffers[take] = nil end
end

local function getAudioBuffer(take, size)
  if not audioBuffers[take] or #audioBuffers[take] < size then audioBuffers[take] = reaper.new_array(size) end
  return audioBuffers[take]
end

-- Helper: unified accessor bounds (PROJECT TIME) + derived itemLen
local function get_accessor_bounds(take)
  if not take then return nil end
  local aa = getAudioAccessor(take)
  if not aa then return nil end
  local aaStart = reaper.GetAudioAccessorStartTime(aa)
  local aaEnd   = reaper.GetAudioAccessorEndTime(aa)
  local src     = reaper.GetMediaItemTake_Source(take)
  local sr      = reaper.GetMediaSourceSampleRate(src)
  local itemLen = math.max(0, aaEnd - aaStart)
  return aa, aaStart, aaEnd, sr, itemLen
end

-- ===== RMS/phrase detection (accessor-based timing) WITH ITEM VOLUME CORRECTION =====
local function getRMSLevels(take, item)
  local aa, aaStart, aaEnd, samplerate, itemLen = get_accessor_bounds(take)
  if not aa or samplerate <= 0 or itemLen <= 0 then if take then releaseAudioAccessor(take) end; return nil end

  local itemVolume = reaper.GetMediaItemInfo_Value(item, "D_VOL")
  local numChannels = getSourceChannelCount(take)
  local windowSize = 0.1
  local numWindows = math.max(0, math.floor(itemLen / windowSize))
  local levels = {}

  for i = 0, numWindows - 1 do
    local readTime = aaStart + (i * windowSize)
    local numSamples = math.floor(samplerate * windowSize)
    if numSamples > 0 and numSamples <= 1000000 then
      local buf = getAudioBuffer(take, numSamples * numChannels * 2)
      buf.clear()
      local read = reaper.GetAudioAccessorSamples(aa, samplerate, numChannels, readTime, numSamples, buf)
      if read > 0 then
        local sum, t = 0, buf.table()
        -- Process stereo interleaved data: skip every other pair to avoid L/R aliasing
        for j = 1, #t, numChannels * 2 do
          local s = t[j] * itemVolume
          sum = sum + s * s
        end
        levels[i+1] = math.sqrt(sum / math.max(1, math.floor(#t / (numChannels * 2))))
      else
        levels[i+1] = 0
      end
    end
  end

  releaseAudioAccessor(take)
  return levels, itemLen
end

-- Detect silence gaps using relative threshold
local function detectSilenceGaps(levels, sensitivityPercentage)
  if not levels or #levels == 0 then return {} end
  local sorted = {}
  for _, level in ipairs(levels) do sorted[#sorted+1] = level end
  table.sort(sorted)
  local medianRMS = sorted[math.ceil(#sorted / 2)]
  if medianRMS <= 0 then return {} end

  local silenceThreshold = medianRMS * sensitivityPercentage
  local gaps, gapStartIdx = {}, nil
  for i = 1, #levels do
    local silent = levels[i] < silenceThreshold
    if silent and not gapStartIdx then
      gapStartIdx = i
    elseif not silent and gapStartIdx then
      local gapEndIdx = i - 1
      if gapEndIdx >= gapStartIdx then gaps[#gaps+1] = {startIdx=gapStartIdx, endIdx=gapEndIdx} end
      gapStartIdx = nil
    end
  end
  if gapStartIdx then gaps[#gaps+1] = {startIdx=gapStartIdx, endIdx=#levels} end
  return gaps
end

local function gapsToBreakpoints(gaps, itemLen, windowSize)
  if not gaps or #gaps == 0 then return {} end
  local breakpoints = {}
  for _, gap in ipairs(gaps) do
    local midIdx = (gap.startIdx + gap.endIdx) / 2
    local midTime = (midIdx - 1) * windowSize
    midTime = math.max(0, math.min(itemLen, midTime))
    breakpoints[#breakpoints+1] = midTime
  end
  return breakpoints
end

local function detectPhrases(take, item, separationSensitivity)
  local phraseStartTime = reaper.time_precise()
  local levels, itemLen = getRMSLevels(take, item)
  if not levels or #levels == 0 then return nil end
  local windowSize = 0.1
  local gaps = detectSilenceGaps(levels, separationSensitivity)
  local breakpoints = gapsToBreakpoints(gaps, itemLen, windowSize)

  local phrases = {}
  local currentStart = 0
  for _, bp in ipairs(breakpoints) do
    phrases[#phrases+1] = {startTime=currentStart, endTime=bp, avgLevel=0, isEdge=false}
    currentStart = bp
  end
  if currentStart < itemLen then
    phrases[#phrases+1] = {startTime=currentStart, endTime=itemLen, avgLevel=0, isEdge=false}
  end
  if #phrases > 0 then
    phrases[1].isEdge = true
    if #phrases > 1 then phrases[#phrases].isEdge = true end
  end

  for _, ph in ipairs(phrases) do
    local startWin = math.floor(ph.startTime / windowSize) + 1
    local endWin = math.min(math.floor(ph.endTime / windowSize) + 1, #levels)
    local sum, count = 0, 0
    for i = startWin, endWin do if levels[i] then sum = sum + levels[i]; count = count + 1 end end
    ph.avgLevel = count > 0 and (sum / count) or 0
  end

  local dt = reaper.time_precise() - phraseStartTime
  debugMsg(string.format("Phrase detection time: %.3fs, phrases: %d\n", dt, #phrases))
  return phrases, dt
end

---- ===== Gate Envelope Generation - OPTIMIZED WITH STEREO DECIMATION =====
local function generateGateEnvelope(take, item, gateThreshold, gateHoldTime, gateReduction, gateOnsetTime)
  local aa, aaStart, aaEnd, samplerate, itemLen = get_accessor_bounds(take)
  if not aa or samplerate <= 0 or itemLen <= 0 then return nil end

  local itemVolume = reaper.GetMediaItemInfo_Value(item, "D_VOL")
  local numChannels = getSourceChannelCount(take)
  local gatePoints = {}
  local windowSize = 0.01
  local numWindows = math.ceil(itemLen / windowSize)
  local thresholdLin = dBToLinear(gateThreshold)
  local reductionLin = dBToLinear(gateReduction)
  
  -- Lookahead window: how far ahead to scan for rising edges
  local lookaheadWindows = math.ceil(gateOnsetTime / windowSize)
  
  -- Pre-scan: identify all threshold crossing points (ONE scan, store results)
  local aboveThreshold = {}  -- aboveThreshold[i] = true if window i has signal above threshold
  local belowThreshold = true
  
  for i = 1, numWindows do
    local readTime = aaStart + (i - 1) * windowSize
    local numSamples = math.min(math.floor(samplerate * windowSize), 100000)
    
    if numSamples > 0 then
      local buf = getAudioBuffer(take, numSamples * numChannels * 2)
      buf.clear()
      local read = reaper.GetAudioAccessorSamples(aa, samplerate, numChannels, readTime, numSamples, buf)
      
      local maxLevel = 0
      if read > 0 then
        local t = buf.table()
        -- Process stereo interleaved data: skip every other pair to avoid L/R aliasing
        for j = 1, #t, numChannels * 2 do
          local s = math.abs(t[j] * itemVolume)
          if s > maxLevel then maxLevel = s end
        end
      end
      
      aboveThreshold[i] = (maxLevel > thresholdLin)
    else
      aboveThreshold[i] = false
    end
  end
  
  -- Single pass: compute gate reductions using precomputed threshold data
  local belowThresholdTime = 0
  
  for i = 1, numWindows do
    local itemTime = (i - 1) * windowSize
    local isAboveThreshold = aboveThreshold[i]
    local reduction = 1.0
    
    if isAboveThreshold then
      -- Signal is above threshold: gate fully open
      belowThresholdTime = 0
      reduction = 1.0
      
    else
      -- Signal is below threshold
      belowThresholdTime = belowThresholdTime + windowSize
      
      if belowThresholdTime <= gateHoldTime then
        -- Within hold time: gate still open
        reduction = 1.0
        
      else
        -- Past hold time: check for upcoming rising edge
        local timePastHold = belowThresholdTime - gateHoldTime
        local nextRisingEdge = nil
        
        -- Scan ahead for next rising edge (lookahead)
        for j = i + 1, math.min(i + lookaheadWindows, numWindows) do
          local wasBelow = not aboveThreshold[j - 1]
          local isNowAbove = aboveThreshold[j]
          
          if wasBelow and isNowAbove then
            nextRisingEdge = j
            break
          end
        end
        
        if nextRisingEdge then
          -- Calculate distance to rising edge
          local windowsUntilEdge = nextRisingEdge - i
          local timeUntilEdge = windowsUntilEdge * windowSize
          
          if timeUntilEdge < gateOnsetTime then
            -- We're in the anticipatory fade-in window
            -- Fade from reduction to 1.0 over gateOnsetTime
            local fadeProgress = (gateOnsetTime - timeUntilEdge) / gateOnsetTime
            reduction = reductionLin + (1.0 - reductionLin) * fadeProgress
          else
            -- Not yet in anticipatory window: apply fade-out from hold time
            if timePastHold < gateOnsetTime then
              -- Fading from open to reduced
              local fadeProgress = timePastHold / gateOnsetTime
              reduction = 1.0 + (reductionLin - 1.0) * fadeProgress
            else
              -- Fully reduced, no upcoming edge in lookahead
              reduction = reductionLin
            end
          end
        else
          -- No rising edge found in lookahead: apply normal fade-out
          if timePastHold < gateOnsetTime then
            local fadeProgress = timePastHold / gateOnsetTime
            reduction = 1.0 + (reductionLin - 1.0) * fadeProgress
          else
            reduction = reductionLin
          end
        end
      end
    end
    
    gatePoints[i] = {time = itemTime, reduction = reduction}
  end
  
  return gatePoints
end

-- Adjustments
local function calculateVolumeAdjustments(phrases, correctionStrength, preLimitBoost)
  if not phrases or #phrases == 0 then return {} end
  local balancingPhrases = {}
  for _, ph in ipairs(phrases) do if not ph.isEdge then balancingPhrases[#balancingPhrases+1] = ph.avgLevel end end
  if #balancingPhrases == 0 then return {} end
  table.sort(balancingPhrases)
  local target = balancingPhrases[math.ceil(#balancingPhrases/2)]
  local adj = {}
  for _, ph in ipairs(phrases) do
    if ph.isEdge then
      adj[ph] = 1.0
    elseif ph.avgLevel > 0 then
      local ratio = target / ph.avgLevel
      local a = 1 + (ratio - 1) * correctionStrength
      adj[ph] = a
    end
  end
  return adj
end

local function recalculatePhraseLevels(take, item, phrases)
  if not take or not phrases or #phrases == 0 then return end
  local levels, _ = getRMSLevels(take, item)
  if not levels then return end
  local windowSize = 0.1
  for _, ph in ipairs(phrases) do
    local startWin = math.floor(ph.startTime / windowSize) + 1
    local endWin = math.min(math.floor(ph.endTime / windowSize) + 1, #levels)
    local sum, count = 0, 0
    for i = startWin, endWin do if levels[i] then sum = sum + levels[i]; count = count + 1 end end
    ph.avgLevel = count > 0 and (sum / count) or 0
  end
end

-- ===== Waveform data (raw + adjusted) - MONO ONLY =====
local function getRawWaveform(item, numSamples)
  local take = reaper.GetActiveTake(item)
  if not take or reaper.TakeIsMIDI(take) then return nil, 0 end
  local itemVolume = reaper.GetMediaItemInfo_Value(item, "D_VOL")

  local aa, aaStart, aaEnd, samplerate, itemLen = get_accessor_bounds(take)
  if not aa or samplerate <= 0 or itemLen <= 0 then if take then releaseAudioAccessor(take) end; return nil, 0 end

  local numChannels = getSourceChannelCount(take)
  local data = {}
  local windowSize = itemLen / numSamples

  for i = 0, numSamples - 1 do
    local readTime = aaStart + (i * windowSize)
    local numSamps = math.min(math.floor(samplerate * windowSize), 1000000)
    if numSamps <= 0 then
      data[i+1] = {pos=0, neg=0}
    else
      local buf = getAudioBuffer(take, numSamps * numChannels * 2)
      buf.clear()
      local read = reaper.GetAudioAccessorSamples(aa, samplerate, numChannels, readTime, numSamps, buf)
      if read > 0 then
        local pos, neg, t = 0, 0, buf.table()
        -- Process stereo interleaved data: skip every other value to avoid L/R aliasing
        for j = 1, #t, numChannels * 2 do
          local s = t[j] * itemVolume
          if s > pos then pos = s end
          if s < neg then neg = s end
        end
        data[i+1] = {pos=pos, neg=math.abs(neg)}
      else
        data[i+1] = {pos=0, neg=0}
      end
    end
  end

  releaseAudioAccessor(take)
  return data, linearTodB(itemVolume)
end

local function getAdjustedWaveform(item, numSamples, phrases, adjustments, peakCeiling, trim, preLimitBoost)
  local take = reaper.GetActiveTake(item)
  if not take or reaper.TakeIsMIDI(take) then return nil, 0 end
  local itemVolume = reaper.GetMediaItemInfo_Value(item, "D_VOL")

  local aa, aaStart, aaEnd, samplerate, itemLen = get_accessor_bounds(take)
  if not aa or samplerate <= 0 or itemLen <= 0 then if take then releaseAudioAccessor(take) end; return nil, 0 end

  local numChannels = getSourceChannelCount(take)
  local data = {}
  local peakLin = peakCeiling < 0 and dBToLinear(peakCeiling) or math.huge
  local trimLin = dBToLinear(trim)
  local preLimitLin = dBToLinear(preLimitBoost)
  local windowSize = itemLen / numSamples

  for i = 0, numSamples - 1 do
    local readTime = aaStart + (i * windowSize)
    local numSamps = math.min(math.floor(samplerate * windowSize), 1000000)
    if numSamps <= 0 then
      data[i+1] = {pos=0, neg=0}
    else
      local buf = getAudioBuffer(take, numSamps * numChannels * 2)
      buf.clear()
      local read = reaper.GetAudioAccessorSamples(aa, samplerate, numChannels, readTime, numSamps, buf)
      if read > 0 then
        local itemTime = (readTime - aaStart)
        local volAdj = 1.0
        for ph, a in pairs(adjustments) do
          if itemTime >= ph.startTime and itemTime <= ph.endTime then volAdj = volAdj * a; break end
        end
        
        local pos, neg, t = 0, 0, buf.table()
        -- Process stereo interleaved data: skip every other value to avoid L/R aliasing
        for j = 1, #t, numChannels * 2 do
          local s = t[j] * itemVolume * volAdj * preLimitLin
          if math.abs(s) > peakLin then s = s > 0 and peakLin or -peakLin end
          s = s * trimLin
          if s > pos then pos = s end
          if s < neg then neg = s end
        end
        data[i+1] = {pos=pos, neg=math.abs(neg)}
      else
        data[i+1] = {pos=0, neg=0}
      end
    end
  end

  releaseAudioAccessor(take)
  return data, linearTodB(itemVolume)
end

-- ===== Drawing helpers =====
local function drawWaveform(drawList, rawData, adjustedData, x, y, width, height, minDB, maxDB, curvePower, zoomLevel, zoomCenter, rawOpacity)
  if not adjustedData or #adjustedData == 0 then return end
  local centerY = y + height / 2
  local dbRange = maxDB - minDB

  local totalSamples = #adjustedData
  local visibleSamples = math.max(50, math.floor(totalSamples / zoomLevel))
  local startSample = math.max(1, math.min(totalSamples - visibleSamples, math.floor(zoomCenter * totalSamples - visibleSamples / 2)))
  local endSample = math.min(totalSamples, startSample + visibleSamples)
  local barWidth = width / visibleSamples

  reaper.ImGui_DrawList_AddLine(drawList, x, centerY, x + width, centerY, 0x808080FF, 1)

  local function dbToHeight(db, maxHeight)
    if db <= minDB then return 0 end
    if db >= maxDB then return maxHeight end
    local normalized = (db - minDB) / dbRange
    local curved = normalized ^ curvePower
    return curved * maxHeight
  end

  local rawOpacityHex = math.floor(rawOpacity * 2.55)
  local rawColor = 0x40808000 + rawOpacityHex

  if rawData and #rawData > 0 and rawOpacity > 0 then
    for i = startSample, endSample do
      if i <= #rawData then
        local barX = x + (i - startSample) * barWidth
        local posDB = linearTodB(rawData[i].pos)
        local negDB = linearTodB(rawData[i].neg)
        local posH = dbToHeight(posDB, height / 2)
        local negH = dbToHeight(negDB, height / 2)
        if posH > 0 then reaper.ImGui_DrawList_AddRectFilled(drawList, barX, centerY - posH, barX + barWidth + 1, centerY, rawColor) end
        if negH > 0 then reaper.ImGui_DrawList_AddRectFilled(drawList, barX, centerY, barX + barWidth + 1, centerY + negH, rawColor) end
      end
    end
  end

  for i = startSample, endSample do
    local barX = x + (i - startSample) * barWidth
    local posDB = linearTodB(adjustedData[i].pos)
    local negDB = linearTodB(adjustedData[i].neg)
    local posH = dbToHeight(posDB, height / 2)
    local negH = dbToHeight(negDB, height / 2)
    if posH > 0 then reaper.ImGui_DrawList_AddRectFilled(drawList, barX, centerY - posH, barX + barWidth + 1, centerY, 0x4080FFFF) end
    if negH > 0 then reaper.ImGui_DrawList_AddRectFilled(drawList, barX, centerY, barX + barWidth + 1, centerY + negH, 0x4080FFFF) end
  end

  local dbMarks = {0, -6, -12, -18, -24, -30, -40, -60, -80, -100, -120}
  for _, db in ipairs(dbMarks) do
    if db >= minDB and db <= maxDB then
      local yTop = centerY - dbToHeight(db, height / 2)
      local yBot = centerY + dbToHeight(db, height / 2)
      reaper.ImGui_DrawList_AddLine(drawList, x - 5, yTop, x, yTop, 0xFFFFFF80, 1)
      reaper.ImGui_DrawList_AddLine(drawList, x - 5, yBot, x, yBot, 0xFFFFFF80, 1)
    end
  end

  if zoomLevel > 1.01 then
    reaper.ImGui_DrawList_AddText(drawList, x + 5, y + 5, 0xFFFFFFFF, string.format("Zoom: %.1fx", zoomLevel))
  end
end

-- ===== Playhead Drawing =====
local function drawPlayhead(drawList, item, x, y, w, h, zoomLevel, zoomCenter, totalSamples, startSample, visibleSamples)
  if not item then return end
  
  local isPlaying = reaper.GetPlayState() & 1 == 1
  local cursorPos = isPlaying and reaper.GetPlayPosition() or reaper.GetCursorPosition()
  local itemStart = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
  local itemLength = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
  local itemEnd = itemStart + itemLength
  
  -- Check if cursor is within this item
  if cursorPos >= itemStart and cursorPos <= itemEnd then
    -- Get the take to access audio bounds
    local take = reaper.GetActiveTake(item)
    if not take then return end
    
    local aa, aaStart, aaEnd, _, audioItemLen = get_accessor_bounds(take)
    if not aa then return end
    
    -- Calculate offset within the item (in item time, not project time)
    local itemOffset = cursorPos - itemStart
    
    -- Map item time to waveform sample position
    local samplePos = math.floor((itemOffset / audioItemLen) * totalSamples) + 1
    
    -- Check if sample position is visible in current zoom/pan
    if samplePos >= startSample and samplePos <= startSample + visibleSamples then
      -- Calculate pixel X position on waveform
      local xPos = x + ((samplePos - startSample) / visibleSamples) * w
      
      -- Draw playhead line (bright green, semi-thick)
      reaper.ImGui_DrawList_AddLine(drawList, xPos, y, xPos, y + h, 0x00FF00FF, 2)
      
      -- Optional: Add a subtle glow/highlight effect by drawing a slightly thicker semi-transparent line behind it
      reaper.ImGui_DrawList_AddLine(drawList, xPos, y, xPos, y + h, 0x00FF0044, 4)
    end
  end
end

-- ===== UPDATE drawGateOverlay() function =====
local function drawGateOverlay(drawList, gatePoints, adjustedData, item, x, y, width, height, zoomLevel, zoomCenter, gateOpacity)
  if not gatePoints or #gatePoints == 0 then return end
  if not adjustedData or #adjustedData == 0 then return end
  
  local take = reaper.GetActiveTake(item)
  if not take then return end
  
  local aa, aaStart, aaEnd, samplerate, itemLen = get_accessor_bounds(take)
  if not aa then return end
  
  local totalSamples = #adjustedData
  local visibleSamples = math.max(50, math.floor(totalSamples / zoomLevel))
  local startSample = math.max(1, math.min(totalSamples - visibleSamples, math.floor(zoomCenter * totalSamples - visibleSamples / 2)))
  local endSample = math.min(totalSamples, startSample + visibleSamples)
  local barWidth = width / visibleSamples
  
  local centerY = y + height / 2
  local halfH = height / 2
  
  -- Gate overlay color: red with variable opacity
  local gateOpacityHex = math.floor(gateOpacity * 2.55)
  local gateOverlayColor = 0xFF000000 + gateOpacityHex
  
  -- Draw gate reduction regions
  for i = startSample, endSample do
    local barX = x + (i - startSample) * barWidth
    
    -- Map waveform sample index to item time
    local windowSize = itemLen / totalSamples
    local itemTime = (i - 1) * windowSize
    
    -- Find corresponding gate point at 0.01 second resolution
    local gateIdx = math.floor(itemTime / 0.01) + 1
    
    if gateIdx >= 1 and gateIdx <= #gatePoints then
      local gatePoint = gatePoints[gateIdx]
      local reduction = gatePoint.reduction
      
      -- Only draw overlay where gate is actively reducing (not at full 1.0)
      if reduction < 0.99 then
        -- Draw overlay for the full height at this position
        reaper.ImGui_DrawList_AddRectFilled(drawList, barX, y, barX + barWidth, y + height, gateOverlayColor)
      end
    end
  end
end

-- Phrase breakpoints visualization
local phraseMarkerPositions = {}
local function drawPhraseMarkers(drawList, phrases, adjustedData, x, y, width, height, zoomLevel, zoomCenter, startSample, isDraggingMarker, draggedMarkerIdx, draggedMarkerX, hoverMarkerIdx, markersToDelete)
  if not phrases or not adjustedData or #adjustedData == 0 then return end
  phraseMarkerPositions = {}
  local centerY = y + height / 2
  local totalSamples = #adjustedData
  local visibleSamples = math.max(50, math.floor(totalSamples / zoomLevel))
  local itemLen = 0
  for _, ph in ipairs(phrases) do if ph.endTime > itemLen then itemLen = ph.endTime end end

  for i = 1, #phrases - 1 do
    local breakpointTime = phrases[i].endTime
    local samplePos = math.floor((breakpointTime / itemLen) * totalSamples) + 1
    if samplePos >= startSample and samplePos <= startSample + visibleSamples then
      local px = x + (samplePos - startSample) * (width / visibleSamples)

      local isFirstMarker = (i == 1)
      local isLastMarker  = (i == #phrases - 1)
      local isEdgeMarker  = isFirstMarker or isLastMarker
      local isMarkedForDeletion = markersToDelete and markersToDelete[i]

      local baseColor, baseBorderColor, hoverColor, hoverBorderColor, dragColor
      if isMarkedForDeletion then
        baseColor, baseBorderColor = 0xFF0000FF, 0xFF0000FF
        hoverColor, hoverBorderColor = 0xFF0000FF, 0xFF0000FF
        dragColor = 0xFF0000FF
      else
        baseColor = isEdgeMarker and 0xFFE400FF or 0xFFFFFFFF
        baseBorderColor = baseColor
        hoverColor, hoverBorderColor = baseColor, baseColor
        dragColor = 0xFF00FFFF
      end

      if isDraggingMarker and draggedMarkerIdx == i and draggedMarkerX then
        px = draggedMarkerX
        reaper.ImGui_DrawList_AddCircleFilled(drawList, px, centerY, 6, dragColor, 12)
        reaper.ImGui_DrawList_AddCircle(drawList, px, centerY, 8, dragColor, 12, 2)
      elseif hoverMarkerIdx == i then
        reaper.ImGui_DrawList_AddCircleFilled(drawList, px, centerY, 6, hoverColor, 12)
        reaper.ImGui_DrawList_AddCircle(drawList, px, centerY, 8, hoverBorderColor, 12, 2)
      else
        reaper.ImGui_DrawList_AddCircleFilled(drawList, px, centerY, 5, baseColor, 12)
        if isMarkedForDeletion then
          reaper.ImGui_DrawList_AddCircle(drawList, px, centerY, 7, baseBorderColor, 12, 2)
        end
      end

      phraseMarkerPositions[#phraseMarkerPositions+1] = {x=px, y=centerY, markerIdx=i, time=breakpointTime}
    end
  end
end

-- Time ruler drawing
local function drawTimeRuler(drawList, item, x, y, width, height, zoomLevel, zoomCenter, totalSamples, startSample, visibleSamples)
  if not item then return end
  reaper.ImGui_DrawList_AddRectFilled(drawList, x, y, x + width, y + height, 0x0F0F0FF0)

  local take = reaper.GetActiveTake(item)
  if not take then return end

  local aa, aaStart, aaEnd, _, itemLen = get_accessor_bounds(take)
  if not aa then return end

  local itemPos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
  local startTime = itemPos + (startSample / totalSamples) * itemLen
  local endTime   = itemPos + ((startSample + visibleSamples) / totalSamples) * itemLen
  local timeRange = endTime - startTime

  local divisions = {1, 2, 5, 10, 30, 60, 120, 300, 600}
  local targetDivisions = math.max(3, math.min(10, width / 80))
  local bestDivision = divisions[1]
  for _, div in ipairs(divisions) do
    if timeRange / div <= targetDivisions then bestDivision = div; break end
  end

  local firstMark = math.ceil(startTime / bestDivision) * bestDivision
  for markTime = firstMark, endTime, bestDivision do
    if markTime >= startTime and markTime <= endTime then
      local relX = (markTime - startTime) / timeRange
      local px = x + relX * width
      reaper.ImGui_DrawList_AddLine(drawList, px, y, px, y + height * 0.3, 0xFFFFFFFF, 1)
      local hours = math.floor(markTime / 3600)
      local minutes = math.floor((markTime % 3600) / 60)
      local seconds = markTime % 60
      local timeText
      if hours > 0 then
        timeText = string.format("%d:%02d:%05.2f", hours, minutes, seconds)
      elseif minutes > 0 then
        timeText = string.format("%d:%05.2f", minutes, seconds)
      else
        timeText = string.format("%.2f", seconds)
      end
      local textWidth = #timeText * 7
      reaper.ImGui_DrawList_AddText(drawList, px - textWidth/2, y + height * 0.4, 0xFFFFFFFF, timeText)
    end
  end
end

-- ===== Peak ceiling helpers =====
local function db_to_halfheight(db, minDB, maxDB, curvePower, halfH)
  if db <= minDB then return 0 end
  if db >= maxDB then return halfH end
  local norm = (db - minDB) / (maxDB - minDB)
  return (norm ^ curvePower) * halfH
end
local function halfheight_to_db(h, minDB, maxDB, curvePower, halfH)
  if h <= 0 then return minDB end
  if h >= halfH then return maxDB end
  local norm = (h / halfH) ^ (1.0 / curvePower)
  return minDB + norm * (maxDB - minDB)
end

-- Envelope simplification/apply
local function simplifyEnvelope(env)
  local pointCount = reaper.CountEnvelopePoints(env)
  if pointCount <= 2 then return end
  local pts = {}
  for i = 0, pointCount - 1 do
    local _, time, value, shape, tension, selected = reaper.GetEnvelopePoint(env, i)
    pts[#pts+1] = {time=time, value=value, shape=shape, tension=tension, selected=selected}
  end
  table.sort(pts, function(a,b) return a.time < b.time end)
  local keep = {}
  keep[#keep+1] = pts[1]
  local i = 2
  while i <= #pts do
    local s = i
    local v = pts[i].value
    while i <= #pts and math.abs(pts[i].value - v) < 0.0001 do i = i + 1 end
    local e = i - 1
    if e - s >= 2 then
      keep[#keep+1] = pts[s]; keep[#keep+1] = pts[e]
    else
      for j = s, e do keep[#keep+1] = pts[j] end
    end
  end
  local itemLen = reaper.GetEnvelopeInfo_Value(env, "LENGTH")
  reaper.DeleteEnvelopePointRange(env, -1, itemLen + 1000)
  for _, p in ipairs(keep) do reaper.InsertEnvelopePoint(env, p.time, p.value, p.shape, p.tension, p.selected, true) end
  reaper.Envelope_SortPoints(env)
end


local gateEnvelopeCache = {}

local function getCachedGateEnvelope(take, item, gateThreshold, gateHoldTime, gateReduction, gateOnsetTime)
  if not take or not item then return nil end
  
  -- Get audio accessor bounds - these change when item is trimmed
  local aa, aaStart, aaEnd, _, _ = get_accessor_bounds(take)
  if not aa then return nil end
  
  -- Create a cache key that includes aaStart and aaEnd so cache invalidates on trim
  local cacheKey = string.format("gate_%.1f_%.2f_%.1f_%.3f_%s_%.9f_%.9f", 
    gateThreshold, gateHoldTime, gateReduction, gateOnsetTime, tostring(take), aaStart, aaEnd)
  
  -- Return cached version if it exists
  if gateEnvelopeCache[cacheKey] then
    return gateEnvelopeCache[cacheKey]
  end
  
  -- Generate new envelope and cache it
  local newEnvelope = generateGateEnvelope(take, item, gateThreshold, gateHoldTime, gateReduction, gateOnsetTime)
  gateEnvelopeCache[cacheKey] = newEnvelope
  
  return newEnvelope
end

local function clearGateEnvelopeCache()
  gateEnvelopeCache = {}
end

local function applyToItem(item, phrases, adjustments, peakCeiling, trim, preLimitBoost, resolutionMs, reducePoints, gateEnabled, gateThreshold, gateHoldTime, gateReduction, gateOnsetTime)
  local ts = reaper.time_precise()
  local take = reaper.GetActiveTake(item)
  if not take or reaper.TakeIsMIDI(take) then return false, 0 end
  local env = reaper.GetTakeEnvelopeByName(take, "Volume")
  if not env then
    reaper.Main_OnCommand(reaper.NamedCommandLookup("_S&M_TAKEENVSHOW9"), 0)
    env = reaper.GetTakeEnvelopeByName(take, "Volume")
  end
  if not env then return false, 0 end

  local aa, aaStart, aaEnd, samplerate, itemLen = get_accessor_bounds(take)
  if not aa or samplerate <= 0 or itemLen <= 0 then if take then releaseAudioAccessor(take) end; return false, 0 end

  reaper.DeleteEnvelopePointRange(env, -1, itemLen + 1000)

  local resolutionSec = math.max(0.001, (resolutionMs or 50) / 1000)
  local itemVolume = reaper.GetMediaItemInfo_Value(item, "D_VOL")
  local peakLin = peakCeiling < 0 and dBToLinear(peakCeiling) or math.huge
  local trimLin = dBToLinear(trim)
  
  local gatePoints = nil
  if gateEnabled then
    gatePoints = getCachedGateEnvelope(take, item, gateThreshold, gateHoldTime, gateReduction, gateOnsetTime)
  end

  local numPoints = math.ceil(itemLen / resolutionSec)
  local maxSamples = math.min(math.floor(samplerate * resolutionSec), 1000000)
  local buf = getAudioBuffer(take, math.max(1, maxSamples) * 2)

  for i = 0, numPoints do
    local tRel = math.min(i * resolutionSec, itemLen)
    buf.clear()
    local read = reaper.GetAudioAccessorSamples(aa, samplerate, 1, aaStart + tRel, math.max(1, maxSamples), buf)
    if read > 0 then
      local volAdj = 1.0
      for ph, a in pairs(adjustments) do
        if tRel >= ph.startTime and tRel <= ph.endTime then volAdj = volAdj * a; break end
      end
      
      local gateAdj = 1.0
      if gatePoints then
        local gateIdx = math.floor(tRel / 0.01) + 1
        if gateIdx >= 1 and gateIdx <= #gatePoints then
          gateAdj = gatePoints[gateIdx].reduction
        end
      end
      
      local preLimitAdj = 1.0
      if gateAdj >= 0.99 then
        preLimitAdj = dBToLinear(preLimitBoost)
      end
      
      local peak, t = 0, buf.table()
      for j = 1, #t do 
        local s = math.abs(t[j] * itemVolume)
        if s > peak then peak = s end 
      end
      local final = volAdj * gateAdj * preLimitAdj
      if peak * final > peakLin then final = peakLin / peak end
      final = final * trimLin
      local scaled = reaper.ScaleToEnvelopeMode(1, final, env)
      reaper.InsertEnvelopePoint(env, tRel, scaled, 0, 0, false, true)
    end
  end

  releaseAudioAccessor(take)
  reaper.Envelope_SortPoints(env)
  simplifyEnvelope(env)
  return true, (reaper.time_precise() - ts)
end

-- ===== GUI State =====
local ctx = reaper.ImGui_CreateContext('Gain Assist')

local sliderDoubleClickTimes = {}
local sliderLastValue = {}

local peakCeiling, correctionStrength, separationSensitivity, trim, preLimitBoost, numBars, minDB, maxDB, curvePower, resolutionMs, reducePoints, showDisplaySettings, rawWaveformOpacity, showTooltips, gateEnabled, gateThreshold, gateHoldTime, gateReduction, gateOnsetTime, gateOverlayOpacity = loadSettings()
local statusMessage = "Ready"
local waveformData, rawWaveformData = nil, nil
local gatePoints = nil
local itemName, phrases, adjustments = "", nil, {}
local lastAudioCalcTime = 0
local phraseDetectionTime = 0

local waveformRendered, waveformNeedsRedraw = false, true
local cacheValid = false

local zoomLevel, zoomCenter = 1.0, 0.5
local lastZoomLevel, lastZoomCenter = 1.0, 0.5
local lastPlotW, lastPlotH = 0, 0

local isDragging, dragStartY, dragStartZoom, dragStartCursorSample = false, 0, 1.0, 0
local isDraggingMarker, draggedMarkerIdx, draggedMarkerX = false, nil, nil
local isDraggingPeakCeiling, hoverPeakCeiling = false, false
local hoverMarkerIdx = nil

local isErasing = false
local eraserStartX, eraserStartY = 0, 0
local markersToDelete = {}

local showHelpMenu = false
local sliderWasActive = {}
local phrasesManualllyAdjusted = false
local showManualAdjustmentWarning = false
local pendingSeparationSensitivity = nil

local tabState = {
  currentTab = 1
}

local isWindows = reaper.GetOS():find("Win") ~= nil
local modifierKey = isWindows and "Ctrl" or "Cmd"

local function getModifierKeyState()
  return reaper.ImGui_IsKeyDown(ctx, reaper.ImGui_Mod_Ctrl()) or reaper.ImGui_IsKeyDown(ctx, reaper.ImGui_Mod_Super())
end

local function checkSliderDoubleClick(sliderID)
  local now = reaper.time_precise()
  local lastTime = sliderDoubleClickTimes[sliderID] or 0
  local threshold = 0.35
  if reaper.ImGui_IsItemHovered(ctx) and reaper.ImGui_IsMouseClicked(ctx, 0) then
    if (now - lastTime) < threshold then
      sliderDoubleClickTimes[sliderID] = 0
      return true
    end
    sliderDoubleClickTimes[sliderID] = now
  end
  return false
end

local function deleteMarker(markerIdx)
  if not phrases or markerIdx < 1 or markerIdx >= #phrases then return false end
  local ph1 = phrases[markerIdx]
  local ph2 = phrases[markerIdx + 1]
  ph1.endTime = ph2.endTime
  ph1.avgLevel = (ph1.avgLevel + ph2.avgLevel) / 2
  table.remove(phrases, markerIdx + 1)
  phrasesManualllyAdjusted = true
  return true
end

local function createMarkerAtTime(clickTime)
  if not phrases then return false end
  local itemLen = 0
  for _, p in ipairs(phrases) do if p.endTime > itemLen then itemLen = p.endTime end end
  local targetIdx = nil
  for i, p in ipairs(phrases) do
    if clickTime > p.startTime and clickTime < p.endTime then targetIdx = i; break end
  end
  if not targetIdx then statusMessage = "Cannot create marker outside phrases"; return false end
  local targetPhrase = phrases[targetIdx]
  local ph1 = {startTime=targetPhrase.startTime, endTime=clickTime, avgLevel=0}
  local ph2 = {startTime=clickTime, endTime=targetPhrase.endTime, avgLevel=0}
  table.remove(phrases, targetIdx)
  table.insert(phrases, targetIdx, ph1)
  table.insert(phrases, targetIdx + 1, ph2)

  local item = reaper.GetSelectedMediaItem(0, 0)
  if item then
    local take = reaper.GetActiveTake(item)
    if take then recalculatePhraseLevels(take, item, phrases) end
  end
  phrasesManualllyAdjusted = true
  statusMessage = "Breakpoint created"
  return true
end

local function refreshWaveformDisplay()
  local t0 = reaper.time_precise()
  
  local item = reaper.GetSelectedMediaItem(0, 0)
  if not item or not phrases then return end
  
  local take = reaper.GetActiveTake(item)
  if take then
    releaseAudioAccessor(take)
  end
  
  adjustments = calculateVolumeAdjustments(phrases, correctionStrength / 100, preLimitBoost)
  waveformData = getAdjustedWaveform(item, numBars, phrases, adjustments, peakCeiling, trim, preLimitBoost)
  rawWaveformData = getRawWaveform(item, numBars)
  
  if gateEnabled then
    if take then
      gatePoints = getCachedGateEnvelope(take, item, gateThreshold, gateHoldTime, gateReduction, gateOnsetTime)
    end
  else
    gatePoints = nil
  end
  
  waveformNeedsRedraw = true
  cacheValid = false
  
  local elapsed = reaper.time_precise() - t0
  debugMsg(string.format("refreshWaveformDisplay: %.3fs\n", elapsed))
end

local function refreshWaveform(forceRedetect)
  local t0 = reaper.time_precise()
  local item = reaper.GetSelectedMediaItem(0, 0)
  if not item then statusMessage = "No item selected"; waveformData, rawWaveformData = nil, nil; return end
  local take = reaper.GetActiveTake(item)
  if take then itemName = reaper.GetTakeName(take) end

  local detectionTime = 0
  
  -- Skip detection if separation is 0 (unless phrases already exist with entries)
  if separationSensitivity == 0 and (not phrases or #phrases == 0) then
    phrases = {}
    phraseDetectionTime = 0
  -- Run detection if: forced, first time (phrases is nil), OR phrases exist
  elseif forceRedetect or not phrases or (phrases and #phrases > 0) then
    local detectionStart = reaper.time_precise()
    local newPhrases, ptime = detectPhrases(take, item, separationSensitivity)
    phrases, phraseDetectionTime = newPhrases, (ptime or 0)
    detectionTime = reaper.time_precise() - detectionStart
  end
  -- Otherwise skip detection (phrases exist and are empty)

  -- Always get raw waveform
  rawWaveformData = getRawWaveform(item, numBars)
  
  if phrases and #phrases > 0 then
    -- Have phrases: calculate volume adjustments for each phrase
    adjustments = calculateVolumeAdjustments(phrases, correctionStrength / 100, preLimitBoost)
    waveformData = getAdjustedWaveform(item, numBars, phrases, adjustments, peakCeiling, trim, preLimitBoost)
  else
    -- No phrases: skip phrase-based adjustments, but still apply peak/trim/gate
    adjustments = {}
    waveformData = getAdjustedWaveform(item, numBars, {}, {}, peakCeiling, trim, preLimitBoost)
  end
  
  -- Generate gate points for visualization
  if gateEnabled then
    gatePoints = getCachedGateEnvelope(take, item, gateThreshold, gateHoldTime, gateReduction, gateOnsetTime)
  else
    gatePoints = nil
  end
  
  lastAudioCalcTime = reaper.time_precise() - t0
  if detectionTime > 0 then
    statusMessage = string.format("Audio: %.3fs | Detect: %.3fs | Total: %.3fs", lastAudioCalcTime - detectionTime, detectionTime, lastAudioCalcTime)
  else
    statusMessage = string.format("Audio: %.3fs", lastAudioCalcTime)
  end
  
  waveformNeedsRedraw, waveformRendered, cacheValid = true, false, false
end

local function refreshWaveformWithDetection()
  local item = reaper.GetSelectedMediaItem(0, 0)
  if not item then return end
  local take = reaper.GetActiveTake(item)
  if not take then return end

  -- Skip detection if separation is 0 and no phrases exist
  if separationSensitivity == 0 then
    phrases = {}
    phraseDetectionTime = 0
  else
    local newPhrases, ptime = detectPhrases(take, item, separationSensitivity)
    phrases = newPhrases
    phraseDetectionTime = ptime or 0
  end
  
  phrasesManualllyAdjusted = false

  -- Always get raw waveform
  rawWaveformData = getRawWaveform(item, numBars)
  
  if phrases and #phrases > 0 then
    -- Have phrases: calculate volume adjustments for each phrase
    adjustments = calculateVolumeAdjustments(phrases, correctionStrength / 100, preLimitBoost)
    waveformData = getAdjustedWaveform(item, numBars, phrases, adjustments, peakCeiling, trim, preLimitBoost)
  else
    -- No phrases: skip phrase-based adjustments, but still apply peak/trim/gate
    adjustments = {}
    waveformData = getAdjustedWaveform(item, numBars, {}, {}, peakCeiling, trim, preLimitBoost)
  end
  
  -- Generate gate points for visualization
  if gateEnabled then
    gatePoints = getCachedGateEnvelope(take, item, gateThreshold, gateHoldTime, gateReduction, gateOnsetTime)
  else
    gatePoints = nil
  end

  waveformNeedsRedraw = true
  cacheValid = false
end

local function getPinnedWaveformRect(plotHeight)
  local winPosX, winPosY = reaper.ImGui_GetWindowPos(ctx)
  local winW, winH      = reaper.ImGui_GetWindowSize(ctx)
  local padX, padY = 8, 8
  local okMin, crMinX, crMinY = pcall(reaper.ImGui_GetWindowContentRegionMin, ctx)
  local okMax, crMaxX, crMaxY = pcall(reaper.ImGui_GetWindowContentRegionMax, ctx)
  if okMin and okMax and crMinX and crMaxX then
    local x = winPosX + crMinX
    local y = winPosY + crMinY
    local width = crMaxX - crMinX
    local height = plotHeight
    return x, y, width, height
  end
  local x = winPosX + padX
  local y = winPosY + padY
  local width  = math.max(0, winW - padX * 2)
  local height = plotHeight
  return x, y, width, height
end

local function handleHotkeys()
  -- Enter key: Apply changes
  if reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Enter()) then
    if phrases and #phrases > 0 then
      debugMsg("DEBUG: Applying with " .. #phrases .. " phrases (manually adjusted: " .. tostring(phrasesManualllyAdjusted) .. ")\n")
      for idx, ph in ipairs(phrases) do
        debugMsg(string.format("  Phrase %d: %.3f - %.3f\n", idx, ph.startTime, ph.endTime))
      end
    end
    saveSettings(peakCeiling, correctionStrength, separationSensitivity, trim, preLimitBoost, resolutionMs, true, rawWaveformOpacity, showTooltips, gateEnabled, gateThreshold, gateHoldTime, gateReduction, gateOnsetTime, gateOverlayOpacity)
    reaper.Undo_BeginBlock()
    local cnt, processed, totalApply = reaper.CountSelectedMediaItems(0), 0, 0
    local currentItem = reaper.GetSelectedMediaItem(0, 0)
  
    for i = 0, cnt - 1 do
      local item = reaper.GetSelectedMediaItem(0, i)
      local take = reaper.GetActiveTake(item)
      if take and not reaper.TakeIsMIDI(take) then
        local itemPhrases
        if item == currentItem and phrases and #phrases > 0 and phrasesManualllyAdjusted then
          itemPhrases = phrases
          debugMsg("Using manual phrases for current item\n")
        else
          itemPhrases = detectPhrases(take, item, separationSensitivity)
          debugMsg("Auto-detecting phrases for other item\n")
        end
        if itemPhrases and #itemPhrases > 0 then
          local adj = calculateVolumeAdjustments(itemPhrases, correctionStrength / 100, preLimitBoost)
          local ok, t = applyToItem(item, itemPhrases, adj, peakCeiling, trim, preLimitBoost, resolutionMs, true, gateEnabled, gateThreshold, gateHoldTime, gateReduction, gateOnsetTime)
          if ok then processed = processed + 1; totalApply = totalApply + t end
        end
      end
    end
    reaper.Undo_EndBlock("Gain Assist", -1)
    reaper.UpdateArrange()
    statusMessage = string.format("Committed to %d item(s) | Apply: %.3fs", processed, totalApply)
  end
  
  -- Spacebar: Play/Pause
  -- ReaImGui's IsKeyPressed will detect spacebar, but we only want to handle it
  -- when ImGui doesn't have a text input field or other keyboard control active
  if reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Space()) then
    if not reaper.ImGui_IsAnyItemActive(ctx) then
      local isPlaying = (reaper.GetPlayState() & 1) == 1
      if isPlaying then
        reaper.Main_OnCommand(reaper.NamedCommandLookup("_NF_PLAY_STOP_PLAY_PAUSE"), 0)
      else
        reaper.Main_OnCommand(reaper.NamedCommandLookup("_NF_PLAY_STOP_PLAY_PAUSE"), 0)
      end
    end
  end
end

function PushTheme()
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowPadding(), 20, 8)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FrameRounding(), 12)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_GrabMinSize(), 15)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_GrabRounding(), 12)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_WindowBg(), 0x222222F0)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_FrameBg(), 0x0000008A)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_FrameBgHovered(), 0x54555666)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_FrameBgActive(), 0x4296FA66)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_SliderGrab(), 0x4080FFFF)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_SliderGrabActive(), 0xFFFFFFFF)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(), 0x4080FFFF)
end

function PopTheme()
  reaper.ImGui_PopStyleVar(ctx, 4)
  reaper.ImGui_PopStyleColor(ctx, 7)
end

local ctxInit = false
local function loop()
  PushTheme()
  if not ctxInit then refreshWaveform(true); ctxInit = true end
  local visible, open = reaper.ImGui_Begin(ctx, 'Gain Assist', true, reaper.ImGui_WindowFlags_None())
  if visible then
    
    if reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Escape()) then open = false end
    handleHotkeys()
    local winW, winH = reaper.ImGui_GetWindowSize(ctx)
    
    -- Define height tiers for progressive control hiding
    local MIN_HEIGHT_WAVEFORM_ONLY = 0
    local MIN_HEIGHT_WITH_STATUS = 350
    local MIN_HEIGHT_ONE_TAB = 500
    
    local showWaveform = winH >= MIN_HEIGHT_WAVEFORM_ONLY
    local showStatus = winH >= MIN_HEIGHT_WITH_STATUS
    local showTabs = winH >= MIN_HEIGHT_ONE_TAB
    
    if not showWaveform then
      -- Window too small - show message
      local availW, availH = reaper.ImGui_GetContentRegionAvail(ctx)
      local msg = "Window too small - please increase height"
      local textW = reaper.ImGui_CalcTextSize(ctx, msg)
      reaper.ImGui_Dummy(ctx, (availW - textW) / 2, availH / 2 - 10)
      reaper.ImGui_SameLine(ctx)
      reaper.ImGui_Text(ctx, msg)
    elseif winW < 0 then
      -- Window too narrow
      local availW, availH = reaper.ImGui_GetContentRegionAvail(ctx)
      local msg = "Window too small - please increase width"
      local textW = reaper.ImGui_CalcTextSize(ctx, msg)
      reaper.ImGui_Dummy(ctx, (availW - textW) / 2, availH / 2 - 10)
      reaper.ImGui_SameLine(ctx)
      reaper.ImGui_Text(ctx, msg)
    else
      if showHelpMenu then
        local helpVisible, helpOpen = reaper.ImGui_Begin(ctx, 'Help - Gain Assist', true)
        if helpVisible then
          reaper.ImGui_Text(ctx, "GAIN ASSIST - HELP")
          reaper.ImGui_Separator(ctx)
          local changed, newVal = reaper.ImGui_Checkbox(ctx, "Show Tooltips##helpMenu", showTooltips)
          if changed then
            showTooltips = newVal
            setExtState("showTooltips", showTooltips and 1 or 0)
          end
          reaper.ImGui_Spacing(ctx)
          reaper.ImGui_Separator(ctx)
          reaper.ImGui_Spacing(ctx)
          
          reaper.ImGui_TextWrapped(ctx, "This tool detects audio 'phrases' and balances their volume levels.")
          reaper.ImGui_Spacing(ctx)
          reaper.ImGui_Text(ctx, "PHRASE DETECTION:")
          reaper.ImGui_BulletText(ctx, "Uses relative threshold based on median RMS level")
          reaper.ImGui_BulletText(ctx, "Sensitivity slider controls silence detection")
          reaper.ImGui_BulletText(ctx, "Breakpoints placed at midpoints of silence gaps")
          reaper.ImGui_BulletText(ctx, "Adjusting slider re-detects (overwrites manual changes)")
          reaper.ImGui_Spacing(ctx)
          reaper.ImGui_Text(ctx, "BREAKPOINT MARKERS:")
          reaper.ImGui_BulletText(ctx, "White circles = phrase separation points")
          reaper.ImGui_BulletText(ctx, "Yellow circles = edge markers (first and last)")
          reaper.ImGui_BulletText(ctx, "Drag markers to manually adjust boundaries")
          reaper.ImGui_BulletText(ctx, "Right-click and drag to delete multiple markers")
          reaper.ImGui_BulletText(ctx, "Double-click in waveform to create new breakpoint")
          reaper.ImGui_Spacing(ctx)
          reaper.ImGui_Text(ctx, "WAVEFORM INTERACTION:")
          reaper.ImGui_BulletText(ctx, "Drag vertically to zoom in/out")
          reaper.ImGui_BulletText(ctx, "Drag horizontally while zoomed to pan")
          reaper.ImGui_BulletText(ctx, "Magenta lines = Peak Ceiling limit")
          reaper.ImGui_BulletText(ctx, "Drag peak lines to adjust ceiling")
          reaper.ImGui_Spacing(ctx)
          reaper.ImGui_Text(ctx, "VOLUME CONTROLS:")
          reaper.ImGui_BulletText(ctx, "Phrase Balancing: 0-100% (normalizes phrase levels)")
          reaper.ImGui_BulletText(ctx, "Pre-Limit Boost: -12 to +12 dB (before peak limiting)")
          reaper.ImGui_BulletText(ctx, "Peak Ceiling: -60 to 0 dB (hard limit on output)")
          reaper.ImGui_BulletText(ctx, "Overall Trim: -12 to +12 dB (final output level)")
          reaper.ImGui_Spacing(ctx)
          reaper.ImGui_Text(ctx, "NOISE GATE:")
          reaper.ImGui_BulletText(ctx, "Enable gate to reduce low-level noise")
          reaper.ImGui_BulletText(ctx, "Threshold: signal level to trigger gate")
          reaper.ImGui_BulletText(ctx, "Hold Time: duration to wait before reduction")
          reaper.ImGui_BulletText(ctx, "Reduction: amount to reduce gated areas")
          reaper.ImGui_BulletText(ctx, "Onset Time: fade-in/out duration for smooth transitions")
          reaper.ImGui_BulletText(ctx, "Red overlay shows where gate is actively reducing")
          reaper.ImGui_Spacing(ctx)
          reaper.ImGui_Text(ctx, "TIPS:")
          reaper.ImGui_BulletText(ctx, "Right-click sliders to reset to defaults")
          reaper.ImGui_BulletText(ctx, "Use 'Refresh' to force re-detection")
          reaper.ImGui_BulletText(ctx, "Click 'Apply' or press Enter to commit changes to selected items")
          reaper.ImGui_BulletText(ctx, "Press Esc to exit script")
          reaper.ImGui_BulletText(ctx, "Reserve area outside edge markers for silence")
          reaper.ImGui_BulletText(ctx, "If envelope fails to apply, try toggling it on first")
          reaper.ImGui_BulletText(ctx, "To reduce lag, decrease waveform resolution")
          reaper.ImGui_Spacing(ctx)
          reaper.ImGui_End(ctx)
        end
        if not helpOpen then showHelpMenu = false end
      end

      local contentAvailW, _ = reaper.ImGui_GetContentRegionAvail(ctx)
      local plotW = math.max(contentAvailW, 100)
      local plotH = math.max(contentAvailW * 0.15, 150)
      local rulerH = 25

      reaper.ImGui_Dummy(ctx, plotW, plotH + rulerH)
      reaper.ImGui_Spacing(ctx); reaper.ImGui_Separator(ctx); reaper.ImGui_Spacing(ctx)

      reaper.ImGui_Text(ctx, "Item: " .. (itemName or ""))
      reaper.ImGui_SameLine(ctx)
      reaper.ImGui_Text(ctx, "Status: " .. (statusMessage or ""))
      reaper.ImGui_Dummy(ctx, 0, 2)
      
      
      local contentWidth, _ = reaper.ImGui_GetContentRegionAvail(ctx)
      local totalButtonWidth = 90 + 150 + 100 + 100 + 110
      local buttonSpacing = 8
      totalButtonWidth = totalButtonWidth + (buttonSpacing * 4)
      
      if contentWidth < totalButtonWidth + 50 then
        reaper.ImGui_Text(ctx, "Window too narrow for controls")
        reaper.ImGui_Spacing(ctx)
      else
        reaper.ImGui_SameLine(ctx, contentWidth - totalButtonWidth)
        --local leftPad = math.max(0, (contentWidth - totalButtonWidth) / 2)
       -- reaper.ImGui_SameLine(ctx, leftPad)
        
        if reaper.ImGui_Button(ctx, "Apply", 110, 25) then
          if phrases and #phrases > 0 then
            debugMsg("DEBUG: Applying with " .. #phrases .. " phrases (manually adjusted: " .. tostring(phrasesManualllyAdjusted) .. ")\n")
            for idx, ph in ipairs(phrases) do
              debugMsg(string.format("  Phrase %d: %.3f - %.3f\n", idx, ph.startTime, ph.endTime))
            end
          end
          saveSettings(peakCeiling, correctionStrength, separationSensitivity, trim, preLimitBoost, resolutionMs, true, rawWaveformOpacity, showTooltips, gateEnabled, gateThreshold, gateHoldTime, gateReduction, gateOnsetTime)
          reaper.Undo_BeginBlock()
          local cnt, processed, totalApply = reaper.CountSelectedMediaItems(0), 0, 0
          local currentItem = reaper.GetSelectedMediaItem(0, 0)
        
          for i = 0, cnt - 1 do
            local item = reaper.GetSelectedMediaItem(0, i)
            local take = reaper.GetActiveTake(item)
            if take and not reaper.TakeIsMIDI(take) then
              local itemPhrases
              if item == currentItem and phrases and #phrases > 0 and phrasesManualllyAdjusted then
                itemPhrases = phrases
                debugMsg("Using manual phrases for current item\n")
              else
                itemPhrases = detectPhrases(take, item, separationSensitivity)
                debugMsg("Auto-detecting phrases for other item\n")
              end
              if itemPhrases and #itemPhrases > 0 then
                local adj = calculateVolumeAdjustments(itemPhrases, correctionStrength / 100, preLimitBoost)
                local ok, t = applyToItem(item, itemPhrases, adj, peakCeiling, trim, preLimitBoost, resolutionMs, true, gateEnabled, gateThreshold, gateHoldTime, gateReduction, gateOnsetTime)
                if ok then processed = processed + 1; totalApply = totalApply + t end
              end
            end
          end
          reaper.Undo_EndBlock("Gain Assist", -1)
          reaper.UpdateArrange()
          statusMessage = string.format("Committed to %d item(s) | Apply: %.3fs", processed, totalApply)
        end
        reaper.ImGui_SameLine(ctx, 0, buttonSpacing)
        
        if reaper.ImGui_Button(ctx, "Refresh", 100, 25) then
          refreshWaveform(true); zoomLevel, zoomCenter = 1.0, 0.5
        end
        reaper.ImGui_SameLine(ctx, 0, buttonSpacing)
        
        if reaper.ImGui_Button(ctx, "Help", 100, 25) then
          showHelpMenu = not showHelpMenu
        end
      end
      
      if showTabs then
        reaper.ImGui_Spacing(ctx)
        local minTabWidth = 350
        if contentWidth < minTabWidth then
          reaper.ImGui_Text(ctx, "Window too narrow for tab controls")
          reaper.ImGui_Spacing(ctx)
        else
          local tabButtonWidth = 100
          local tabButtonGap = 0
          local totalTabWidth = (tabButtonWidth * 3) + (tabButtonGap * 2)
          local tabLeftPad = math.max(0, (contentWidth - totalTabWidth) / 2)
          
          reaper.ImGui_Dummy(ctx, tabLeftPad, 0)
          reaper.ImGui_SameLine(ctx)
          
          local tabBg1 = tabState.currentTab == 1 and 0x4080FFFF or 0x404040FF
          local tabBg2 = tabState.currentTab == 2 and 0x4080FFFF or 0x404040FF
          local tabBg3 = tabState.currentTab == 3 and 0x4080FFFF or 0x404040FF
          local tabText1 = tabState.currentTab == 1 and 0xFFFFFFFF or 0xAAAAAAAA
          local tabText2 = tabState.currentTab == 2 and 0xFFFFFFFF or 0xAAAAAAAA
          local tabText3 = tabState.currentTab == 3 and 0xFFFFFFFF or 0xAAAAAAAA
          
          local fg = reaper.ImGui_GetForegroundDrawList(ctx)
          local tabX, tabY = reaper.ImGui_GetCursorScreenPos(ctx)
          
          reaper.ImGui_DrawList_AddRectFilled(fg, tabX, tabY, tabX + tabButtonWidth, tabY + 32, tabBg1, 4)
          local textW1, textH1 = reaper.ImGui_CalcTextSize(ctx, "Level")
          reaper.ImGui_DrawList_AddText(fg, tabX + (tabButtonWidth - textW1) / 2, tabY + (32 - textH1) / 2, tabText1, "Level")
         
          reaper.ImGui_DrawList_AddRectFilled(fg, tabX + tabButtonWidth, tabY, tabX + tabButtonWidth * 2, tabY + 32, tabBg2, 4)
          local textW2, textH2 = reaper.ImGui_CalcTextSize(ctx, "Gate")
          reaper.ImGui_DrawList_AddText(fg, tabX + tabButtonWidth + (tabButtonWidth - textW2) / 2, tabY + (32 - textH2) / 2, tabText2, "Gate")
          
          reaper.ImGui_DrawList_AddRectFilled(fg, tabX + tabButtonWidth * 2, tabY, tabX + tabButtonWidth * 3, tabY + 32, tabBg3, 4)
          local textW3, textH3 = reaper.ImGui_CalcTextSize(ctx, "Display")
          reaper.ImGui_DrawList_AddText(fg, tabX + tabButtonWidth * 2 + (tabButtonWidth - textW3) / 2, tabY + (32 - textH3) / 2, tabText3, "Display")
          
          reaper.ImGui_SetCursorScreenPos(ctx, tabX, tabY)
          if reaper.ImGui_InvisibleButton(ctx, "tab1", tabButtonWidth, 32) then
            tabState.currentTab = 1
          end
          reaper.ImGui_SameLine(ctx, 0, 0)
          if reaper.ImGui_InvisibleButton(ctx, "tab2", tabButtonWidth, 32) then
            tabState.currentTab = 2
          end
          reaper.ImGui_SameLine(ctx, 0, 0)
          if reaper.ImGui_InvisibleButton(ctx, "tab3", tabButtonWidth, 32) then
            tabState.currentTab = 3
          end
          
          reaper.ImGui_Spacing(ctx)
  
          if tabState.currentTab == 1 then
            local gap = 28
            local colWidth = math.max(220, math.min(360, (contentWidth - gap) / 2))
            local totalControlsW = (colWidth * 2) + gap
            local leftPad = math.max(0, (contentWidth - totalControlsW) / 2)
  
            if contentWidth < 500 then
              reaper.ImGui_Text(ctx, "Window too narrow for controls")
              reaper.ImGui_Spacing(ctx)
            else
              reaper.ImGui_Dummy(ctx, leftPad, 0)
              reaper.ImGui_SameLine(ctx)
  
              reaper.ImGui_BeginChild(ctx, "controls_left_col", colWidth, 0, reaper.ImGui_WindowFlags_NoScrollbar())
                reaper.ImGui_PushItemWidth(ctx, colWidth * 0.60)
  
                local changed, newVal = reaper.ImGui_SliderDouble(ctx, "##separationSensitivity", separationSensitivity, 0.00, 0.95, "%.2f")
                if reaper.ImGui_IsItemHovered(ctx) and reaper.ImGui_IsMouseClicked(ctx, 1) then
                  if phrasesManualllyAdjusted then
                    showManualAdjustmentWarning = true
                    pendingSeparationSensitivity = DEFAULT_SEPARATION_SENSITIVITY
                  else
                    separationSensitivity = DEFAULT_SEPARATION_SENSITIVITY
                    statusMessage = "Separation Sensitivity reset"
                    refreshWaveformWithDetection()
                  end
                elseif changed then
                  if phrasesManualllyAdjusted then
                    showManualAdjustmentWarning = true
                    pendingSeparationSensitivity = newVal
                  else
                    separationSensitivity = newVal
                  end
                end
                local isActive = reaper.ImGui_IsItemActive(ctx)
                if sliderWasActive["separationSensitivity"] and not isActive then
                  if phrasesManualllyAdjusted then
                    showManualAdjustmentWarning = true
                    pendingSeparationSensitivity = separationSensitivity
                  else
                    refreshWaveformWithDetection()
                  end
                end
                sliderWasActive["separationSensitivity"] = isActive
                reaper.ImGui_SameLine(ctx)
                reaper.ImGui_Text(ctx, "Separation (less → more)")
                reaper.ImGui_Spacing(ctx)
  
                changed, newVal = reaper.ImGui_SliderDouble(ctx, "##correctionStrength", correctionStrength, 0, 100, "%.0f")
                if reaper.ImGui_IsItemHovered(ctx) and reaper.ImGui_IsMouseClicked(ctx, 1) then
                  correctionStrength = DEFAULT_CORRECTION_STRENGTH
                  statusMessage = "Phrase Balancing reset"
                  refreshWaveformDisplay()
                elseif changed then
                  correctionStrength = newVal
                end
                isActive = reaper.ImGui_IsItemActive(ctx)
                if sliderWasActive["correctionStrength"] and not isActive then
                  refreshWaveformDisplay()
                end
                sliderWasActive["correctionStrength"] = isActive
                reaper.ImGui_SameLine(ctx)
                reaper.ImGui_Text(ctx, "Phrase Balancing (%)")
                reaper.ImGui_Spacing(ctx)
  
                changed, newVal = reaper.ImGui_SliderDouble(ctx, "##preLimitBoost", preLimitBoost, -12, 12, "%.1f")
                if reaper.ImGui_IsItemHovered(ctx) and reaper.ImGui_IsMouseClicked(ctx, 1) then
                  preLimitBoost = DEFAULT_PRE_LIMIT_BOOST
                  statusMessage = "Pre-Limit Boost reset"
                  refreshWaveformDisplay()
                elseif changed then
                  preLimitBoost = newVal
                end
                isActive = reaper.ImGui_IsItemActive(ctx)
                if sliderWasActive["preLimitBoost"] and not isActive then
                  refreshWaveformDisplay()
                end
                sliderWasActive["preLimitBoost"] = isActive
                reaper.ImGui_SameLine(ctx)
                reaper.ImGui_Text(ctx, "Pre-Limit Boost (dB)")
  
                reaper.ImGui_PopItemWidth(ctx)
              reaper.ImGui_EndChild(ctx)
  
              reaper.ImGui_SameLine(ctx, 0, gap)
  
              reaper.ImGui_BeginChild(ctx, "controls_right_col", colWidth, 0, reaper.ImGui_WindowFlags_NoScrollbar())
                reaper.ImGui_PushItemWidth(ctx, colWidth * 0.60)
  
                local changed2, newVal2 = reaper.ImGui_SliderDouble(ctx, "##resolutionMs", resolutionMs, 1, 50, "%.0f")
                if reaper.ImGui_IsItemHovered(ctx) and reaper.ImGui_IsMouseClicked(ctx, 1) then
                  resolutionMs = DEFAULT_RESOLUTION_MS
                  statusMessage = "Peak Smoothness reset"
                elseif changed2 then
                  resolutionMs = newVal2
                  statusMessage = "Peak Smoothness changed"
                end
                reaper.ImGui_SameLine(ctx)
                reaper.ImGui_Text(ctx, "Peak Smoothness (ms)")
                reaper.ImGui_Spacing(ctx)
                
                changed2, newVal2 = reaper.ImGui_SliderDouble(ctx, "##peakCeiling", peakCeiling, -60, 0, "%.1f")
                if reaper.ImGui_IsItemHovered(ctx) and reaper.ImGui_IsMouseClicked(ctx, 1) then
                  peakCeiling = DEFAULT_PEAK_CEILING
                  statusMessage = "Peak Ceiling reset"
                  refreshWaveformDisplay()
                elseif changed2 then
                  peakCeiling = newVal2
                end
                local isActive2 = reaper.ImGui_IsItemActive(ctx)
                if sliderWasActive["peakCeiling"] and not isActive2 then
                  refreshWaveformDisplay()
                end
                sliderWasActive["peakCeiling"] = isActive2
                reaper.ImGui_SameLine(ctx)
                reaper.ImGui_Text(ctx, "Peak Ceiling (dB)")
                reaper.ImGui_Spacing(ctx)
                
                changed2, newVal2 = reaper.ImGui_SliderDouble(ctx, "##trim", trim, -12, 12, "%.1f")
                if reaper.ImGui_IsItemHovered(ctx) and reaper.ImGui_IsMouseClicked(ctx, 1) then
                  trim = DEFAULT_TRIM
                  statusMessage = "Overall Trim reset"
                  refreshWaveformDisplay()
                elseif changed2 then
                  trim = newVal2
                end
                isActive2 = reaper.ImGui_IsItemActive(ctx)
                if sliderWasActive["trim"] and not isActive2 then
                  refreshWaveformDisplay()
                end
                sliderWasActive["trim"] = isActive2
                reaper.ImGui_SameLine(ctx)
                reaper.ImGui_Text(ctx, "Overall Trim (dB)")
                reaper.ImGui_Spacing(ctx)
                
                reaper.ImGui_PopItemWidth(ctx)
              reaper.ImGui_EndChild(ctx)
            end
  
          elseif tabState.currentTab == 2 then
            local gap = 28
            local colWidth = math.max(220, math.min(360, (contentWidth - gap) / 2))
            local totalControlsW = (colWidth * 2) + gap
            local leftPad = math.max(0, (contentWidth - totalControlsW) / 2)
          
            if contentWidth < 500 then
              reaper.ImGui_Text(ctx, "Window too narrow for gate controls")
              reaper.ImGui_Spacing(ctx)
            else
              reaper.ImGui_Dummy(ctx, leftPad, 0)
              reaper.ImGui_SameLine(ctx)
          
              reaper.ImGui_BeginChild(ctx, "gate_left_col", colWidth, 0, reaper.ImGui_WindowFlags_NoScrollbar())
                reaper.ImGui_PushItemWidth(ctx, colWidth * 0.60)
                
                
                reaper.ImGui_Dummy(ctx, 188, 0)
                reaper.ImGui_SameLine(ctx)
                local changed, newVal = reaper.ImGui_Checkbox(ctx, "##gateEnabled", gateEnabled)
                if changed then
                  gateEnabled = newVal
                  refreshWaveformDisplay()
                end
                reaper.ImGui_SameLine(ctx)
                reaper.ImGui_Text(ctx, "Gate Enabled")
                reaper.ImGui_Spacing(ctx)
          
                changed, newVal = reaper.ImGui_SliderDouble(ctx, "##gateThreshold", gateThreshold, -80, -6, "%.1f")
                if reaper.ImGui_IsItemHovered(ctx) and reaper.ImGui_IsMouseClicked(ctx, 1) then
                  gateThreshold = DEFAULT_GATE_THRESHOLD
                  statusMessage = "Gate Threshold reset"
                  refreshWaveformDisplay()
                elseif changed then
                  gateThreshold = newVal
                  clearGateEnvelopeCache()
                end
                local isActive = reaper.ImGui_IsItemActive(ctx)
                if sliderWasActive["gateThreshold"] and not isActive then
                  refreshWaveformDisplay()
                end
                sliderWasActive["gateThreshold"] = isActive
                reaper.ImGui_SameLine(ctx)
                reaper.ImGui_Text(ctx, "Threshold (dB)")
                reaper.ImGui_Spacing(ctx)
          
                changed, newVal = reaper.ImGui_SliderDouble(ctx, "##gateHoldTime", gateHoldTime, 0.05, 2.0, "%.2f")
                if reaper.ImGui_IsItemHovered(ctx) and reaper.ImGui_IsMouseClicked(ctx, 1) then
                  gateHoldTime = DEFAULT_GATE_HOLD_TIME
                  statusMessage = "Gate Hold Time reset"
                  refreshWaveformDisplay()
                elseif changed then
                  gateHoldTime = newVal
                  clearGateEnvelopeCache()
                end
                isActive = reaper.ImGui_IsItemActive(ctx)
                if sliderWasActive["gateHoldTime"] and not isActive then
                  refreshWaveformDisplay()
                end
                sliderWasActive["gateHoldTime"] = isActive
                reaper.ImGui_SameLine(ctx)
                reaper.ImGui_Text(ctx, "Hold Time (s)")
          
                reaper.ImGui_PopItemWidth(ctx)
              reaper.ImGui_EndChild(ctx)
          
              reaper.ImGui_SameLine(ctx, 0, gap)
          
              reaper.ImGui_BeginChild(ctx, "gate_right_col", colWidth, 0, reaper.ImGui_WindowFlags_NoScrollbar())
                reaper.ImGui_PushItemWidth(ctx, colWidth * 0.60)
                reaper.ImGui_Spacing(ctx)
                reaper.ImGui_Spacing(ctx)
                reaper.ImGui_Spacing(ctx)
                reaper.ImGui_Spacing(ctx)
                reaper.ImGui_Spacing(ctx)
                reaper.ImGui_Spacing(ctx)
                reaper.ImGui_Spacing(ctx)
                local changed2, newVal2 = reaper.ImGui_SliderDouble(ctx, "##gateReduction", gateReduction, -80, 0, "%.1f")
                if reaper.ImGui_IsItemHovered(ctx) and reaper.ImGui_IsMouseClicked(ctx, 1) then
                  gateReduction = DEFAULT_GATE_REDUCTION
                  statusMessage = "Gate Reduction reset"
                  refreshWaveformDisplay()
                elseif changed2 then
                  gateReduction = newVal2
                  clearGateEnvelopeCache()
                end
                local isActive2 = reaper.ImGui_IsItemActive(ctx)
                if sliderWasActive["gateReduction"] and not isActive2 then
                  refreshWaveformDisplay()
                end
                sliderWasActive["gateReduction"] = isActive2
                reaper.ImGui_SameLine(ctx)
                reaper.ImGui_Text(ctx, "Reduction (dB)")
                reaper.ImGui_Spacing(ctx)
          
                changed2, newVal2 = reaper.ImGui_SliderDouble(ctx, "##gateOnsetTime", gateOnsetTime, 0.01, 0.5, "%.3f")
                if reaper.ImGui_IsItemHovered(ctx) and reaper.ImGui_IsMouseClicked(ctx, 1) then
                  gateOnsetTime = DEFAULT_GATE_ONSET_TIME
                  statusMessage = "Gate Onset Time reset"
                  refreshWaveformDisplay()
                elseif changed2 then
                  gateOnsetTime = newVal2
                  clearGateEnvelopeCache()
                end
                isActive2 = reaper.ImGui_IsItemActive(ctx)
                if sliderWasActive["gateOnsetTime"] and not isActive2 then
                  refreshWaveformDisplay()
                end
                sliderWasActive["gateOnsetTime"] = isActive2
                reaper.ImGui_SameLine(ctx)
                reaper.ImGui_Text(ctx, "Onset Time (s)")
                reaper.ImGui_Spacing(ctx)
          
                reaper.ImGui_PopItemWidth(ctx)
              reaper.ImGui_EndChild(ctx)
            end
  
          elseif tabState.currentTab == 3 then
            local gap = 28
            local colWidth = math.max(220, math.min(360, (contentWidth - gap) / 2))
            local totalControlsW = (colWidth * 2) + gap
            local leftPad = math.max(0, (contentWidth - totalControlsW) / 2)
          
            if contentWidth < 500 then
              reaper.ImGui_Text(ctx, "Window too narrow for display controls")
              reaper.ImGui_Spacing(ctx)
            else
              reaper.ImGui_Dummy(ctx, leftPad, 0)
              reaper.ImGui_SameLine(ctx)
          
              reaper.ImGui_BeginChild(ctx, "display_left_col", colWidth, 0, reaper.ImGui_WindowFlags_NoScrollbar())
                reaper.ImGui_PushItemWidth(ctx, colWidth * 0.60)
          
                local changed, newVal = reaper.ImGui_SliderInt(ctx, "##numBars", numBars, 500, 10000)
                if checkSliderDoubleClick("numBars") then
                  numBars = DEFAULT_NUM_BARS
                  setExtState("numBars", numBars)
                  statusMessage = "Waveform Resolution reset"
                  refreshWaveformDisplay()
                elseif changed then
                  numBars = newVal
                  setExtState("numBars", numBars)
                end
                reaper.ImGui_SameLine(ctx)
                reaper.ImGui_Text(ctx, "Waveform Resolution")
                reaper.ImGui_Spacing(ctx)
          
                changed, newVal = reaper.ImGui_SliderInt(ctx, "##minDB", minDB, -150, -6)
                if checkSliderDoubleClick("minDB") then
                  minDB = DEFAULT_MIN_DB
                  setExtState("minDB", minDB)
                  statusMessage = "Min dB reset"
                  refreshWaveformDisplay()
                elseif changed then
                  minDB = newVal
                  setExtState("minDB", minDB)
                end
                reaper.ImGui_SameLine(ctx)
                reaper.ImGui_Text(ctx, "Min dB")
                reaper.ImGui_Spacing(ctx)
          
                changed, newVal = reaper.ImGui_SliderInt(ctx, "##maxDB", maxDB, -24, 0)
                if checkSliderDoubleClick("maxDB") then
                  maxDB = DEFAULT_MAX_DB
                  setExtState("maxDB", maxDB)
                  statusMessage = "Max dB reset"
                  refreshWaveformDisplay()
                elseif changed then
                  maxDB = newVal
                  setExtState("maxDB", maxDB)
                end
                reaper.ImGui_SameLine(ctx)
                reaper.ImGui_Text(ctx, "Max dB")
          
                reaper.ImGui_PopItemWidth(ctx)
              reaper.ImGui_EndChild(ctx)
          
              reaper.ImGui_SameLine(ctx, 0, gap)
          
              reaper.ImGui_BeginChild(ctx, "display_right_col", colWidth, 0, reaper.ImGui_WindowFlags_NoScrollbar())
                reaper.ImGui_PushItemWidth(ctx, colWidth * 0.60)
          
                local changed, newVal = reaper.ImGui_SliderDouble(ctx, "##curvePower", curvePower, 1.0, 20.0, "%.1f")
                if checkSliderDoubleClick("curvePower") then
                  curvePower = DEFAULT_CURVE_POWER
                  setExtState("curvePower", curvePower)
                  statusMessage = "Curve Power reset"
                  refreshWaveformDisplay()
                elseif changed then
                  curvePower = newVal
                  setExtState("curvePower", curvePower)
                end
                reaper.ImGui_SameLine(ctx)
                reaper.ImGui_Text(ctx, "Curve Power")
                reaper.ImGui_Spacing(ctx)
          
                changed, newVal = reaper.ImGui_SliderDouble(ctx, "##rawWaveformOpacity", rawWaveformOpacity, 0, 100, "%.0f%%")
                if checkSliderDoubleClick("rawWaveformOpacity") then
                  rawWaveformOpacity = DEFAULT_RAW_WAVEFORM_OPACITY
                  statusMessage = "Raw Waveform Opacity reset"
                  refreshWaveformDisplay()
                elseif changed then
                  rawWaveformOpacity = newVal
                end
                reaper.ImGui_SameLine(ctx)
                reaper.ImGui_Text(ctx, "Raw Waveform Opacity")
                reaper.ImGui_Spacing(ctx)
          
                -- NEW: Gate Overlay Opacity slider (right below raw waveform opacity)
                changed, newVal = reaper.ImGui_SliderDouble(ctx, "##gateOverlayOpacity", gateOverlayOpacity, 0, 100, "%.0f%%")
                if checkSliderDoubleClick("gateOverlayOpacity") then
                  gateOverlayOpacity = DEFAULT_GATE_OVERLAY_OPACITY
                  statusMessage = "Gate Overlay Opacity reset"
                  waveformNeedsRedraw = true
                elseif changed then
                  gateOverlayOpacity = newVal
                  waveformNeedsRedraw = true
                end
                reaper.ImGui_SameLine(ctx)
                reaper.ImGui_Text(ctx, "Gate Overlay Opacity")
          
                reaper.ImGui_PopItemWidth(ctx)
              reaper.ImGui_EndChild(ctx)
            end
          end
        end
      elseif showControls then
        reaper.ImGui_Text(ctx, "Waveform visible | Scroll down for controls")
      end

      if waveformData and #waveformData > 0 then
        if lastPlotW ~= plotW or lastPlotH ~= plotH then waveformNeedsRedraw, cacheValid = true, false; lastPlotW, lastPlotH = plotW, plotH end
        if lastZoomLevel ~= zoomLevel or lastZoomCenter ~= zoomCenter then waveformNeedsRedraw, cacheValid = true, false; lastZoomLevel, lastZoomCenter = zoomLevel, zoomCenter end

        local x, y, w, h = getPinnedWaveformRect(plotH)
        local totalSamples = #waveformData
        local visibleSamples = math.max(50, math.floor(totalSamples / zoomLevel))
        local startSample = math.max(1, math.min(totalSamples - visibleSamples, math.floor(zoomCenter * totalSamples - visibleSamples / 2)))

        local mouse_x, mouse_y = reaper.ImGui_GetMousePos(ctx)
        local isInside = (mouse_x >= x and mouse_x <= x + w and mouse_y >= y and mouse_y <= y + h)
        -- Check if mouse is near any phrase marker
        local nearMarker = false
        for _, marker in ipairs(phraseMarkerPositions) do
          local dx, dy = mouse_x - marker.x, mouse_y - marker.y
          if (dx*dx + dy*dy) <= (8*8) then
            nearMarker = true
            break
          end
        end
        
        -- LEFT CLICK on waveform (when not interacting with other elements or markers)
        if isInside and reaper.ImGui_IsMouseClicked(ctx, 0) and not isDragging and not isDraggingMarker and not isDraggingPeakCeiling and not isErasing and not nearMarker then
          local item = reaper.GetSelectedMediaItem(0, 0)
          if item then
            local take = reaper.GetActiveTake(item)
            if take then
              local aa, aaStart, aaEnd, samplerate, itemLen = get_accessor_bounds(take)
              if aa then
                -- Calculate which sample was clicked
                local relX = (mouse_x - x) / w
                local samplePos = startSample + relX * visibleSamples
                local clickTime = (samplePos / totalSamples) * itemLen
                
                -- Get item position in project
                local itemStart = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
                
                -- Set edit cursor to the clicked position
                local cursorPos = itemStart + clickTime
                reaper.SetEditCurPos(cursorPos, false, false)
                
                statusMessage = string.format("Edit cursor set to %.3f", cursorPos)
              end
            end
          end
        end
        
        local isMouseClicked = reaper.ImGui_IsMouseClicked(ctx, 0)
        local isRightClicked = reaper.ImGui_IsMouseClicked(ctx, 1)

        local centerY = y + h / 2
        local halfH = h / 2
        local peakOffset = db_to_halfheight(peakCeiling, minDB, maxDB, curvePower, halfH)
        local peakYTop = centerY - peakOffset
        local peakYBot = centerY + peakOffset

        hoverMarkerIdx = nil
        if isInside and not isDragging and not isDraggingPeakCeiling and not isErasing then
          for _, marker in ipairs(phraseMarkerPositions) do
            local dx, dy = mouse_x - marker.x, mouse_y - marker.y
            if (dx*dx + dy*dy) <= (8*8) then
              hoverMarkerIdx = marker.markerIdx
              reaper.ImGui_SetMouseCursor(ctx, reaper.ImGui_MouseCursor_Hand())
              if showTooltips then
                if isRightClicked then
                  reaper.ImGui_SetTooltip(ctx, "Right-click to delete\nDouble-click to create")
                else
                  reaper.ImGui_SetTooltip(ctx, "Drag to adjust phrase boundary\nDouble-click to create/delete")
                end
              end
              break
            end
          end
        end

        if isInside and isRightClicked and not isDragging and not isDraggingPeakCeiling and not isErasing then
          isErasing = true
          eraserStartX, eraserStartY = mouse_x, mouse_y
          markersToDelete = {}
          reaper.ImGui_SetMouseCursor(ctx, reaper.ImGui_MouseCursor_Arrow())
        end

        if isErasing then
          for _, marker in ipairs(phraseMarkerPositions) do
            local dx, dy = mouse_x - marker.x, mouse_y - marker.y
            local dist = math.sqrt(dx*dx + dy*dy)
            if dist <= 20 then markersToDelete[marker.markerIdx] = true end
          end
          if reaper.ImGui_IsMouseReleased(ctx, 1) then
            local deletedCount = 0
            local sortedIndices = {}
            for idx, _ in pairs(markersToDelete) do table.insert(sortedIndices, idx) end
            table.sort(sortedIndices, function(a, b) return a > b end)
            for _, idx in ipairs(sortedIndices) do
              if deleteMarker(idx) then deletedCount = deletedCount + 1 end
            end
            if deletedCount > 0 then
              local item = reaper.GetSelectedMediaItem(0, 0)
              if item then
                local take = reaper.GetActiveTake(item)
                if take then recalculatePhraseLevels(take, item, phrases) end
              end
              adjustments = calculateVolumeAdjustments(phrases, correctionStrength / 100, preLimitBoost)
              waveformData = getAdjustedWaveform(item, numBars, phrases, adjustments, peakCeiling, trim, preLimitBoost)
              statusMessage = string.format("Deleted %d breakpoint(s)", deletedCount)
              waveformNeedsRedraw, cacheValid = true, false
            end
            isErasing = false
            markersToDelete = {}
          end
        end

        local clickedOnMarker = false
        if isInside and isMouseClicked and not isDragging and not isDraggingPeakCeiling and not isErasing then
          for _, marker in ipairs(phraseMarkerPositions) do
            local dx, dy = mouse_x - marker.x, mouse_y - marker.y
            if (dx*dx + dy*dy) <= (5*5) then
              isDraggingMarker = true
              draggedMarkerIdx = marker.markerIdx
              draggedMarkerX = mouse_x
              clickedOnMarker = true
              break
            end
          end
        end

        if isInside and reaper.ImGui_IsMouseDoubleClicked(ctx, 0)
           and not clickedOnMarker
           and not isDragging and not isDraggingPeakCeiling and not isErasing then
          local itemLen = 0
          for _, ph in ipairs(phrases) do if ph.endTime > itemLen then itemLen = ph.endTime end end
          local relX = (mouse_x - x) / w
          local samplePos = startSample + relX * visibleSamples
          local clickTime = (samplePos / totalSamples) * itemLen
          if createMarkerAtTime(clickTime) then
            local item = reaper.GetSelectedMediaItem(0, 0)
            if item then
              local take = reaper.GetActiveTake(item)
              if take then recalculatePhraseLevels(take, item, phrases) end
              adjustments = calculateVolumeAdjustments(phrases, correctionStrength / 100, preLimitBoost)
              waveformData = getAdjustedWaveform(item, numBars, phrases, adjustments, peakCeiling, trim, preLimitBoost)
            end
            waveformNeedsRedraw, cacheValid = true, false
          end
        end

        if isDraggingMarker then
          if reaper.ImGui_IsMouseReleased(ctx, 0) then
            isDraggingMarker = false
            local item = reaper.GetSelectedMediaItem(0, 0)
            if item then
              local take = reaper.GetActiveTake(item)
              if take then recalculatePhraseLevels(take, item, phrases) end
              adjustments = calculateVolumeAdjustments(phrases, correctionStrength / 100, preLimitBoost)
              waveformData = getAdjustedWaveform(item, numBars, phrases, adjustments, peakCeiling, trim, preLimitBoost)
              waveformNeedsRedraw, cacheValid = true, false
              statusMessage = "Breakpoint adjusted"
              phrasesManualllyAdjusted = true
            end
            draggedMarkerIdx, draggedMarkerX = nil, nil
          else
            draggedMarkerX = mouse_x
            local itemLen = 0
            for _, ph in ipairs(phrases) do if ph.endTime > itemLen then itemLen = ph.endTime end end
            local relX = (mouse_x - x) / w
            local samplePos = startSample + relX * visibleSamples
            local newTime = (samplePos / totalSamples) * itemLen
            
            if draggedMarkerIdx and phrases[draggedMarkerIdx] then
              -- Check if this is the first marker (edge marker at start)
              if draggedMarkerIdx == 1 then
                -- First marker: allow it to go all the way to 0
                newTime = math.max(0, math.min(newTime, phrases[draggedMarkerIdx + 1].endTime - 0.05))
              -- Check if this is the last marker (edge marker at end)
              elseif draggedMarkerIdx == #phrases - 1 then
                -- Last marker: allow it to go all the way to itemLen
                newTime = math.max(phrases[draggedMarkerIdx].startTime + 0.05, math.min(newTime, itemLen))
              else
                -- Middle markers: keep minimum spacing of 0.05 on both sides
                newTime = math.max(phrases[draggedMarkerIdx].startTime + 0.05, math.min(newTime, phrases[draggedMarkerIdx + 1].endTime - 0.05))
              end
              
              phrases[draggedMarkerIdx].endTime = newTime
              phrases[draggedMarkerIdx + 1].startTime = newTime
            end
            waveformNeedsRedraw, cacheValid = true, false
          end
        end
        

        local tol = 6
        hoverPeakCeiling = false
        if isInside then
          if math.abs(mouse_y - peakYTop) <= tol or math.abs(mouse_y - peakYBot) <= tol then
            hoverPeakCeiling = true
            reaper.ImGui_SetMouseCursor(ctx, reaper.ImGui_MouseCursor_ResizeNS())
            if showTooltips then
              reaper.ImGui_SetTooltip(ctx, string.format("Peak Ceiling: %.1f dB", peakCeiling))
            end
            if reaper.ImGui_IsMouseClicked(ctx, 0) and not isDraggingMarker and not isErasing then
              isDraggingPeakCeiling = true
            end
          end
        end

        if isDraggingPeakCeiling then
          if reaper.ImGui_IsMouseReleased(ctx, 0) then
            isDraggingPeakCeiling = false
            refreshWaveformDisplay()
          else
            local curOff = math.abs(centerY - mouse_y)
            curOff = math.max(0, math.min(halfH, curOff))
            local newDb = halfheight_to_db(curOff, minDB, maxDB, curvePower, halfH)
            newDb = math.max(-60, math.min(0, newDb))
            peakCeiling = newDb
            peakOffset = db_to_halfheight(peakCeiling, minDB, maxDB, curvePower, halfH)
          end
        end

        if isInside and reaper.ImGui_IsMouseClicked(ctx, 0) and not isDraggingMarker and not isDraggingPeakCeiling and not hoverPeakCeiling and not isErasing then
          isDragging = true
          dragStartY = mouse_y
          dragStartZoom = zoomLevel
          local total = #waveformData
          local vis = math.max(50, math.floor(total / zoomLevel))
          local startSamp = math.max(1, math.min(total - vis, math.floor(zoomCenter * total - vis / 2)))
          local relX = (mouse_x - x) / w
          dragStartCursorSample = startSamp + relX * vis
        end
        if isDragging and not isDraggingMarker and not isDraggingPeakCeiling and not isErasing then
          if reaper.ImGui_IsMouseReleased(ctx, 0) then
            isDragging = false
          else
            local deltaY = dragStartY - mouse_y
            local zoomFactor = 1 + (deltaY / 100)
            local newZoom = math.max(1.0, math.min(100.0, dragStartZoom * zoomFactor))
            local total = #waveformData
            local newVis = math.max(50, math.floor(total / newZoom))
            local relX = (mouse_x - x) / w
            local newStart = dragStartCursorSample - relX * newVis
            newStart = math.max(1, math.min(total - newVis, newStart))
            zoomCenter = (newStart + newVis / 2) / total
            zoomCenter = math.max(0, math.min(1, zoomCenter))
            zoomLevel = newZoom
            waveformNeedsRedraw = true
          end
        end

        local fg = reaper.ImGui_GetForegroundDrawList(ctx)
        reaper.ImGui_DrawList_AddRectFilled(fg, x, y, x + w, y + h, 0x1A1A1AFF)
        drawWaveform(fg, rawWaveformData, waveformData, x, y, w, h, minDB, maxDB, curvePower, zoomLevel, zoomCenter, rawWaveformOpacity)
        
        -- Draw gate overlay (red semi-transparent background where gate is reducing)
       local item = reaper.GetSelectedMediaItem(0, 0)
       if item and gateEnabled and gatePoints then
         drawGateOverlay(fg, gatePoints, waveformData, item, x, y, w, h, zoomLevel, zoomCenter, gateOverlayOpacity)
       end
       
        -- Draw phrase markers on top (so they're not red-tinted)
        drawPhraseMarkers(fg, phrases, waveformData, x, y, w, h, zoomLevel, zoomCenter, startSample, isDraggingMarker, draggedMarkerIdx, draggedMarkerX, hoverMarkerIdx, markersToDelete)
        -- Draw playhead line
        drawPlayhead(fg, item, x, y, w, h, zoomLevel, zoomCenter, totalSamples, startSample, visibleSamples)  
          
          
        if isErasing then
          reaper.ImGui_DrawList_AddCircle(fg, mouse_x, mouse_y, 20, 0xFF0000FF, 0, 2)
          reaper.ImGui_DrawList_AddLine(fg, mouse_x - 10, mouse_y, mouse_x + 10, mouse_y, 0xFF0000FF, 2)
          reaper.ImGui_DrawList_AddLine(fg, mouse_x, mouse_y - 10, mouse_x, mouse_y + 10, 0xFF0000FF, 2)
        end

        local PEAK_LINE_COLOR_FULL = 0xFF00FFFF
        local PEAK_LINE_OPACITY_FADED = 0x66
        local PEAK_LINE_COLOR_FADED = 0xFF00FF00 + PEAK_LINE_OPACITY_FADED
        local peakLineColor = (hoverPeakCeiling or isDraggingPeakCeiling) and PEAK_LINE_COLOR_FULL or PEAK_LINE_COLOR_FADED
        local centerY2 = y + h / 2
        local halfH2 = h / 2
        local peakOffset2 = db_to_halfheight(peakCeiling, minDB, maxDB, curvePower, halfH2)
        reaper.ImGui_DrawList_AddLine(fg, x, centerY2 - peakOffset2, x + w, centerY2 - peakOffset2, peakLineColor, 2)
        reaper.ImGui_DrawList_AddLine(fg, x, centerY2 + peakOffset2, x + w, centerY2 + peakOffset2, peakLineColor, 2)
        reaper.ImGui_DrawList_AddRect(fg, x, y, x + w, y + h, 0x808080FF, 0, 0, 1)

        local item = reaper.GetSelectedMediaItem(0, 0)
        drawTimeRuler(fg, item, x, y + h, w, rulerH, zoomLevel, zoomCenter, totalSamples, startSample, visibleSamples)

        local tooltipText = nil
        if hoverPeakCeiling then tooltipText = string.format("Peak Ceiling: %.1f dB", peakCeiling) end
        hoverMarkerIdx = nil
        if isInside and not isDragging and not isDraggingPeakCeiling and not isErasing then
          for _, marker in ipairs(phraseMarkerPositions) do
            local dx, dy = mouse_x - marker.x, mouse_y - marker.y
            if (dx*dx + dy*dy) <= (8*8) then
              hoverMarkerIdx = marker.markerIdx
              reaper.ImGui_SetMouseCursor(ctx, reaper.ImGui_MouseCursor_Hand())
              tooltipText = "Drag to adjust phrase boundary\nDouble click to create point\nRight click and drag to delete points"
              break
            end
          end
        end
        if tooltipText and showTooltips then
          local tooltipX = mouse_x + 10
          local tooltipY = mouse_y + 10
          local textColor = 0xFFFFFFFF
          local bgColor = 0x000000CC
          local padding = 4
          local lines = {}
          for line in tooltipText:gmatch("[^\n]+") do lines[#lines + 1] = line end
          local maxTextWidth = 0
          for _, line in ipairs(lines) do maxTextWidth = math.max(maxTextWidth, #line * 7) end
          local textHeight = #lines * 16
          reaper.ImGui_DrawList_AddRectFilled(fg, tooltipX - padding, tooltipY - padding, tooltipX + maxTextWidth + padding, tooltipY + textHeight + padding, bgColor, 2)
          for i, line in ipairs(lines) do
            reaper.ImGui_DrawList_AddText(fg, tooltipX, tooltipY + (i - 1) * 16, textColor, line)
          end
        end
      else
        reaper.ImGui_Text(ctx, "No waveform - select item and click Refresh")
      end

      reaper.ImGui_End(ctx)
    end
  end

  if showManualAdjustmentWarning and pendingSeparationSensitivity then
    local visible2, open2 = reaper.ImGui_Begin(ctx, 'Warning - Manual Adjustments', true, reaper.ImGui_WindowFlags_AlwaysAutoResize())
    if visible2 then
      reaper.ImGui_Text(ctx, "Adjusting separation sensitivity will re-detect phrases")
      reaper.ImGui_Text(ctx, "and overwrite your manual breakpoint adjustments.")
      reaper.ImGui_Spacing(ctx)
      reaper.ImGui_Text(ctx, "Continue?")
      reaper.ImGui_Spacing(ctx)
      if reaper.ImGui_Button(ctx, "Continue", 120, 25) then
        separationSensitivity = pendingSeparationSensitivity
        refreshWaveformWithDetection()
        showManualAdjustmentWarning = false
        pendingSeparationSensitivity = nil
      end
      reaper.ImGui_SameLine(ctx)
      if reaper.ImGui_Button(ctx, "Cancel", 120, 25) then
        showManualAdjustmentWarning = false
        pendingSeparationSensitivity = nil
      end
      reaper.ImGui_End(ctx)
    end
    if not open2 then
      showManualAdjustmentWarning = false
      pendingSeparationSensitivity = nil
    end
  end
  PopTheme()
  if open then reaper.defer(loop) end
end

loop()
