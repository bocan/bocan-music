import AudioToolbox
@preconcurrency import AVFoundation
import Foundation

// MARK: - StereoExpanderAudioUnit

/// Custom `AUAudioUnit` implementing a mid/side stereo width processor.
///
/// **Algorithm** — Encode L/R to M/S, scale the side channel, decode back:
/// ```
///   M = (L + R) / 2
///   S = (L - R) / 2 × width
///   L_out = M + S,   R_out = M − S
/// ```
/// At `width = 1.0` this is an identity transform.
/// At `width = 0.0` the output is mono (L == R == M).
/// At `width = 2.0` the stereo image is doubled.
///
/// **Real-time safety**: same constraints as `CrossfeedAudioUnit` — only raw pointer
/// captured; no allocations or locks in the render block.
final class StereoExpanderAudioUnit: AUAudioUnit {
    // MARK: - Types

    struct State {
        var width: Float = 1.0 // 0.5…2.0 stereo width
    }

    // MARK: - Registration

    static let componentDescription = AudioComponentDescription(
        componentType: kAudioUnitType_Effect,
        componentSubType: 0x4263_6E65, // 'Bcne'
        componentManufacturer: 0x426F_636E, // 'Bocn'
        componentFlags: AudioComponentFlags.sandboxSafe.rawValue,
        componentFlagsMask: 0
    )

    static func registerIfNeeded() {
        AUAudioUnit.registerSubclass(
            StereoExpanderAudioUnit.self,
            as: self.componentDescription,
            name: "Bocan Stereo Expander",
            version: 1
        )
    }

    // MARK: - State

    let statePtr = UnsafeMutablePointer<State>.allocate(capacity: 1)
    private var inputBusArray: AUAudioUnitBusArray!
    private var outputBusArray: AUAudioUnitBusArray!

    // MARK: - AUAudioUnit

    override init(
        componentDescription: AudioComponentDescription,
        options: AudioComponentInstantiationOptions = []
    ) throws {
        try super.init(componentDescription: componentDescription, options: options)
        self.statePtr.initialize(to: State())
        try self.setupBuses()
        self.setupParameterTree()
    }

    deinit {
        statePtr.deinitialize(count: 1)
        statePtr.deallocate()
    }

    override var inputBusses: AUAudioUnitBusArray {
        self.inputBusArray
    }

    override var outputBusses: AUAudioUnitBusArray {
        self.outputBusArray
    }

    override var internalRenderBlock: AUInternalRenderBlock {
        let st = self.statePtr
        return { _, timestamp, frameCount, _, outputData, eventList, pullInput in
            // Process parameter events
            var evt = eventList
            while let event = evt {
                if event.pointee.head.eventType == .parameter ||
                    event.pointee.head.eventType == .parameterRamp {
                    if event.pointee.parameter.parameterAddress == 0 {
                        st.pointee.width = event.pointee.parameter.value
                    }
                }
                evt = UnsafePointer(event.pointee.head.next)
            }

            guard let pull = pullInput else { return kAudioUnitErr_NoConnection }
            var flags: AudioUnitRenderActionFlags = []
            let status = pull(&flags, timestamp, frameCount, 0, outputData)
            guard status == noErr else { return status }

            let abl = UnsafeMutableAudioBufferListPointer(outputData)
            guard abl.count >= 2,
                  let lPtr = abl[0].mData?.assumingMemoryBound(to: Float.self),
                  let rPtr = abl[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }

            let width = st.pointee.width
            let n = Int(frameCount)

            for i in 0 ..< n {
                let l = lPtr[i]
                let r = rPtr[i]
                let mid = 0.5 * (l + r)
                let side = 0.5 * (l - r) * width // scale side by width
                lPtr[i] = mid + side
                rPtr[i] = mid - side
            }

            return noErr
        }
    }

    // MARK: - Private setup

    private func setupBuses() throws {
        // swiftlint:disable:next force_unwrapping
        let fmt = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
        let inBus = try AUAudioUnitBus(format: fmt)
        let outBus = try AUAudioUnitBus(format: fmt)
        inBus.maximumChannelCount = 2
        outBus.maximumChannelCount = 2
        self.inputBusArray = AUAudioUnitBusArray(audioUnit: self, busType: .input, busses: [inBus])
        self.outputBusArray = AUAudioUnitBusArray(audioUnit: self, busType: .output, busses: [outBus])
    }

    private func setupParameterTree() {
        let widthParam = AUParameterTree.createParameter(
            withIdentifier: "width",
            name: "Stereo Width",
            address: 0,
            min: 0.5,
            max: 2.0,
            unit: .generic,
            unitName: nil,
            flags: [.flag_IsReadable, .flag_IsWritable],
            valueStrings: nil,
            dependentParameters: nil
        )
        widthParam.value = 1.0
        parameterTree = AUParameterTree.createTree(withChildren: [widthParam])

        parameterTree?.implementorValueObserver = { [weak self] param, value in
            guard let self, param.address == 0 else { return }
            self.statePtr.pointee.width = value
        }
        parameterTree?.implementorValueProvider = { [weak self] param in
            guard let self, param.address == 0 else { return 1.0 }
            return self.statePtr.pointee.width
        }
    }
}

// MARK: - StereoExpanderUnit

/// Wraps `StereoExpanderAudioUnit` in an `AVAudioUnitEffect`.
public final class StereoExpanderUnit: @unchecked Sendable {
    // @unchecked: AVAudioUnitEffect lacks Sendable; safety provided by AudioEngine actor.

    let node: AVAudioUnitEffect

    public init() {
        StereoExpanderAudioUnit.registerIfNeeded()
        self.node = AVAudioUnitEffect(
            audioComponentDescription: StereoExpanderAudioUnit.componentDescription
        )
    }

    /// Stereo width multiplier (0.5 = narrow, 1.0 = unchanged, 2.0 = wide).
    public func setWidth(_ width: Double) {
        let clamped = Float(max(0.5, min(2.0, width)))
        self.node.auAudioUnit.parameterTree?.parameter(withAddress: 0)?.setValue(clamped, originator: nil)
        (self.node.auAudioUnit as? StereoExpanderAudioUnit)?.statePtr.pointee.width = clamped
    }

    public var bypass: Bool {
        get { self.node.bypass }
        set { self.node.bypass = newValue }
    }
}
