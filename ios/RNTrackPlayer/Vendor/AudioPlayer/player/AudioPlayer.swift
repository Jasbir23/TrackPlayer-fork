//
//  AudioPlayer.swift
//  AudioPlayer
//
//  Created by Kevin DELANNOY on 26/04/15.
//  Copyright (c) 2015 Kevin Delannoy. All rights reserved.
//

import AVFoundation
#if os(iOS) || os(tvOS)
    import MediaPlayer
#endif

/// An `AudioPlayer` instance is used to play `AudioPlayerItem`. It's an easy to use AVPlayer with simple methods to
/// handle the whole playing audio process.
///
/// You can get events (such as state change or time observation) by registering a delegate.
public class AudioPlayer: NSObject {
    // MARK: Handlers

    /// The background handler.
    let backgroundHandler = BackgroundHandler()

    /// Reachability for network connection.
    let reachability = Reachability()

    // MARK: Event producers

    /// The network event producer.
    lazy var networkEventProducer: NetworkEventProducer = {
        NetworkEventProducer(reachability: self.reachability)
    }()

    /// The player event producer.
    let playerEventProducer = PlayerEventProducer()

    /// The seek event producer.
    let seekEventProducer = SeekEventProducer()

    /// The quality adjustment event producer.
    var qualityAdjustmentEventProducer = QualityAdjustmentEventProducer()

    /// The audio item event producer.
    var trackEventProducer = TrackEventProducer()

    /// The retry event producer.
    var retryEventProducer = RetryEventProducer()

    // MARK: Player

