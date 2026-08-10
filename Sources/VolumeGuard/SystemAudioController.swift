import AudioToolbox
import CoreAudio
import Foundation

struct AudioDeviceSnapshot: Equatable {
    let deviceID: AudioObjectID
    let deviceName: String
    let volume: Double?
    let canSetVolume: Bool
}

enum AudioControllerError: LocalizedError {
    case noOutputDevice
    case volumeUnavailable
    case volumeReadOnly
    case coreAudio(operation: String, status: OSStatus)

    var errorDescription: String? {
        switch self {
        case .noOutputDevice:
            return "没有可用的音频输出设备"
        case .volumeUnavailable:
            return "当前输出设备不提供系统音量"
        case .volumeReadOnly:
            return "当前输出设备的音量由硬件控制"
        case let .coreAudio(operation, status):
            return "\(operation)失败（Core Audio \(status)）"
        }
    }
}

/// Reads and writes only the default output device's scalar volume. It does not
/// open an audio stream, record audio, or install a virtual audio driver.
final class SystemAudioController {
    typealias ChangeHandler = () -> Void

    private let listenerQueue = DispatchQueue(label: "com.volumeguard.audio-listener")
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
                self.bindToCurrentDevice()
                self.deliverChange()
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
            self?.deliverChange()
        }
    }

    func snapshot() -> AudioDeviceSnapshot {
        guard let deviceID = try? defaultOutputDevice() else {
            return AudioDeviceSnapshot(
                deviceID: AudioObjectID(kAudioObjectUnknown),
                deviceName: "无输出设备",
                volume: nil,
                canSetVolume: false
            )
        }

        let volume = try? currentVolume(deviceID: deviceID)
        return AudioDeviceSnapshot(
            deviceID: deviceID,
            deviceName: deviceName(deviceID: deviceID),
            volume: volume,
            canSetVolume: hasWritableVolume(deviceID: deviceID)
        )
    }

    func setVolume(_ requestedVolume: Double) throws {
        let deviceID = try defaultOutputDevice()
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

        let channels = readableChannelVolumes(deviceID: deviceID).filter { channel, _ in
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

    private func currentVolume(deviceID: AudioObjectID) throws -> Double {
        var virtualMasterAddress = Self.virtualMasterVolumeAddress
        if let value = readScalar(deviceID: deviceID, address: &virtualMasterAddress) {
            return Double(value)
        }

        var masterAddress = Self.volumeAddress(element: kAudioObjectPropertyElementMaster)
        if let value = readScalar(deviceID: deviceID, address: &masterAddress) {
            return Double(value)
        }

        let channelVolumes = readableChannelVolumes(deviceID: deviceID).map { $0.value }
        guard let loudest = channelVolumes.max() else {
            throw AudioControllerError.volumeUnavailable
        }
        return Double(loudest)
    }

    private func readableChannelVolumes(deviceID: AudioObjectID) -> [(channel: UInt32, value: Float32)] {
        var volumes: [(channel: UInt32, value: Float32)] = []
        let channelCount = outputChannelCount(deviceID: deviceID)
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

    private func hasWritableVolume(deviceID: AudioObjectID) -> Bool {
        var virtualMasterAddress = Self.virtualMasterVolumeAddress
        if isSettable(deviceID: deviceID, address: &virtualMasterAddress) { return true }

        var masterAddress = Self.volumeAddress(element: kAudioObjectPropertyElementMaster)
        if isSettable(deviceID: deviceID, address: &masterAddress) { return true }

        let channelCount = outputChannelCount(deviceID: deviceID)
        guard channelCount > 0 else { return false }
        for channel in UInt32(1)...channelCount {
            var address = Self.volumeAddress(element: channel)
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

    private func bindToCurrentDevice() {
        removeDeviceListeners()
        guard let deviceID = try? defaultOutputDevice() else { return }
        observedDeviceID = deviceID

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.deliverChange()
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
    }

    private func deliverChange() {
        guard let handler = handler else { return }
        DispatchQueue.main.async(execute: handler)
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

    private static var virtualMasterVolumeAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMasterVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMaster
        )
    }
}
