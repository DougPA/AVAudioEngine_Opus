//
//  AudioHelper.swift
//  AVAudioEngine_Opus
//
//  Created by Douglas Adams on 7/21/18.
//  Copyright © 2018 Douglas Adams. All rights reserved.
//

import Foundation
import CoreAudio
import AVFoundation

// ------------------------------------------------------------------------------
// MARK: - AudioHelper Class implementation
// ------------------------------------------------------------------------------

//public typealias DeviceID = UInt32

public final class AudioHelper {
  
  // ----------------------------------------------------------------------------
  // MARK: - Public properties
  
  public enum Direction: String {
    case input = "Input"
    case output = "Output"
  }
  
  public static var inputDevices            : [AHAudioDevice] { return getDeviceList(for: .input) }
  public static var inputDeviceNames        : [String] { return inputDevices.map  { $0.name! } }
  
  public static var outputDevices           : [AHAudioDevice] { return getDeviceList(for: .output) }
  public static var outputDeviceNames       : [String] { return outputDevices.map  { $0.name! } }
  
  // ----------------------------------------------------------------------------
  // MARK: - Public class methods
  
  /// Set the device as the default
  ///
  /// - Parameters:
  ///   - id:                 the DeviceID
  /// - Returns:              success / failure
  ///
  public class func setAsDefault(_ device: AHAudioDevice) -> Bool {
    
    var deviceID = device.id
    
    // get the device's direction
    let direction = directionOf(deviceID)
    
    var propertyAddress = AudioObjectPropertyAddress(mSelector: direction == .input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice,
                                                     mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMaster)
    // set the default device
    let error = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                           &propertyAddress,
                                           0,
                                           nil,
                                           UInt32(MemoryLayout<AudioDeviceID>.size),
                                           &deviceID)
    return error == noErr
  }
  
  // ----------------------------------------------------------------------------
  // MARK: - Private class methods
  
  /// Find all AudioDevices
  ///
  /// - Parameter direction:    Input / Output
  /// - Returns:                an array of AudioDevice
  ///
  public final class func getDeviceList(for direction: Direction) -> [AHAudioDevice] {
    
    var deviceArray = [AHAudioDevice]()
    var property = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMaster)
    // find the number of devices
    var size: UInt32 = 0
    var numberOfDevices = 0
    guard AudioObjectGetPropertyDataSize( AudioObjectID(kAudioObjectSystemObject),
                                          &property,
                                          0,
                                          nil,
                                          &size ) == noErr else { fatalError() }
    numberOfDevices = Int(size) / MemoryLayout<AudioDeviceID>.size
    
    // get the device ids
    let deviceIDs = UnsafeMutablePointer<UInt32>.allocate(capacity: numberOfDevices)
    guard AudioObjectGetPropertyData( AudioObjectID(kAudioObjectSystemObject),
                                      &property,
                                      0,
                                      nil,
                                      &size,
                                      deviceIDs ) == noErr else { fatalError() }
    numberOfDevices = Int(size) / MemoryLayout<AudioDeviceID>.size
    
    // iterate through the found devices
    for i in 0..<numberOfDevices {
      
      // is the device in the desired direction?
      if directionOf(deviceIDs.advanced(by: i).pointee) == direction {
        
        // YES, initialize an AudioDevice
        if let device = AHAudioDevice( id: deviceIDs.advanced(by: i ).pointee, direction: direction ) {
          
          // add it to the array
          deviceArray.append( device )
        }
      }
    }
    return deviceArray
  }
  /// Obtain the direction (Input/Output) of a Device
  ///
  /// - Parameters:
  ///   - id:                 a Device ID
  /// - Returns:              .input / .output
  ///
  private class func directionOf(_ deviceID: AudioDeviceID) -> Direction {
    var size : UInt32 = 0
    
    // setup for the specified direction
    var propertyAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                                     mScope: kAudioDevicePropertyScopeInput,
                                                     mElement: 0)
    // get the number of devices with the specified id & direction
    guard AudioObjectGetPropertyDataSize(deviceID,
                                         &propertyAddress,
                                         0,
                                         nil,
                                         &size) == noErr else { fatalError() }
    //
    return (size != 0 ? .input : .output)
  }
}

// ------------------------------------------------------------------------------
// MARK: - AHAudioDevice Struct implementation
// ------------------------------------------------------------------------------

public struct AHAudioDevice {
  
  // ----------------------------------------------------------------------------
  // MARK: - Public properties
  
  public var id                             : AudioDeviceID
  public var direction                      : AudioHelper.Direction
  
  public var asbd                           : AudioStreamBasicDescription? = nil
  public var isDefault                      : Bool { return isDefaultDevice(id, direction: direction) }
  public var name                           : String? = nil
  public var uniqueID                       : String? = nil
  public var formats                        = [AVAudioFormat]()
  
  // ----------------------------------------------------------------------------
  // MARK: - Initialization
  
