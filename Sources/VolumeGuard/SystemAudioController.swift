import AudioToolbox
import CoreAudio
import Foundation
import VolumeGuardCore

struct AudioDeviceSnapshot: Equatable {
    let deviceID: AudioObjectID
    let deviceIdentifier: String
    let deviceName: String
    let category: AudioDeviceCategory
    let volume: Double?
    let canSetVolume: Bool
    let isMuted: Bool?
    let canSetMute: Bool
}

enum AudioControllerError: LocalizedError {
    case noOutputDevice
    case volumeUnavailable
    case volumeReadOnly
    case muteReadOnly
    case coreAudio(operation: String, status: OSStatus)

    var errorDescription: String? {
        switch self {
        case .noOutputDevice:
            return "没有可用的音频输出设备"
        case .volumeUnavailable:
            return "当前输出设备不提供系统音量"
        case .volumeReadOnly:
            return "当前输出设备的音量由硬件控制"
        case .muteReadOnly:
            return "当前输出设备不提供系统静音控制"
        case let .coreAudio(operation, status):
            return "\(operation)失败（Core Audio \(status)）"
        }
    }
}

enum AudioChangeReason {
    case volumeOrMute
    case outputDevice
    case systemWake
}

/// Reads and writes only the default output device's scalar volume. It does not
/// open an audio stream, record audio, or install a virtual audio driver.
final class SystemAudioController {
    typealias ChangeHandler = (AudioChangeReason) -> Void

    private struct DeviceMetadata {
        let deviceID: AudioObjectID
        let identifier: String
        let name: String
        let category: AudioDeviceCategory
        let canSetVolume: Bool
        let canSetMute: Bool
        let outputChannelCount: UInt32
    }

    private let listenerQueue = DispatchQueue(label: "com.volumeguard.audio-listener")
    private let metadataLock = NSLock()
    private var cachedMetadata: DeviceMetadata?
    private var handler: ChangeHandler?
    private var systemListener: AudioObjectPropertyListenerBlock?
    private var observedSystemAddresses: [AudioObjectPropertyAddress] = []
    private var deviceListener: AudioObjectPropertyListenerBlock?
    private var observedDeviceID = AudioObjectID(kAudioObjectUnknown)
    private var observedAddresses: [AudioObjectPropertyAddress] = []

    deinit {
        stopMonitoring()
    }

