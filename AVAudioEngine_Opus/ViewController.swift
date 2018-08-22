//
//  ViewController.swift
//  AVAudioEngine_Opus
//
//  Created by Douglas Adams on 7/24/18.
//  Copyright © 2018 Douglas Adams. All rights reserved.
//

import Cocoa
import AVFoundation
import OpusOSX
import Accelerate


//  DATA FLOW
//
//  Input device  ----->    InputNode Tap   ----->     AudioConverter     ----->
//
//                various                   various                       [Float]
//                various                   various                       pcmFloat32
//                various                   various                       24_000
//                various                   various                       interleaved
//                various                   various                       2 channels
//                various                   various                       2_400 frames
//
//
//  Ring Buffer   ----->    Opus Encoder    ----->     Opus Decoder       ----->
//
//                [Float]                   [UInt8]                       [Float]
//                pcmFloat32                Opus                          pcmFloat32
//                24_000                    24_000                        24_000
//                interleaved               interleaved                   interleaved
//                2 channels                2 channels                    2 channels
//                240 frames                240 frames                    240 frames


class ViewController                        : NSViewController {
  
  // ----------------------------------------------------------------------------
  // MARK: - Private properties
  
  @objc dynamic var inputs                  : [String] = AudioHelper.inputDeviceNames
  
  @IBOutlet private weak var startButton    : NSButton!
  @IBOutlet private weak var stopButton     : NSButton!
  @IBOutlet private weak var devicePopup    : NSPopUpButton!

  
  private var _encoder                      : OpaquePointer!
  private var _decoder                      : OpaquePointer!

