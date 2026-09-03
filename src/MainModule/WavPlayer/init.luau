--!native
--!optimize 2
local WavPlayer = {}

local RunService = game:GetService("RunService")

const signal = require(script.Signal)

local m_sqrt  = math.sqrt
local m_atan2 = math.atan2
local m_pi    = math.pi
local m_abs   = math.abs
local m_floor = math.floor

const WINDOW_SIZE              = 1024
const HALF_WINDOW              = WINDOW_SIZE / 2
const HOP_SIZE                 = WINDOW_SIZE / 4  -- Re-analyse 4× per window → ~5.8 ms steps at 44100 Hz
const BASE_COMPONENT_FREQUENCY = 440

const VOL_NORM = 4 / WINDOW_SIZE

local HANN_WINDOW = table.create(WINDOW_SIZE)
do
	local coeff = 2 * m_pi / (WINDOW_SIZE - 1)
	for i = 1, WINDOW_SIZE do
		HANN_WINDOW[i] = 0.5 * (1 - math.cos(coeff * (i - 1)))
	end
end

local function createFftState(size)
	local state  = {}
	local log2n  = math.log(size) / math.log(2)

	state.bitRev = {}
	for i = 0, size - 1 do
		local rev  = 0
		local temp = i
		for j = 0, log2n - 1 do
			rev  = bit32.bor(bit32.lshift(rev, 1), bit32.band(temp, 1))
			temp = bit32.rshift(temp, 1)
		end
		state.bitRev[i] = rev
	end

	state.cosTable = {}
	state.sinTable = {}
	for k = 0, size // 2 - 1 do
		local angle       = -2 * m_pi * k / size
		state.cosTable[k] = math.cos(angle)
		state.sinTable[k] = math.sin(angle)
	end

	return state
end

local SHARED_FFT_STATE = createFftState(WINDOW_SIZE)

