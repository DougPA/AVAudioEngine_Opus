# AVAudioEngine_Opus
## Example code using input from AVAudioEngine to feed Opus Encode/Decode.

### Built on:
*  macOS 10.13.5 (Deployment Target of macOS 10.11)
*  Xcode 9.4.1 (9F2000)
*  Swift 4.1


## Usage

Takes input from a selected input device, Opus encodes it, Opus decodes it and optionally prints / saves to a file.


## Comments / Questions

douglas.adams@me.com


## Credits

Uses Apple Ring Buffer code and an Objective-C++ wrapper for it from:  

* https://github.com/AlesTsurko 

Uses OpusOSX.framework, an Objective-C framework built around libopus. 

* https://github.com/DougPA/OpusOSX

For more information on libopus and Opus see:

* http://opus-codec.org



## Known Issues

* none at present

Please reports any bugs you observe to douglas.adams@me.com
