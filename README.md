# WavService

> [!IMPORTANT]
> **WavService is currently in Beta!**
> Please report bugs or issues on our [Discord Server](https://canary.discord.com/invite/MvVBbftUYm).
>

## About

**WavService** is a runtime **Sound Player** that allows you to load `.wav` files directly Roblox sound services directly.

### Features

* Runtime image loading without publishing
* Works through a Roblox env by default
* Parse any PNG type file
* Currently in **Beta**

## Building

The project uses a `Rojo` format that can be built as a RBXM or RBXMX,Check [Releases](https://github.com/The-Bunker-Organization/WavService/releases) for the RBXM without building yourself.

## Using RBXM
Just path it to your instance or GUI for using it,it will generate a GUI for it using the PNG binary parsed

### Basic Format
```
local SoundService = require(path.to.MainModule) --you can also upload it and use as a module id like require(670000)

local sound = SoundService:Init("https://example.com/audio.wav") --NEEDS to be a .wav format
sound.Volume = 0.5 --Volume
sound:Play()
```

## Status

| Feature         | Status            |
| --------------- | ----------------- |
| Rojo loader / RBXM Module      | 🟢 Available      |
| Argon build     | 🟡 Working onto it |

## Contributing

Found a bug or have an improvement?

* Open an issue on the repository.
* Fork repository with your fix or addition.
* For urgent questions, email **[thebunkerproject@waifu.club](mailto:thebunkerproject@waifu.club)**.

## License

WavService is free and open-source software licensed under the **GNU General Public License v3.0 (GPL-3.0)**.
You are free to use, modify, and redistribute the software under the terms of the license.

See the [LICENSE](LICENSE) file for the full license text.