local function fft(reals, imaginaries, state)
	local n        = #reals
	local bitRev   = state.bitRev
	local cosTable = state.cosTable
	local sinTable = state.sinTable

	for i = 0, n - 1 do
		local j = bitRev[i]
		if j > i then
			reals[i+1], reals[j+1]             = reals[j+1], reals[i+1]
			imaginaries[i+1], imaginaries[j+1] = imaginaries[j+1], imaginaries[i+1]
		end
	end

	local m = 1
	while m < n do
		local m2 = m * 2
		for k = 0, m - 1 do
			local cos = cosTable[k * n // m2]
			local sin = sinTable[k * n // m2]
			for j = k, n - 1, m2 do
				local jm1  = j + m + 1
				local j1   = j + 1
				local rm1  = reals[jm1]
				local im1  = imaginaries[jm1]
				local t_re = cos * rm1 - sin * im1
				local t_im = sin * rm1 + cos * im1
				local r    = reals[j1]
				local im   = imaginaries[j1]
				reals[jm1]       = r  - t_re
				imaginaries[jm1] = im - t_im
				reals[j1]        = r  + t_re
				imaginaries[j1]  = im + t_im
			end
		end
		m = m2
	end

	return reals, imaginaries
end

local function getString(length, offset, blob)
	local t = table.create(length)
	for i = 1, length do
		t[i] = string.char(buffer.readu8(blob, offset + i - 1))
	end
	return table.concat(t)
end

local WavPlayerProxy = {}

WavPlayerProxy.__index = function(self, key)
	if key == "IsPlaying"  then return self._isPlaying  end
	if key == "IsReady"    then return self._isReady    end
	if key == "TimeLength" then return self._timeLength end
	if key == "Ended"      then return self._endedEvent end
	local v = rawget(self, key)
	if v ~= nil then return v end
	return WavPlayer[key]
end

WavPlayerProxy.__newindex = function(self, key, value)
	if key == "IsPlaying" or key == "IsReady" or key == "TimeLength" or key == "Ended" then
		error(string.format("Property '%s' is read-only.", key), 2)
	end
	if rawget(self, key) == value then return end

	if key == "PlaybackSpeed" then
		rawset(self, "PlaybackSpeed", value)
		self:_updateWaveFrequencies()
	elseif key == "TimePosition" then
		rawset(self, "TimePosition", value)
		self._previousIndex = -1
	else
		rawset(self, key, value)
	end
end

function WavPlayer.new(parent)
	local self = setmetatable({}, WavPlayerProxy)

	self.Parent        = parent
	self.PlaybackSpeed = 1
	self.Volume        = 1
	self.BitCrush      = 1
	self.TimePosition  = 0
	self.Looping       = true
	self.AutoPlay      = true

	self._isPlaying  = false
	self._isReady    = false
	self._timeLength = 0

	self._endedEvent  = signal.new()
	self._waves       = {}
	self._waveParams  = {}
	self._connections = {}

	self._reals       = table.create(WINDOW_SIZE,     0)
	self._imaginaries = table.create(WINDOW_SIZE,     0)
	self._magnitudes  = table.create(HALF_WINDOW + 1, 0)
	self._phases      = table.create(HALF_WINDOW + 1, 0)

	self._smoothedMagnitudes = table.create(HALF_WINDOW + 1, 0)

	self._previousIndex = -1

	self.AudioDeviceOutput        = Instance.new("AudioDeviceOutput")
	self.AudioDeviceOutput.Name   = "WavOutput"
	self.AudioDeviceOutput.Parent = self.Parent

	self.AudioAnalyzer        = Instance.new("AudioAnalyzer")
	self.AudioAnalyzer.Name   = "WavAnalyzer"
	self.AudioAnalyzer.Parent = self.Parent

	self:_initializeWaves()

	return self
end

function WavPlayer:LoadAudio(wavString)
	local wasPlaying = self._isPlaying
	self:Stop()

	if self._data then
		buffer.fill(self._data, 0, 0, buffer.len(self._data))
	end

	self._data = buffer.fromstring(wavString)
	self:_parseHeader()

	local actualDataBytes = buffer.len(self._data) - self.ByteOffset
	local actualSamples   = actualDataBytes / self.Channels / self.BytesPerSample
	self._timeLength      = actualSamples / self.SamplingRate
	self._isReady         = true

	self.TimePosition   = 0
	self._previousIndex = -1

	local sm = self._smoothedMagnitudes
	for i = 1, HALF_WINDOW + 1 do sm[i] = 0 end

	self:_updateWaveFrequencies()

	if wasPlaying or self.AutoPlay then
		self:Play()
	end
end

function WavPlayer:_parseHeader()
	local data       = self._data
	local byteOffset = 16

	local formatChunkSize = buffer.readu32(data, byteOffset)
	byteOffset            = 22
	self.Channels         = buffer.readu16(data, byteOffset)

	if self.Channels ~= 1 then
		error("WavPlayer currently only supports mono files")
	end

	byteOffset         = 24
	self.SamplingRate  = buffer.readu32(data, byteOffset)
	byteOffset         = 34
	self.BitsPerSample = buffer.readu16(data, byteOffset)

	byteOffset = byteOffset + 2
	if formatChunkSize == 18 then
		byteOffset = byteOffset + 2
	elseif formatChunkSize == 40 then
		byteOffset = byteOffset + 24
	elseif formatChunkSize ~= 16 then
		error("Unsupported WAV format chunk size: " .. formatChunkSize)
	end

	local header = ""
	while header ~= "data" do
		header     = getString(4, byteOffset, data)
		byteOffset = byteOffset + 1
	end
	byteOffset = byteOffset + 3

	self.DataSize       = buffer.readu32(data, byteOffset)
	self.BytesPerSample = self.BitsPerSample / 8
	self.Samples        = self.DataSize / self.Channels / self.BytesPerSample
	self.MaxValue       = 2 ^ (self.BitsPerSample - 1)
	self.ByteOffset     = byteOffset + 4
end

function WavPlayer:_makeSine(i, frequency)
	local p          = Instance.new("AudioPlayer")
	p.Volume         = 0
	p.Looping        = true
	p.Name           = tostring(i)
	p.LoopRegion     = NumberRange.new(0.2, 4.5)
	p.PlaybackRegion = NumberRange.new(0.2, 4.5)
	p.Parent         = self.Parent

	if frequency == 0 then
		p.AssetId       = "rbxassetid://9040512197"
		p.PlaybackSpeed = 0
	else
		local freqPbs = frequency / BASE_COMPONENT_FREQUENCY
		if freqPbs > 20 then
			p.AssetId       = "rbxassetid://198099744"
			p.PlaybackSpeed = frequency / 1050
		else
			p.AssetId       = "rbxassetid://9040512197"
			p.PlaybackSpeed = freqPbs
		end
	end

	local outWire          = Instance.new("Wire")
	outWire.Name           = "OutWire"
	outWire.SourceInstance = p
	outWire.TargetInstance = self.AudioDeviceOutput
	outWire.Parent         = p

	local analyzerWire          = Instance.new("Wire")
	analyzerWire.Name           = "AnalyzerWire"
	analyzerWire.SourceInstance = p
	analyzerWire.TargetInstance = self.AudioAnalyzer
	analyzerWire.Parent         = p

	p:Play()
	return p
end

function WavPlayer:_initializeWaves()
	for i = 0, HALF_WINDOW do
		table.insert(self._waves, self:_makeSine(i, 0))
	end
	self:_updateWaveFrequencies()
end

function WavPlayer:_updateWaveFrequencies()
	if not self._isReady then return end

	local absSpeed     = m_abs(self.PlaybackSpeed)
	local hzMultiplier = self.SamplingRate / WINDOW_SIZE

	for i, wave in next, self._waves do
		local idx        = i - 1
		local pit        = idx * hzMultiplier * absSpeed
		local freqPbs    = pit / BASE_COMPONENT_FREQUENCY
		local isHighFreq = freqPbs > 20

		if isHighFreq then
			wave.AssetId       = "rbxassetid://198099744"
			wave.PlaybackSpeed = pit / 1050
		else
			wave.AssetId       = "rbxassetid://9040512197"
			wave.PlaybackSpeed = freqPbs
		end

		self._waveParams[i] = {
			pit            = pit,
			crossPoint     = isHighFreq and 2.531 or 0.812,
			halfWavePeriod = isHighFreq and (1 / 2100) or (1 / (BASE_COMPONENT_FREQUENCY * 2))
		}
	end
end

function WavPlayer:_update(dt)
	if not self._isReady or not self._data or not self.Parent or not self.Parent.Parent then
		for _, wave in next, self._waves do
			wave.Volume = 0
		end
		return
	end

	local nextPos = self.TimePosition + dt * self.PlaybackSpeed
	local timeLen = self._timeLength

	if self.Looping then
		rawset(self, "TimePosition", nextPos % timeLen)
	else
		if nextPos >= timeLen then
			rawset(self, "TimePosition", timeLen)
			self:Stop()
			self._endedEvent:Fire()
			return
		elseif nextPos < 0 then
			rawset(self, "TimePosition", 0)
			self:Stop()
			return
		else
			rawset(self, "TimePosition", nextPos)
		end
	end

	-- Advance the hop pointer 4x faster than the full window so volumes/phases
	-- update every ~5.8 ms instead of ~23 ms, eliminating the staircase delay.
	local hopIndex = m_floor(self.TimePosition * (self.SamplingRate / HOP_SIZE)) * HOP_SIZE

	if hopIndex ~= self._previousIndex then
		local rawBuffer    = self._data
		local bufLen       = buffer.len(rawBuffer)
		-- Centre the analysis window on the current playback position so the
		-- FFT reflects the audio being heard right now, not a past boundary.
		local centerSample = m_floor(self.TimePosition * self.SamplingRate)
		local baseOffset   = self.ByteOffset + (centerSample - HALF_WINDOW) * self.BytesPerSample
		local crush      = self.BitCrush or 1
		local maxVal     = self.MaxValue
		local bits       = self.BitsPerSample
		local bytesPS    = self.BytesPerSample
		local reals      = self._reals
		local imaginaries = self._imaginaries
		local hann       = HANN_WINDOW

		local readSample
		if bits == 8 then
			readSample = buffer.readi8
		elseif bits == 16 then
			readSample = buffer.readi16
		else
			readSample = buffer.readi32
		end

		task.desynchronize()

		if crush == 1 then
			for i = 1, WINDOW_SIZE do
				local bytePos = baseOffset + (i - 1) * bytesPS
				local sample  = 0
				if bytePos >= 0 and (bytePos + bytesPS) <= bufLen then
					sample = readSample(rawBuffer, bytePos)
				end
				reals[i]       = (sample / maxVal) * hann[i]
				imaginaries[i] = 0
			end
		else
			local prevNorm = 0
			for i = 1, WINDOW_SIZE do
				if i % crush == 0 or i == 1 then
					local bytePos = baseOffset + (i - 1) * bytesPS
					local sample  = 0
					if bytePos >= 0 and (bytePos + bytesPS) <= bufLen then
						sample = readSample(rawBuffer, bytePos)
					end
					prevNorm = sample / maxVal
				end
				reals[i]       = prevNorm * hann[i]
				imaginaries[i] = 0
			end
		end

		self._reals, self._imaginaries = fft(reals, imaginaries, SHARED_FFT_STATE)
		reals        = self._reals
		imaginaries  = self._imaginaries

		local magnitudes = self._magnitudes
		local phases     = self._phases
		local waveCount  = #self._waves

		for i = 1, waveCount do
			local r  = reals[i]
			local im = imaginaries[i]
			magnitudes[i] = m_sqrt(r * r + im * im)
			phases[i]     = m_atan2(im, r)
		end

		task.synchronize()

		local volMult  = VOL_NORM * self.Volume
		local smoothed = self._smoothedMagnitudes
		local waves    = self._waves
		local wParams  = self._waveParams
		local mags     = self._magnitudes
		local phs      = self._phases

		for i = 1, waveCount do
			local wave = waves[i]
			local wp   = wParams[i]

			if not wave.Parent then
				pcall(game.Destroy, wave)
				waves[i] = self:_makeSine(i - 1, wp.pit)
				wave     = waves[i]
			end

			local target = mags[i] * volMult
			local prev   = smoothed[i]

			-- Fast attack (instant) + fast release (3 frames to ~3% residual)
			-- vs the old 0.7/0.3 split that left ~28% residual after 1 frame.
			smoothed[i] = target >= prev and target or (prev * 0.3 + target * 0.7)

			wave.TimePosition = wp.crossPoint + (phs[i] / m_pi) * wp.halfWavePeriod
			wave.Volume       = smoothed[i]
		end
	end

	self._previousIndex = hopIndex
end

function WavPlayer:Play()
	if not self._isReady or self._isPlaying then return end
	self._isPlaying = true

	table.insert(self._connections, RunService.Heartbeat:Connect(function(dt)
		self:_update(dt)
	end))
end

function WavPlayer:Stop()
	self._isPlaying = false
	for _, conn in next, self._connections do
		conn:Disconnect()
	end
	table.clear(self._connections)
	for _, wave in next, self._waves do
		wave.Volume = 0
	end
end

function WavPlayer:Destroy()
	self:Stop()
	self._isReady = false

	if self._data then
		buffer.fill(self._data, 0, 0, buffer.len(self._data))
		self._data = nil
	end

	if self._endedEvent then
		self._endedEvent:Destroy()
		self._endedEvent = nil
	end

	for _, wave in next, self._waves do
		wave:Destroy()
	end
	table.clear(self._waves)
	table.clear(self._waveParams)

	if self.AudioDeviceOutput then
		self.AudioDeviceOutput:Destroy()
		self.AudioDeviceOutput = nil
	end
	if self.AudioAnalyzer then
		self.AudioAnalyzer:Destroy()
		self.AudioAnalyzer = nil
	end
end

return WavPlayer
