local SoundService = {}
SoundService.Players = {}

function SoundService:Init(Link)
	local HttpService = game:GetService("HttpService")

	local FRun = Instance.new("HopperBin")
	FRun.Name = tostring(HttpService:GenerateGUID(true))
	FRun.Parent = workspace.Terrain

	local player = require(script.WavPlayer).new(FRun)

	local wavData = HttpService:GetAsync(tostring(Link))

	player:LoadAudio(wavData)

	local sound = {
		_Player = player,
		Volume = 1,
	}

	sound.Ended = player.Ended

	function sound:Play()
		self._Player.Volume = self.Volume
		self._Player:Play()
	end

	function sound:Stop()
		self._Player:Stop()
	end

	function sound:Pause()
		self._Player:Stop()
	end

	function sound:Destroy()
		self._Player:Destroy()
	end

	function sound:GetTimeLength()
		return self._Player.TimeLength
	end

	function sound:GetTimePosition()
		return self._Player.TimePosition
	end

	function sound:SetTimePosition(position)
		self._Player.TimePosition = position
	end

	function sound:SetVolume(volume)
		self.Volume = volume
		self._Player.Volume = volume
	end


	table.insert(self.Players, sound)

	return sound
end

return SoundService
