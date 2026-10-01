import AudioEngineKernels
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
/// **Real-time safety**: the render block and its state (`renderState`) live in the
/// Objective-C superclass, `BocanStereoExpanderKernelUnit`. Do not override
/// `internalRenderBlock` here: a Swift render block allocates on the audio thread.
final class StereoExpanderAudioUnit: BocanStereoExpanderKernelUnit {
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

    private var inputBusArray: AUAudioUnitBusArray!
    private var outputBusArray: AUAudioUnitBusArray!

    // MARK: - AUAudioUnit

    override init(
        componentDescription: AudioComponentDescription,
        options: AudioComponentInstantiationOptions = []
    ) throws {
        try super.init(componentDescription: componentDescription, options: options)
        try self.setupBuses()
        self.setupParameterTree()
    }

    override var inputBusses: AUAudioUnitBusArray {
        self.inputBusArray
    }

    override var outputBusses: AUAudioUnitBusArray {
        self.outputBusArray
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
            self.renderState.pointee.width = value
        }
        parameterTree?.implementorValueProvider = { [weak self] param in
            guard let self, param.address == 0 else { return 1.0 }
            return self.renderState.pointee.width
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
        (self.node.auAudioUnit as? StereoExpanderAudioUnit)?.renderState.pointee.width = clamped
    }

    public var bypass: Bool {
        get { self.node.bypass }
        set { self.node.bypass = newValue }
    }
}