    func startMonitoring(changeHandler: @escaping ChangeHandler) {
        guard handler == nil else { return }
        handler = changeHandler

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self = self else { return }
            self.listenerQueue.async {
                let previousDeviceID = self.observedDeviceID
                self.bindToCurrentDevice()
                let reason: AudioChangeReason = previousDeviceID == self.observedDeviceID
                    ? .volumeOrMute
                    : .outputDevice
                self.deliverChange(reason)
            }
        }
        systemListener = block
        let systemID = AudioObjectID(kAudioObjectSystemObject)
        let addresses = [
            Self.defaultOutputAddress,
            AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDevices,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMaster
            )
        ]
        for var address in addresses {
            let status = AudioObjectAddPropertyListenerBlock(
                systemID,
                &address,
                listenerQueue,
                block
            )
            if status == noErr { observedSystemAddresses.append(address) }
        }
        listenerQueue.async { [weak self] in
            self?.bindToCurrentDevice()
        }
    }

    func stopMonitoring() {
        handler = nil
        if let block = systemListener {
            for var address in observedSystemAddresses {
                AudioObjectRemovePropertyListenerBlock(
                    AudioObjectID(kAudioObjectSystemObject),
                    &address,
                    listenerQueue,
                    block
                )
            }
        }
        observedSystemAddresses.removeAll()
        systemListener = nil
        removeDeviceListeners()
    }

    func rebindMonitoring() {
        listenerQueue.async { [weak self] in
            self?.bindToCurrentDevice()
            self?.deliverChange(.systemWake)
        }
    }

    func snapshot() -> AudioDeviceSnapshot {
        guard let deviceID = try? defaultOutputDevice() else {
            return AudioDeviceSnapshot(
                deviceID: AudioObjectID(kAudioObjectUnknown),
                deviceIdentifier: "no-output-device",
                deviceName: "无输出设备",
                category: .other,
                volume: nil,
                canSetVolume: false,
                isMuted: nil,
                canSetMute: false
            )
        }

        let metadata = metadataForDevice(deviceID)
        let volume = try? currentVolume(
            deviceID: deviceID,
            channelCount: metadata.outputChannelCount
        )
        return AudioDeviceSnapshot(
            deviceID: deviceID,
            deviceIdentifier: metadata.identifier,
            deviceName: metadata.name,
            category: metadata.category,
            volume: volume,
            canSetVolume: metadata.canSetVolume,
            isMuted: currentMute(deviceID: deviceID, channelCount: metadata.outputChannelCount),
            canSetMute: metadata.canSetMute
        )
    }

    func setVolume(_ requestedVolume: Double) throws {
        let deviceID = try defaultOutputDevice()
        let metadata = metadataForDevice(deviceID)
        let target = Float32(min(max(requestedVolume, 0), 1))

        var virtualMasterAddress = Self.virtualMasterVolumeAddress
        if isSettable(deviceID: deviceID, address: &virtualMasterAddress) {
            var value = target
            let status = AudioObjectSetPropertyData(
                deviceID,
                &virtualMasterAddress,
                0,
                nil,
                UInt32(MemoryLayout<Float32>.size),
                &value
            )
            guard status == noErr else {
                throw AudioControllerError.coreAudio(operation: "设置虚拟主音量", status: status)
            }
            return
        }

        var masterAddress = Self.volumeAddress(element: kAudioObjectPropertyElementMaster)
        if isSettable(deviceID: deviceID, address: &masterAddress) {
            var value = target
            let status = AudioObjectSetPropertyData(
                deviceID,
                &masterAddress,
                0,
                nil,
                UInt32(MemoryLayout<Float32>.size),
                &value
            )
            guard status == noErr else {
                throw AudioControllerError.coreAudio(operation: "设置主音量", status: status)
            }
            return
        }

        let channels = readableChannelVolumes(
            deviceID: deviceID,
            channelCount: metadata.outputChannelCount
        ).filter { channel, _ in
            var address = Self.volumeAddress(element: channel)
            return isSettable(deviceID: deviceID, address: &address)
        }
        guard !channels.isEmpty else { throw AudioControllerError.volumeReadOnly }

        // Scale each channel by the same ratio so existing left/right balance is
        // preserved. The loudest channel lands on the requested ceiling.
        let loudest = channels.map { $0.value }.max() ?? 0
        let ratio: Float32 = loudest > 0 ? min(1, target / loudest) : 0
        var didSetAnyChannel = false
        var lastError: OSStatus = noErr

        for (channel, oldVolume) in channels {
            var address = Self.volumeAddress(element: channel)
            var value = min(target, oldVolume * ratio)
            let status = AudioObjectSetPropertyData(
                deviceID,
                &address,
                0,
                nil,
                UInt32(MemoryLayout<Float32>.size),
                &value
            )
            if status == noErr {
                didSetAnyChannel = true
            } else {
                lastError = status
            }
        }

        guard didSetAnyChannel else {
            throw AudioControllerError.coreAudio(operation: "设置声道音量", status: lastError)
        }
    }

    func setMuted(_ muted: Bool) throws {
        let deviceID = try defaultOutputDevice()
        let metadata = metadataForDevice(deviceID)
        var muteValue: UInt32 = muted ? 1 : 0

        var masterAddress = Self.muteAddress(element: kAudioObjectPropertyElementMaster)
        if isSettable(deviceID: deviceID, address: &masterAddress) {
            let status = AudioObjectSetPropertyData(
                deviceID,
                &masterAddress,
                0,
                nil,
                UInt32(MemoryLayout<UInt32>.size),
                &muteValue
            )
            guard status == noErr else {
                throw AudioControllerError.coreAudio(operation: "设置静音", status: status)
            }
            return
        }

        guard metadata.outputChannelCount > 0 else { throw AudioControllerError.muteReadOnly }
        var didSetAnyChannel = false
        var lastError: OSStatus = noErr
        for channel in UInt32(1)...metadata.outputChannelCount {
            var address = Self.muteAddress(element: channel)
            guard isSettable(deviceID: deviceID, address: &address) else { continue }
            var value = muteValue
            let status = AudioObjectSetPropertyData(
                deviceID,
                &address,
                0,
                nil,
                UInt32(MemoryLayout<UInt32>.size),
                &value
            )
            if status == noErr {
                didSetAnyChannel = true
            } else {
                lastError = status
            }
        }
        guard didSetAnyChannel else {
            if lastError == noErr { throw AudioControllerError.muteReadOnly }
            throw AudioControllerError.coreAudio(operation: "设置声道静音", status: lastError)
        }
        if lastError != noErr {
            throw AudioControllerError.coreAudio(operation: "设置部分声道静音", status: lastError)
        }
    }

    private func defaultOutputDevice() throws -> AudioObjectID {
        var address = Self.defaultOutputAddress
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )
        guard status == noErr else {
            throw AudioControllerError.coreAudio(operation: "读取默认输出设备", status: status)
        }
        guard deviceID != AudioObjectID(kAudioObjectUnknown) else {
            throw AudioControllerError.noOutputDevice
        }
        return deviceID
    }

    private func currentVolume(deviceID: AudioObjectID, channelCount: UInt32) throws -> Double {
        var virtualMasterAddress = Self.virtualMasterVolumeAddress
        if let value = readScalar(deviceID: deviceID, address: &virtualMasterAddress) {
            return Double(value)
        }

        var masterAddress = Self.volumeAddress(element: kAudioObjectPropertyElementMaster)
        if let value = readScalar(deviceID: deviceID, address: &masterAddress) {
            return Double(value)
        }

        let channelVolumes = readableChannelVolumes(
            deviceID: deviceID,
            channelCount: channelCount
        ).map { $0.value }
        guard let loudest = channelVolumes.max() else {
            throw AudioControllerError.volumeUnavailable
        }
        return Double(loudest)
    }

    private func readableChannelVolumes(
        deviceID: AudioObjectID,
        channelCount: UInt32
    ) -> [(channel: UInt32, value: Float32)] {
        var volumes: [(channel: UInt32, value: Float32)] = []
        guard channelCount > 0 else { return [] }
        for channel in UInt32(1)...channelCount {
            var address = Self.volumeAddress(element: channel)
            if let value = readScalar(deviceID: deviceID, address: &address) {
                volumes.append((channel, value))
            }
        }
        return volumes
    }

    private func readScalar(
        deviceID: AudioObjectID,
        address: inout AudioObjectPropertyAddress
    ) -> Float32? {
        guard AudioObjectHasProperty(deviceID, &address) else { return nil }
        var value = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &size,
            &value
        )
        return status == noErr ? value : nil
    }

    private func readUInt32(
        deviceID: AudioObjectID,
        address: inout AudioObjectPropertyAddress
    ) -> UInt32? {
        guard AudioObjectHasProperty(deviceID, &address) else { return nil }
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value)
        return status == noErr ? value : nil
    }

    private func currentMute(deviceID: AudioObjectID, channelCount: UInt32) -> Bool? {
        var masterAddress = Self.muteAddress(element: kAudioObjectPropertyElementMaster)
        if let value = readUInt32(deviceID: deviceID, address: &masterAddress) {
            return value != 0
        }
        guard channelCount > 0 else { return nil }
        var values: [UInt32] = []
        for channel in UInt32(1)...channelCount {
            var address = Self.muteAddress(element: channel)
            if let value = readUInt32(deviceID: deviceID, address: &address) {
                values.append(value)
            }
        }
        guard !values.isEmpty else { return nil }
        return values.allSatisfy { $0 != 0 }
    }

    private func hasWritableVolume(deviceID: AudioObjectID, channelCount: UInt32) -> Bool {
        var virtualMasterAddress = Self.virtualMasterVolumeAddress
        if isSettable(deviceID: deviceID, address: &virtualMasterAddress) { return true }

        var masterAddress = Self.volumeAddress(element: kAudioObjectPropertyElementMaster)
        if isSettable(deviceID: deviceID, address: &masterAddress) { return true }

        guard channelCount > 0 else { return false }
        for channel in UInt32(1)...channelCount {
            var address = Self.volumeAddress(element: channel)
            if isSettable(deviceID: deviceID, address: &address) { return true }
        }
        return false
    }

    private func hasWritableMute(deviceID: AudioObjectID, channelCount: UInt32) -> Bool {
        var masterAddress = Self.muteAddress(element: kAudioObjectPropertyElementMaster)
        if isSettable(deviceID: deviceID, address: &masterAddress) { return true }
        guard channelCount > 0 else { return false }
        for channel in UInt32(1)...channelCount {
            var address = Self.muteAddress(element: channel)
            if isSettable(deviceID: deviceID, address: &address) { return true }
        }
        return false
    }

    private func isSettable(
        deviceID: AudioObjectID,
        address: inout AudioObjectPropertyAddress
    ) -> Bool {
        guard AudioObjectHasProperty(deviceID, &address) else { return false }
        var settable = DarwinBoolean(false)
        let status = AudioObjectIsPropertySettable(deviceID, &address, &settable)
        return status == noErr && settable.boolValue
    }

    private func deviceName(deviceID: AudioObjectID) -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMaster
        )
        var name: CFString = "未知设备" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &name) { pointer in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, pointer)
        }
        return status == noErr ? name as String : "未知设备"
    }

    private func deviceIdentifier(deviceID: AudioObjectID) -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMaster
        )
        var identifier: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &identifier) { pointer in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, pointer)
        }
        if status == noErr, !(identifier as String).isEmpty {
            return identifier as String
        }
        return "audio-object-\(deviceID)"
    }

    private func dataSourceIdentifier(deviceID: AudioObjectID) -> UInt32? {
        var sourceAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDataSource,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMaster
        )
        return readUInt32(deviceID: deviceID, address: &sourceAddress)
    }

    private func dataSourceName(deviceID: AudioObjectID) -> String? {
        guard var sourceID = dataSourceIdentifier(deviceID: deviceID) else { return nil }
        var nameAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDataSourceNameForIDCFString,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMaster
        )
        guard AudioObjectHasProperty(deviceID, &nameAddress) else { return nil }
        var name: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafePointer(to: &sourceID) { sourcePointer in
            withUnsafeMutablePointer(to: &name) { namePointer in
                AudioObjectGetPropertyData(
                    deviceID,
                    &nameAddress,
                    UInt32(MemoryLayout<UInt32>.size),
                    sourcePointer,
                    &size,
                    namePointer
                )
            }
        }
        guard status == noErr, !(name as String).isEmpty else { return nil }
        return name as String
    }

    private func deviceCategory(deviceID: AudioObjectID, name: String) -> AudioDeviceCategory {
        let normalizedName = "\(name) \(dataSourceName(deviceID: deviceID) ?? "")".lowercased()
        let headphoneHints = [
            "headphone", "headset", "earphone", "airpods", "earbuds", "buds",
            "耳机", "耳麥", "耳機", "beats", "wh-", "wf-"
        ]
        let looksLikeHeadphones = headphoneHints.contains { normalizedName.contains($0) }
        var transportAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMaster
        )
        let transport = readUInt32(deviceID: deviceID, address: &transportAddress)

        switch transport {
        case kAudioDeviceTransportTypeBuiltIn:
            return looksLikeHeadphones ? .wiredHeadphones : .builtInSpeakers
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            return looksLikeHeadphones ? .wirelessHeadphones : .externalSpeakers
        case kAudioDeviceTransportTypeAirPlay:
            return .airPlay
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort:
            return .display
        case kAudioDeviceTransportTypeUSB:
            return looksLikeHeadphones ? .wiredHeadphones : .usbAudio
        default:
            if looksLikeHeadphones { return .wiredHeadphones }
            if normalizedName.contains("display") || normalizedName.contains("monitor") {
                return .display
            }
            if normalizedName.contains("speaker") || normalizedName.contains("扬声器") {
                return .externalSpeakers
            }
            return .other
        }
    }

    private func outputChannelCount(deviceID: AudioObjectID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMaster
        )
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr,
              size >= UInt32(MemoryLayout<AudioBufferList>.size) else { return 0 }

        let rawPointer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { rawPointer.deallocate() }
        let audioBufferList = rawPointer.bindMemory(to: AudioBufferList.self, capacity: 1)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, audioBufferList) == noErr else {
            return 0
        }

        let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
        let count = buffers.reduce(UInt32(0)) { $0 + $1.mNumberChannels }
        return min(count, 64)
    }

    private func metadataForDevice(_ deviceID: AudioObjectID) -> DeviceMetadata {
        metadataLock.lock()
        if let cached = cachedMetadata, cached.deviceID == deviceID {
            metadataLock.unlock()
            return cached
        }
        metadataLock.unlock()

        let channelCount = outputChannelCount(deviceID: deviceID)
        let name = deviceName(deviceID: deviceID)
        let baseIdentifier = deviceIdentifier(deviceID: deviceID)
        let identifier = dataSourceIdentifier(deviceID: deviceID).map {
            "\(baseIdentifier)#source-\($0)"
        } ?? baseIdentifier
        let metadata = DeviceMetadata(
            deviceID: deviceID,
            identifier: identifier,
            name: name,
            category: deviceCategory(deviceID: deviceID, name: name),
            canSetVolume: hasWritableVolume(deviceID: deviceID, channelCount: channelCount),
            canSetMute: hasWritableMute(deviceID: deviceID, channelCount: channelCount),
            outputChannelCount: channelCount
        )
        metadataLock.lock()
        cachedMetadata = metadata
        metadataLock.unlock()
        return metadata
    }

    private func invalidateDeviceMetadata() {
        metadataLock.lock()
        cachedMetadata = nil
        metadataLock.unlock()
    }

    private func bindToCurrentDevice() {
        removeDeviceListeners()
        guard let deviceID = try? defaultOutputDevice() else { return }
        observedDeviceID = deviceID

        let block: AudioObjectPropertyListenerBlock = { [weak self] count, addresses in
            guard let self = self else { return }
            var reason = AudioChangeReason.volumeOrMute
            for index in 0..<Int(count) {
                switch addresses[index].mSelector {
                case kAudioDevicePropertyDeviceIsAlive, kAudioDevicePropertyDataSource:
                    self.invalidateDeviceMetadata()
                    reason = .outputDevice
                default:
                    break
                }
            }
            self.deliverChange(reason)
        }
        deviceListener = block

        let addresses = [
            Self.virtualMasterVolumeAddress,
            Self.volumeAddress(element: kAudioObjectPropertyElementWildcard),
            AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyMute,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: kAudioObjectPropertyElementWildcard
            ),
            AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceIsAlive,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMaster
            ),
            AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDataSource,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMaster
            )
        ]

        for var address in addresses {
            let status = AudioObjectAddPropertyListenerBlock(
                deviceID,
                &address,
                listenerQueue,
                block
            )
            if status == noErr {
                observedAddresses.append(address)
            }
        }
    }

    private func removeDeviceListeners() {
        if let block = deviceListener,
           observedDeviceID != AudioObjectID(kAudioObjectUnknown) {
            for var address in observedAddresses {
                AudioObjectRemovePropertyListenerBlock(
                    observedDeviceID,
                    &address,
                    listenerQueue,
                    block
                )
            }
        }
        observedAddresses.removeAll()
        observedDeviceID = AudioObjectID(kAudioObjectUnknown)
        deviceListener = nil
        invalidateDeviceMetadata()
    }

    private func deliverChange(_ reason: AudioChangeReason) {
        guard let handler = handler else { return }
        DispatchQueue.main.async {
            handler(reason)
        }
    }

    private static var defaultOutputAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMaster
        )
    }

    private static func volumeAddress(element: UInt32) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: element
        )
    }

    private static func muteAddress(element: UInt32) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: element
        )
    }

    private static var virtualMasterVolumeAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMasterVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMaster
        )
    }
}