    /// The audio player.
    var player: AVPlayer? {
        didSet {
            if #available(OSX 10.11, *) {
                player?.allowsExternalPlayback = false
            }
            player?.volume = volume
            player?.rate = rate
            updatePlayerForBufferingStrategy()

            if let player = player {
                playerEventProducer.player = player
                trackEventProducer.item = currentItem
                playerEventProducer.startProducingEvents()
                networkEventProducer.startProducingEvents()
                trackEventProducer.startProducingEvents()
                qualityAdjustmentEventProducer.startProducingEvents()
            } else {
                playerEventProducer.player = nil
                trackEventProducer.item = nil
                playerEventProducer.stopProducingEvents()
                networkEventProducer.stopProducingEvents()
                trackEventProducer.stopProducingEvents()
                qualityAdjustmentEventProducer.stopProducingEvents()
            }
        }
    }

    /// The current item being played.
    internal(set) var currentItem: Track? {
        didSet {
            if let currentItem = currentItem {
                // Save previous item's progression
                let oldProgression = currentItemProgression

                // Stops the current player
                player?.rate = 0
                player = nil

                // Ensures the audio session got started
                setAudioSession(active: true, earPiece: false)

                // Sets new state
                if reachability.isReachable() || currentItem.url.isLocal {
                    state = .buffering
                    backgroundHandler.beginBackgroundTask()
                } else {
                    stateWhenConnectionLost = .buffering
                    state = .waitingForConnection
                    backgroundHandler.beginBackgroundTask()
                    return
                }

                // Reset special state flags
                pausedForInterruption = false

                // Create new AVPlayerItem
                let playerItem = AVPlayerItem(url: currentItem.url.value)

                if #available(iOS 10.0, tvOS 10.0, OSX 10.12, *) {
                    playerItem.preferredForwardBufferDuration = self.preferredForwardBufferDuration
                }

                // Creates new player
                player = AVPlayer(playerItem: playerItem)

                // Updates information on the lock screen
                updateNowPlayingInfoCenter()

                // Calls delegate
                if oldValue != currentItem {
                    delegate?.audioPlayer(self, willChangeTrackFrom: oldValue, at: oldProgression, to: currentItem)
                }
                player?.rate = rate
            } else {
                pause()
            }
        }
    }

    // MARK: Public properties

    /// The delegate that will be called upon events.
    weak var delegate: AudioPlayerDelegate?

    /// Defines the maximum to wait after a connection loss before putting the player to Stopped mode and cancelling
    /// the resume. Default value is 60 seconds.
    var maximumConnectionLossTime = TimeInterval(60)

    /// Defines whether the player should automatically adjust sound quality based on the number of interruption before
    /// a delay and the maximum number of interruption whithin this delay. Default value is `true`.
    var adjustQualityAutomatically = true

    /// Defines the delay within which the player wait for an interruption before upgrading the quality. Default value
    /// is 10 minutes.
    var adjustQualityTimeInternal: TimeInterval {
        get {
            return qualityAdjustmentEventProducer.adjustQualityTimeInternal
        }
        set {
            qualityAdjustmentEventProducer.adjustQualityTimeInternal = newValue
        }
    }

    /// Defines the maximum number of interruption to have within the `adjustQualityTimeInterval` delay before
    /// downgrading the quality. Default value is 5.
    var adjustQualityAfterInterruptionCount: Int {
        get {
            return qualityAdjustmentEventProducer.adjustQualityAfterInterruptionCount
        }
        set {
            qualityAdjustmentEventProducer.adjustQualityAfterInterruptionCount = newValue
        }
    }

    /// The maximum number of interruption before putting the player to Stopped mode. Default value is 10.
    var maximumRetryCount: Int {
        get {
            return retryEventProducer.maximumRetryCount
        }
        set {
            retryEventProducer.maximumRetryCount = newValue
        }
    }

    /// The delay to wait before cancelling last retry and retrying. Default value is 10 seconds.
    var retryTimeout: TimeInterval {
        get {
            return retryEventProducer.retryTimeout
        }
        set {
            retryEventProducer.retryTimeout = newValue
        }
    }

    /// Defines whether the player should resume after a system interruption or not. Default value is `true`.
    var resumeAfterInterruption = true

    /// Defines whether the player should resume after a connection loss or not. Default value is `true`.
    var resumeAfterConnectionLoss = true

    /// Defines the volume of the player. `1.0` means 100% and `0.0` is 0%.
    var volume = Float(1) {
        didSet {
            player?.volume = volume
        }
    }

    /// Defines the rate of the player. Default value is 1.
    var rate = Float(1) {
        didSet {
            if case .playing = state {
                player?.rate = rate
                updateNowPlayingInfoCenter()
            }
        }
    }

    /// Defines the buffering strategy used to determine how much to buffer before starting playback
    var bufferingStrategy: AudioPlayerBufferingStrategy = .defaultBuffering {
        didSet {
            updatePlayerForBufferingStrategy()
        }
    }

    /// Defines the preferred buffer duration in seconds before playback begins. Defaults to 60.
    /// Works on iOS/tvOS 10+ when `bufferingStrategy` is `.playWhenPreferredBufferDurationFull`.
    var preferredBufferDurationBeforePlayback = TimeInterval(60)

    /// Defines the preferred size of the forward buffer for the underlying `AVPlayerItem`.
    /// Works on iOS/tvOS 10+, default is 0, which lets `AVPlayer` decide.
    var preferredForwardBufferDuration = TimeInterval(0)

    /// Defines how to behave when the user is seeking through the lockscreen or the control center.
    ///
    /// - multiplyRate: Multiples the rate by a factor.
    /// - changeTime:   Changes the current position by adding/substracting a time interval.
    enum SeekingBehavior {
        case multiplyRate(Float)
        case changeTime(every: TimeInterval, delta: TimeInterval)

        func handleSeekingStart(player: AudioPlayer, forward: Bool) {
            switch self {
            case .multiplyRate(let rateMultiplier):
                if forward {
                    player.rate = player.rate * rateMultiplier
                } else {
                    player.rate = -(player.rate * rateMultiplier)
                }

            case .changeTime:
                player.seekEventProducer.isBackward = !forward
                player.seekEventProducer.startProducingEvents()
            }
        }

        func handleSeekingEnd(player: AudioPlayer, forward: Bool) {
            switch self {
            case .multiplyRate(let rateMultiplier):
                if forward {
                    player.rate = player.rate / rateMultiplier
                } else {
                    player.rate = -(player.rate / rateMultiplier)
                }

            case .changeTime:
                player.seekEventProducer.stopProducingEvents()
            }
        }
    }

    /// Defines the rate behavior of the player when the backward/forward buttons are pressed. Default value
    /// is `multiplyRate(2)`.
    var seekingBehavior = SeekingBehavior.multiplyRate(2) {
        didSet {
            if case .changeTime(let timerInterval, _) = seekingBehavior {
                seekEventProducer.intervalBetweenEvents = timerInterval
            }
        }
    }

    // MARK: Public Methods

    func play(track: Track) {
        currentItem = track
    }

    // MARK: Readonly properties

    /// The current state of the player.
    internal(set) var state = AudioPlayerState.stopped {
        didSet {
            updateNowPlayingInfoCenter()

            if state != oldValue {
                if case .buffering = state {
                    backgroundHandler.beginBackgroundTask()
                } else if case .buffering = oldValue {
                    backgroundHandler.endBackgroundTask()
                }

                delegate?.audioPlayer(self, didChangeStateFrom: oldValue, to: state)
            }
        }
    }

    // MARK: Private properties

    /// A boolean value indicating whether the player has been paused because of a system interruption.
    var pausedForInterruption = false

    /// A boolean value indicating if quality is being changed. It's necessary for the interruption count to not be
    /// incremented while new quality is buffering.
    var qualityIsBeingChanged = false

    /// The state before the player went into .Buffering. It helps to know whether to restart or not the player.
    var stateBeforeBuffering: AudioPlayerState?

    /// The state of the player when the connection was lost
    var stateWhenConnectionLost: AudioPlayerState?

    // MARK: Initialization

    /// Initializes a new AudioPlayer.
    override init() {
        super.init()

        playerEventProducer.eventListener = self
        networkEventProducer.eventListener = self
        trackEventProducer.eventListener = self
        qualityAdjustmentEventProducer.eventListener = self
    }

    /// Deinitializes the AudioPlayer. On deinit, the player will simply stop playing anything it was previously
    /// playing.
    deinit {
        stop()
    }

    // MARK: Utility methods

    /// Updates the MPNowPlayingInfoCenter with current item's info.
    func updateNowPlayingInfoCenter() {
        #if os(iOS) || os(tvOS)
            if let item = currentItem {
                MPNowPlayingInfoCenter.default().ap_update(
                    with: item,
                    duration: currentItemDuration,
                    progression: currentItemProgression,
                    playbackRate: player?.rate ?? 0)
            } else {
                MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            }
        #endif
    }

    /// Enables or disables the `AVAudioSession` and sets the right category.
    ///
    /// - Parameter active: A boolean value indicating whether the audio session should be set to active or not.
    func setAudioSession(active: Bool, earPiece: Bool) {
        #if os(iOS) || os(tvOS)
            if earPiece {
                _ = try? AVAudioSession.sharedInstance().setCategory(AVAudioSessionCategoryPlayAndRecord)
                _ = try? AVAudioSession.sharedInstance().setMode(AVAudioSessionModeVoiceChat)
                _ = try? AVAudioSession.sharedInstance().setActive(active)
            } else {
                _ = try? AVAudioSession.sharedInstance().setCategory(AVAudioSessionCategoryPlayback)
                _ = try? AVAudioSession.sharedInstance().setActive(active)
            }
        #endif
    }

    // MARK: Public computed properties

    /// Boolean value indicating whether the player should resume playing (after buffering)
    var shouldResumePlaying: Bool {
        return !state.isPaused &&
            (stateWhenConnectionLost.map { !$0.isPaused } ?? true) &&
            (stateBeforeBuffering.map { !$0.isPaused } ?? true)
    }

    // MARK: Retrying

    /// This will retry to play current item and seek back at the correct position if possible (or enabled). If not,
    /// it'll just play the next item in queue.
    func retryOrPlayNext() {
        guard !state.isPlaying else {
            retryEventProducer.stopProducingEvents()
            return
        }

        let cip = currentItemProgression
        let ci = currentItem
        currentItem = ci
        if let cip = cip {
            //We can't call self.seek(to:) in here since the player is new
            //and `cip` is probably not in the seekableTimeRanges.
            player?.seek(to: CMTime(timeInterval: cip))
        }
    }

    /// Updates the current player based on the current buffering strategy.
    /// Only has an effect on iOS 10+, tvOS 10+ and macOS 10.12+
    func updatePlayerForBufferingStrategy() {
        if #available(iOS 10.0, tvOS 10.0, OSX 10.12, *) {
            player?.automaticallyWaitsToMinimizeStalling = self.bufferingStrategy != .playWhenBufferNotEmpty
        }
    }

    /// Updates a given player item based on the `preferredForwardBufferDuration` set.
    /// Only has an effect on iOS 10+, tvOS 10+ and macOS 10.12+
    func updatePlayerItemForBufferingStrategy(_ playerItem: AVPlayerItem) {
        //Nothing strategy-specific yet
        if #available(iOS 10.0, tvOS 10.0, OSX 10.12, *) {
            playerItem.preferredForwardBufferDuration = self.preferredForwardBufferDuration
        }
    }
}

extension AudioPlayer: EventListener {
    /// The implementation of `EventListener`. It handles network events, player events, audio item events, quality
    /// adjustment events, retry events and seek events.
    ///
    /// - Parameters:
    ///   - event: The event.
    ///   - eventProducer: The producer of the event.
    func onEvent(_ event: Event, generetedBy eventProducer: EventProducer) {
        if let event = event as? NetworkEventProducer.NetworkEvent {
            handleNetworkEvent(from: eventProducer, with: event)
        } else if let event = event as? PlayerEventProducer.PlayerEvent {
            handlePlayerEvent(from: eventProducer, with: event)
        } else if let event = event as? TrackEventProducer.TrackEvent {
            handleTrackEvent(from: eventProducer, with: event)
        } else if let event = event as? RetryEventProducer.RetryEvent {
            handleRetryEvent(from: eventProducer, with: event)
        } else if let event = event as? SeekEventProducer.SeekEvent {
            handleSeekEvent(from: eventProducer, with: event)
        }
    }
}