  private var _audioConverter               : AVAudioConverter!
  private let _converterOutputFormat        = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                                            sampleRate: Opus.sampleRate,
                                                            channels: AVAudioChannelCount(Opus.channelCount),
                                                            interleaved: Opus.isInterleaved)!
  private let _converterOutputFrameCount    = Int(Opus.sampleRate / 10)
  
  private var _bufferInput                  : AVAudioPCMBuffer!
  private var _ringBuffer                   = RingBuffer()
  private let kRingBufferSlots              = 3
  private var _bufferOutput                 : AVAudioPCMBuffer!
  private var _bufferSemaphore              : DispatchSemaphore!

  private var _encoderOutput                = [UInt8](repeating: 0, count: Opus.frameCount)
  private var _decoderOutput                : AVAudioPCMBuffer!

  private var _tapInputBlock                : AVAudioNodeTapBlock!
  private var _tapBufferSize                : AVAudioFrameCount = 0
  private let _tapBus                       = 0

  private var _playbackQ                    = DispatchQueue(label: "Playback", qos: .userInteractive, attributes: [.concurrent])
  private var _q                            = DispatchQueue(label: "Object", qos: .userInteractive, attributes: [.concurrent])
  private var _producerIndex                : Int64 = 0
  
  private var _print                        = false
  private var _file                         = false

  private var _engine                       : AVAudioEngine?
  private var _appFolderURL                 : URL?
  private var _outputFileURL                : URL?
  private var _outputFile                   : AVAudioFile?
  private let kOutputFileName               = "test.caf"

  private var __outputActive                = false
  private var _outputActive                 : Bool {
    get { return _q.sync { __outputActive } }
    set { _q.sync(flags: .barrier) { __outputActive = newValue } } }

  // ----------------------------------------------------------------------------
  // MARK: - Overridden methods
  
  override func viewDidLoad() {
    super.viewDidLoad()
    
    createBuffers()

    createTapInputBlock()

    createOpusObjects()
  }
  
  deinit {
    _ringBuffer?.deallocate()
  }
  
  // ----------------------------------------------------------------------------
  // MARK: - Action methods
  
  @IBAction func start(_ sender: NSButton) {
    
    // check that the output format is compatible
    guard checkOutputFormat() else { return }
    
    // toggle the button states
    startButton.isEnabled = false
    stopButton.isEnabled = true
    
    // create the engine
    _engine = AVAudioEngine()
    
    // get the selected input device
    let device = AudioHelper.inputDevices[devicePopup.indexOfSelectedItem]
    
    // try to set it as the input device for the engine
    if setInputDevice(device.id) {
      
      // start capture using this input device
      startInput(device)
    }
  }

  @IBAction func stop(_ sender: NSButton) {

    // toggle the button states
    startButton.isEnabled = true
    stopButton.isEnabled = false

    // remove the Tap
    _engine!.inputNode.removeTap(onBus: _tapBus)

    // stop the output
    _outputActive = false

    // stop and deallocate the engine
    _engine!.stop()
    _engine = nil
  }

  @IBAction func printCheck(_ sender: NSButton) {
    _print = (sender.state == NSControl.StateValue.on)
  }
  
  @IBAction func fileCheck(_ sender: NSButton) {
    _file = (sender.state == NSControl.StateValue.on)

    // create an output file (if needed)
    if _file { setupOutputFile(kOutputFileName) }
  }
  
  // ----------------------------------------------------------------------------
  // MARK: - Private methods
  
  /// Capture data, convert it and place it in the ring buffer
  ///
  private func startInput(_ device: AHAudioDevice) {

    // get the input device's ASBD & derive the AVAudioFormat from it
    var asbd = device.asbd!
    let inputFormat = AVAudioFormat(streamDescription: &asbd)!
    
    // the Tap format is whatever the input node's output produces
    let tapFormat = _engine!.inputNode.outputFormat(forBus: _tapBus)
    
    // calculate a buffer size for 100 milliseconds of audio at the Tap
    //    NOTE: installTap header file says "Supported range is [100, 400] ms."
    _tapBufferSize = AVAudioFrameCount(tapFormat.sampleRate/10)
    
    Swift.print("Input            device  = \(device.name!), ID = \(device.id)")
    Swift.print("Input            format  = \(inputFormat)")
    Swift.print("Converter input  format  = \(tapFormat)")
    Swift.print("Converter output format  = \(_converterOutputFormat)")
    Swift.print("Settings          Print = \(_print), File = \(_file)\n")
    
    // setupt the converter to go from the Tap format to Opus format
    _audioConverter = AVAudioConverter(from: tapFormat, to: _converterOutputFormat)
    
    // clear the buffers
    clearBuffers()
    
    // start a thread to empty the ring buffer
    _bufferSemaphore = DispatchSemaphore(value: 0)
    _outputActive = true
    startOutput()

    _producerIndex = 0
    
    // setup the Tap callback to populate the ring buffer
    _engine!.inputNode.installTap(onBus: _tapBus, bufferSize: _tapBufferSize, format: tapFormat, block: _tapInputBlock)
    
    // prepare & start the engine
    _engine!.prepare()
    try! _engine!.start()
  }
  /// Start a thread to empty the ring buffer
  ///
  private func startOutput() {
    
    _playbackQ.async {
      
      // start at the beginning of the ring buffer
      var frameNumber : Int64 = 0
      
      while self._outputActive {
        
        // wait for the data
        self._bufferSemaphore.wait()
        
        // process 240 frames per iteration
        for _ in 0..<10 {

          let fetchError = self._ringBuffer!.fetch(self._bufferOutput.mutableAudioBufferList,
                                                   nFrame: UInt32(240),
                                                   frameNumnber: frameNumber)
          if fetchError != 0 { Swift.print("Fetch error = \(String(describing: fetchError))") }
          
          // ------------------ ENCODE ------------------

          // perform Opus encoding
          let encodedFrames = opus_encode_float(self._encoder,                            // an encoder
                                                self._bufferOutput.floatChannelData![0],  // source (interleaved .pcmFloat32)
                                                Int32(Opus.frameCount),                   // source, frames per channel
                                                &self._encoderOutput,                     // destination (Opus-encoded bytes)
                                                Int32(Opus.frameCount))                   // destination, max size (bytes)
          // check for encode errors
          if encodedFrames < 0 { Swift.print("Encoder error - " + String(cString: opus_strerror(encodedFrames))) }

          // ------------------ DECODE ------------------

          // perform Opus decoding
          let decodedFrames = opus_decode_float(self._decoder,                            // a decoder
                                                self._encoderOutput,                      // source (Opus-encoded bytes)
                                                Int32(encodedFrames),                     // source, number of bytes
                                                self._decoderOutput.floatChannelData![0], // destination (interleaved .pcmFloat32)
                                                Int32(Opus.frameCount),                   // destination, frames per channel
                                                Int32(0))
          // check for decode errors
          if decodedFrames < 0 { Swift.print("Decoder error - " + String(cString: opus_strerror(decodedFrames))) }

          // --------------- SAVE / PRINT ---------------

          // print a sample of the output
          if self._print { self.printDescription(self._decoderOutput, isInput: false) }

          // save the output to a file (use QuickLook to playback the file & verify its contents)
          if self._file { try! self._outputFile?.write(from: self._decoderOutput) }

          // bump the frame number
          frameNumber += Int64( Opus.frameCount )
        }
      }
    }
  }
  /// Create all of the buffers
  ///
  fileprivate func createBuffers() {
    
    // create the Ring buffer
    _ringBuffer!.allocate(UInt32(Opus.channelCount),
                          bytesPerFrame: UInt32(MemoryLayout<Float>.size * Int(_converterOutputFormat.channelCount)),
                          capacityFrames: UInt32(_converterOutputFrameCount * kRingBufferSlots))
    
    // create a buffer for output from the AudioConverter (input to the ring buffer)
    _bufferInput = AVAudioPCMBuffer(pcmFormat: _converterOutputFormat,
                                    frameCapacity: AVAudioFrameCount(_converterOutputFrameCount))!
    _bufferInput.frameLength = _bufferInput.frameCapacity
    
    // create a buffer for output from the ring buffer
    _bufferOutput = AVAudioPCMBuffer(pcmFormat: _converterOutputFormat,
                                     frameCapacity: AVAudioFrameCount(Opus.frameCount))!
    _bufferOutput.frameLength = _bufferOutput.frameCapacity
    
    // create a buffer for encoder output
    _decoderOutput = AVAudioPCMBuffer(pcmFormat: _converterOutputFormat,
                                      frameCapacity: AVAudioFrameCount(Opus.frameCount))!
    _decoderOutput.frameLength = _decoderOutput.frameCapacity
  }
  /// Create an Opus encoder and a decoder
  ///
  fileprivate func createOpusObjects() {
    
    // create the Opus encoder
    var opusError : Int32 = 0
    _encoder = opus_encoder_create(Int32(Opus.sampleRate),
                                   Int32(Opus.channelCount),
                                   Int32(Opus.application),
                                   &opusError)
    if opusError != OPUS_OK { fatalError("Unable to create OpusEncoder, error = \(opusError)") }
    
    // create the Opus decoder
    _decoder = opus_decoder_create(Int32(Opus.sampleRate),
                                   Int32(Opus.channelCount),
                                   &opusError)
    if opusError != 0 { fatalError("Unable to create OpusDecoder, error = \(opusError)") }
  }
  /// Set the input device for the engine
  ///
  /// - Parameter id:             an AudioDeviceID
  /// - Returns:                  true if successful
  ///
  private func setInputDevice(_ id: AudioDeviceID) -> Bool {
    
    // get the underlying AudioUnit
    let audioUnit = _engine!.inputNode.audioUnit!
    
    // set the new device as the input device
    var inputDeviceID = id
    let error = AudioUnitSetProperty(audioUnit,
                                     kAudioOutputUnitProperty_CurrentDevice,
                                     kAudioUnitScope_Global,
                                     0,
                                     &inputDeviceID,
                                     UInt32(MemoryLayout<AudioDeviceID>.size))
    // success if no errors
    return (error == noErr)
  }
  /// Create a block to process the Tap data
  ///
  private func createTapInputBlock() {
    
    _tapInputBlock = { [unowned self] (inputBuffer, time) in
      
      // show the input
      if self._print { self.printDescription(inputBuffer, isInput: true) }
      
      // setup the Converter callback (assumes no errors)
      var error: NSError?
      self._audioConverter.convert(to: self._bufferInput, error: &error, withInputFrom: { (inNumPackets, outStatus) -> AVAudioBuffer? in
        
        // signal we have the needed amount of data
        outStatus.pointee = AVAudioConverterInputStatus.haveData
        
        // return the data to be converted
        return inputBuffer
      } )

      // show the input
      if self._print { self.printDescription(self._bufferInput, isInput: true) }
      
      // push the converted audio into the Ring buffer
      let storeError = self._ringBuffer!.store(self._bufferInput.mutableAudioBufferList, nFrames: UInt32(self._converterOutputFrameCount), frameNumber: self._producerIndex )
      if storeError != 0 { Swift.print("Store error = \(String(describing: storeError))") }

      // bump the Ring buffer location
      self._producerIndex += Int64(self._converterOutputFrameCount)
      
      // signal the availability of data for the Output thread
      self._bufferSemaphore.signal()
    }
  }
  /// Create an output file in the Application Support folder
  ///
  /// - Parameter name:             a file name (with extension)
  ///
  private func setupOutputFile(_ name: String) {
    
    // get the Application Support folder
    let fileManager = FileManager()
    let urls = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask ) as [URL]
    _appFolderURL = urls.first!.appendingPathComponent( Bundle.main.bundleIdentifier! )
    
    // does the app's folder exist?
    if !fileManager.fileExists( atPath: _appFolderURL!.path ) {
      
      // NO, create it
      do {
        try fileManager.createDirectory( at: _appFolderURL!, withIntermediateDirectories: false, attributes: nil)
      } catch let error as NSError {
        fatalError("Error creating App Support folder: \(error.localizedDescription)")
      }
    }
    // add the file name
    _outputFileURL = _appFolderURL!.appendingPathComponent(name)
    
    // open the file, creating it if necessary, overwrites any existing file
    _outputFile = try! AVAudioFile(forWriting: _outputFileURL!, settings: _converterOutputFormat.settings, commonFormat: .pcmFormatFloat32, interleaved: true)
  }
  /// Clear all buffers
  ///
  private func clearBuffers() {

    // clear the buffers
    memset(_bufferInput.floatChannelData![0], 0, Int(_bufferInput.frameLength) * MemoryLayout<Float>.size * Opus.channelCount)
    memset(_bufferOutput.floatChannelData![0], 0, Int(_bufferOutput.frameLength) * MemoryLayout<Float>.size * Opus.channelCount)
    memset(_decoderOutput.floatChannelData![0], 0, Int(_decoderOutput.frameLength) * MemoryLayout<Float>.size * Opus.channelCount)
    
    // FIXME: Clear the ring buffer?
    
  }
  /// Check for a sample rate compatible with 24_000
  ///
  /// - Returns:                whether sample rate is valid
  ///
  private func checkOutputFormat() -> Bool {
    
    // get the default output device
    let outputDevice = AudioHelper.outputDevices.filter { $0.isDefault }.first!
    
    // get the device's format settings
    var asbd = outputDevice.asbd!
    let outputFormat = AVAudioFormat(streamDescription: &asbd)!
    
    // the rate must be evenly divisible by the Opus rate
    let remainder = outputFormat.sampleRate.truncatingRemainder(dividingBy: Double(Opus.sampleRate))
    if remainder != 0.0 {
      
      let a: NSAlert = NSAlert()
      a.messageText = "Invalid sample rate for \(outputDevice.name!) output"
      a.informativeText = "Sample rate must be evenly divisible by 24,000\n\nUse Audio MIDI Setup to change the rate"
      a.addButton(withTitle: "OK")
      
      a.beginSheetModal(for: view.window!, completionHandler: { (modalResponse: NSApplication.ModalResponse) -> Void in })
    }
    return (remainder == 0.0)
  }
  /// Print a description of a buffer
  ///
  /// - Parameters:
  ///   - buffer:             an AVAudioPCMBuffer Buffer
  ///   - isInput:            whether it is an input or an output
  ///
  private func printDescription(_ buffer: AVAudioPCMBuffer, isInput: Bool) {
    
    // if the buffer has any data
    if buffer.frameLength > 0 {
      
      let length = buffer.frameLength
      let lastEntry = Int(length - 1)
      let stride = buffer.stride
      let direction = isInput ? "Input  " : "Output "
      let channels = buffer.format.channelCount == 1 ? "(1 ch)" : "(2 ch)"
      
      // interleaved ? (implies 2 channel)
      if buffer.format.isInterleaved {
        // INTERLEAVED
        Swift.print("\(direction) buffer \(channels), length = \(length), stride = \(stride), left[\(lastEntry)] = \(buffer.floatChannelData![0].advanced(by: lastEntry * 2).pointee), right[\(lastEntry)] = \(buffer.floatChannelData![0].advanced(by: (lastEntry * 2) + 1).pointee)\(isInput ? "" : "\n")")
        
      } else {
        
        // NOT-INTERLEAVED, 2 channel?
        if buffer.format.channelCount == 2 {
          // 2 channel
          Swift.print("\(direction) buffer \(channels), length = \(length), stride = \(stride), left[\(lastEntry)] = \(buffer.floatChannelData![0].advanced(by: lastEntry).pointee), right[\(lastEntry)] = \(buffer.floatChannelData![1].advanced(by: lastEntry).pointee)\(isInput ? "" : "\n")")
        } else {
          // 1 channel
          Swift.print("\(direction) buffer \(channels), length = \(length), stride = \(stride), left[\(lastEntry)] = \(buffer.floatChannelData![0].advanced(by: lastEntry).pointee)\(isInput ? "" : "\n")")
        }
      }
    }
  }
  
  
  /*
   // ------------------ DE-INTERLEAVE ------------------

   private let kChannelLeft                  = 0
   private let kChannelRight                 = 1
   
   // view the current output buffer as a DSPSplitComplex
   var currentOutputBuffer = DSPSplitComplex(realp: self._output[self._outputIndex].floatChannelData![self.kChannelLeft],
   imagp: self._output[self._outputIndex].floatChannelData![self.kChannelRight])
   
   // view the decoder output (interleaved) as a DSPComplex
   UnsafePointer<Float>(self._decoderOutput).withMemoryRebound(to: DSPComplex.self, capacity: 1) { decoderOutput in
   
   // convert from the decoder output (rebound as a DSPComplex) to the output buffer ( viewed as a DSPSplitComplex)
   vDSP_ctoz(decoderOutput,                      // source
   ViewController.opus.channels,       // source stride
   &currentOutputBuffer,               // destination
   1,                                  // destination stride
   vDSP_Length(decodedFrames))         // # of frames
   }
   */
}

