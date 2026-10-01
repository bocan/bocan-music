import AudioEngineKernels
import AudioToolbox
@preconcurrency import AVFoundation
import Foundation

// MARK: - CrossfeedAudioUnit

/// Custom `AUAudioUnit` implementing Bauer headphone crossfeed.
///
/// **Algorithm** — Bauer (1961) stereo-to-binaural matrix, refined by Jan Meier (2000):
/// ```
///   L_out = L_in + level × LP(R_in)
///   R_out = R_in + level × LP(L_in)
/// ```
/// where LP is a 1st-order IIR low-pass at ~700 Hz (head shadow approximation) and
/// `level ≈ amount × 0.333` (≈ −9.5 dB of cross-talk at `amount = 1`).
///
/// - Reference: Bauer, B.B. (1961). *Stereophonic earphones and binaural loudspeakers.*
///   JAES 9(2):148–151. Implementation adapted from Jan Meier's "Improved Headphone
///   Listening" (2000), https://meier-audio.homepage.t-online.de/sound.htm
///
/// **Real-time safety**: the render block and its state (`renderState`) live in the
/// Objective-C superclass, `BocanCrossfeedKernelUnit`. Do not override
/// `internalRenderBlock` here: a Swift render block allocates on the audio thread,
/// once per cycle in every build and once per sample in an unoptimized one.
/// Parameter changes are delivered via the `AURenderEventList` on the render thread.
///
/// **Thread safety**: `amount` is written by the parameter tree observer on the main
/// thread and read on the render thread.  Aligned 4-byte reads/writes are effectively
/// atomic on both ARM64 and x86-64; a torn read causes at most one buffer of wrong level.
final class CrossfeedAudioUnit: BocanCrossfeedKernelUnit {
    // MARK: - Registration

    static let componentDescription = AudioComponentDescription(
        componentType: kAudioUnitType_Effect,
        componentSubType: 0x4263_6E78, // 'Bcnx'
        componentManufacturer: 0x426F_636E, // 'Bocn'
        componentFlags: AudioComponentFlags.sandboxSafe.rawValue,
        componentFlagsMask: 0
    )

    static func registerIfNeeded() {
        AUAudioUnit.registerSubclass(
            CrossfeedAudioUnit.self,
            as: self.componentDescription,
            name: "Bocan Crossfeed",
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

    override func allocateRenderResources() throws {
        try super.allocateRenderResources()
        let sr = self.outputBusses[0].format.sampleRate
        // 1st-order IIR LP: y[n] = α·y[n-1] + (1-α)·x[n], α = e^(−2π·fc/fs)
        let fc = 700.0 // Bauer crossfeed LP cutoff (Hz)
        self.renderState.pointee.lpAlpha = Float(exp(-2.0 * .pi * fc / sr))
        // Reset delay state on format change to avoid a pop.
        self.renderState.pointee.stateL = 0
        self.renderState.pointee.stateR = 0
    }

    // MARK: - Private setup

    private func setupBuses() throws {
        // Use a generic 44100 Hz stereo format; AVAudioEngine updates it via
        // allocateRenderResources when the real sample rate is known.
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
        let amountParam = AUParameterTree.createParameter(
            withIdentifier: "amount",
            name: "Crossfeed Amount",
            address: 0,
            min: 0,
            max: 1,
            unit: .generic,
            unitName: nil,
            flags: [.flag_IsReadable, .flag_IsWritable],
            valueStrings: nil,
            dependentParameters: nil
        )
        amountParam.value = 0
        parameterTree = AUParameterTree.createTree(withChildren: [amountParam])

        // Deliver parameter changes from the main thread to the render thread.
        parameterTree?.implementorValueObserver = { [weak self] param, value in
            guard let self, param.address == 0 else { return }
            self.renderState.pointee.amount = value
        }
        parameterTree?.implementorValueProvider = { [weak self] param in
            guard let self, param.address == 0 else { return 0 }
            return self.renderState.pointee.amount
        }
    }
}

// MARK: - CrossfeedUnit

/// Wraps `CrossfeedAudioUnit` in an `AVAudioUnitEffect` for use in an `AVAudioEngine` graph.
public final class CrossfeedUnit: @unchecked Sendable {
    // @unchecked: AVAudioUnitEffect lacks Sendable; safety provided by AudioEngine actor.

    let node: AVAudioUnitEffect

    public init() {
        CrossfeedAudioUnit.registerIfNeeded()
        self.node = AVAudioUnitEffect(
            audioComponentDescription: CrossfeedAudioUnit.componentDescription
        )
    }

    /// Crossfeed amount (0 = off, 1 = full Bauer crossfeed).
    public func setAmount(_ amount: Double) {
        let clamped = Float(max(0, min(1, amount)))
        self.node.auAudioUnit.parameterTree?.parameter(withAddress: 0)?.setValue(clamped, originator: nil)
        // Also write directly to ensure the render block reads the update immediately
        // (the observer may not fire synchronously on all OS versions).
        (self.node.auAudioUnit as? CrossfeedAudioUnit)?.renderState.pointee.amount = clamped
    }

    public var bypass: Bool {
        get { self.node.bypass }
        set { self.node.bypass = newValue }
    }
}