  init?(id: AudioDeviceID, direction: AudioHelper.Direction) {
    var nameProperty = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                                                  mScope: kAudioObjectPropertyScopeGlobal,
                                                  mElement: kAudioObjectPropertyElementMaster)
    var uniqueIDProperty = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID,
                                                      mScope: kAudioObjectPropertyScopeGlobal,
                                                      mElement: kAudioObjectPropertyElementMaster)
    self.id = id
    self.direction = direction
    
    // get the Audio Stream Basic Description
    if let physicalFormat = getASBD(id, direction: direction) {
      // save it
      asbd = physicalFormat
      
      // get the name
      var string = "" as CFString
      var size = UInt32(MemoryLayout<CFString>.size)
      guard AudioObjectGetPropertyData( id,
                                        &nameProperty,
                                        0,
                                        nil,
                                        &size,
                                        &string ) == noErr else { return nil }
      name = string as String
      
      // get the unique ID
      guard AudioObjectGetPropertyData( id,
                                        &uniqueIDProperty,
                                        0,
                                        nil,
                                        &size,
                                        &string ) == noErr else { return nil }
      uniqueID = string as String
    }
    formats = getAllowedFormats(id, direction: direction)
  }
  
  // ----------------------------------------------------------------------------
  // MARK: - Public methods
  
  /// Produce a description of this class
  ///
  /// - Returns:              a String representation of the class
  ///
  //  public func desc() -> String {
  //    return "name = \(name!)" + "\n" +
  //      "id = \(id)" + "\n" +
  //      "direction = \(direction.rawValue)" + "\n" +
  //      "isDefault = \(isDefault)" + "\n" +
  //      "uniqueID = \(uniqueID!)" + "\n" +
  //      "ASBD = \(asbd!)" + "\n"
  //  }
  
  // ----------------------------------------------------------------------------
  // MARK: - Private methods
  
  /// Determine if this device is the Default device
  ///
  /// - Returns:                a Bool
  ///
  private func isDefaultDevice(_ deviceID: AudioDeviceID, direction: AudioHelper.Direction) -> Bool {
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    var deviceID : UInt32 = 0
    var property = AudioObjectPropertyAddress(mSelector: direction == .input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMaster)
    // get the default device
    guard AudioObjectGetPropertyData( AudioObjectID(kAudioObjectSystemObject),
                                      &property,
                                      0,
                                      nil,
                                      &size,
                                      &deviceID ) == noErr else { fatalError() }
    return deviceID == id
  }
  /// Get the Audio Stream Basic Description
  ///
  /// - Returns:              an ASBD (if any)
  ///
  private func getASBD(_ deviceID: AudioDeviceID, direction: AudioHelper.Direction) -> AudioStreamBasicDescription? {
    var asbd = AudioStreamBasicDescription()
    var formatProperty = AudioObjectPropertyAddress(mSelector: kAudioStreamPropertyPhysicalFormat,
                                                    mScope: direction == .input ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput,
                                                    mElement: kAudioObjectPropertyElementMaster)
    // get the AudioStreamBasicDescription
    var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    guard AudioObjectGetPropertyData( id,
                                      &formatProperty,
                                      0,
                                      nil,
                                      &size,
                                      &asbd ) == noErr else { fatalError() }
    return asbd
  }
  
  /// Return an array of allowed Formats for a Device
  ///
  /// - Parameters:
  ///   - deviceID:                 a device ID
  ///   - direction:                the device's direction (input/output)
  /// - Returns:                    an arry of AVAudioFormat
  ///
  private func getAllowedFormats(_ deviceID: AudioDeviceID, direction: AudioHelper.Direction) -> [AVAudioFormat] {
    var formats = [AVAudioFormat]()
    
    var property = AudioObjectPropertyAddress(mSelector: kAudioStreamPropertyAvailablePhysicalFormats,
                                              mScope: direction == .input ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput,
                                              mElement: kAudioObjectPropertyElementMaster)
    var sizeInBytes       : UInt32 = 0
    var numberOfRanges    = 0
    
    // get the size of the format list
    guard AudioObjectGetPropertyDataSize( deviceID as AudioObjectID, &property, 0, nil, &sizeInBytes ) == noErr else { return formats }
    if sizeInBytes > 0 {
      
      // calculate the number of AudioStreamRangedDescription(s), allocate space for them
      numberOfRanges = Int(sizeInBytes)/MemoryLayout<AudioStreamRangedDescription>.size
      let rangedFormats = UnsafeMutablePointer<AudioStreamRangedDescription>.allocate(capacity: numberOfRanges)
      
      // get the AudioStreamRangedDescription(s)
      guard AudioObjectGetPropertyData( deviceID, &property, 0, nil, &sizeInBytes, rangedFormats ) == noErr else { return formats }
      
      // convert them to AVAudioFormats
      for i in 0..<numberOfRanges {
        formats.append( AVAudioFormat(streamDescription: &rangedFormats[i].mFormat)! )
      }
      rangedFormats.deallocate()
    }
    return formats
  }
}
