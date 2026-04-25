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
/// **Real-time safety**: the render block captures only a `UnsafeMutablePointer<State>`
/// (a plain machine word).  No Swift-runtime metadata, no allocations, no locks.
/// Parameter changes are delivered via the `AURenderEventList` on the render thread.
///
/// **Thread safety**: `amount` is written by the parameter tree observer on the main
/// thread and read on the render thread.  Aligned 4-byte reads/writes are effectively
/// atomic on both ARM64 and x86-64; a torn read causes at most one buffer of wrong level.
final class CrossfeedAudioUnit: AUAudioUnit {
    // MARK: - Types

    /// All render-thread state in one allocation.
    struct State {
        var amount: Float = 0 // 0…1 crossfeed amount parameter
        var lpAlpha: Float = 0 // 1st-order LP coefficient (sample-rate dependent)
        var stateL: Float = 0 // IIR delay state for the L→R cross-talk path
        var stateR: Float = 0 // IIR delay state for the R→L cross-talk path
    }

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

    /// Pre-allocated render state captured by reference in the render block.
    /// Internal (not private) so CrossfeedUnit can write the amount directly for
    /// immediate responsiveness without waiting for the AUParameterTree observer.
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

    override func allocateRenderResources() throws {
        try super.allocateRenderResources()
        let sr = self.outputBusses[0].format.sampleRate
        // 1st-order IIR LP: y[n] = α·y[n-1] + (1-α)·x[n], α = e^(−2π·fc/fs)
        let fc = 700.0 // Bauer crossfeed LP cutoff (Hz)
        self.statePtr.pointee.lpAlpha = Float(exp(-2.0 * .pi * fc / sr))
        // Reset delay state on format change to avoid a pop.
        self.statePtr.pointee.stateL = 0
        self.statePtr.pointee.stateR = 0
    }

    override var internalRenderBlock: AUInternalRenderBlock {
        let st = self.statePtr // capture only the raw pointer
        return { _, timestamp, frameCount, _, outputData, eventList, pullInput in
            // --- Process parameter events delivered on the render thread ---
            var evt = eventList
            while let event = evt {
                if event.pointee.head.eventType == .parameter ||
                    event.pointee.head.eventType == .parameterRamp {
                    if event.pointee.parameter.parameterAddress == 0 {
                        st.pointee.amount = event.pointee.parameter.value
                    }
                }
                evt = UnsafePointer(event.pointee.head.next)
            }

            // --- Pull input audio ---
            guard let pull = pullInput else { return kAudioUnitErr_NoConnection }
            var flags: AudioUnitRenderActionFlags = []
            let status = pull(&flags, timestamp, frameCount, 0, outputData)
            guard status == noErr else { return status }

            let amount = st.pointee.amount
            guard amount > 1e-4 else { return noErr } // transparent when off

            // --- Apply crossfeed ---
            let abl = UnsafeMutableAudioBufferListPointer(outputData)
            guard abl.count >= 2,
                  let lPtr = abl[0].mData?.assumingMemoryBound(to: Float.self),
                  let rPtr = abl[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }

            let n = Int(frameCount)
            let alpha = st.pointee.lpAlpha
            var sL = st.pointee.stateL // LP state: L channel (feeds into R_out)
            var sR = st.pointee.stateR // LP state: R channel (feeds into L_out)
            // Cross-talk level ≈ −9.5 dB at amount = 1
            let level = amount * 0.333

            for i in 0 ..< n {
                let l = lPtr[i]
                let r = rPtr[i]
                // 1st-order IIR LP on each channel
                sL = alpha * sL + (1 - alpha) * l
                sR = alpha * sR + (1 - alpha) * r
                // Mix filtered cross-talk signal
                lPtr[i] = l + level * sR
                rPtr[i] = r + level * sL
            }

            st.pointee.stateL = sL
            st.pointee.stateR = sR
            return noErr
        }
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
            self.statePtr.pointee.amount = value
        }
        parameterTree?.implementorValueProvider = { [weak self] param in
            guard let self, param.address == 0 else { return 0 }
            return self.statePtr.pointee.amount
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
        (self.node.auAudioUnit as? CrossfeedAudioUnit)?.statePtr.pointee.amount = clamped
    }

    public var bypass: Bool {
        get { self.node.bypass }
        set { self.node.bypass = newValue }
    }
}
