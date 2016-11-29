//
//  SambaPlayer.swift
//  SambaPlayer SDK
//
//  Created by Leandro Zanol, Priscila Magalhães, Thiago Miranda on 07/07/16.
//  Copyright © 2016 Sambatech. All rights reserved.
//

import Foundation
import UIKit

/// Responsible for managing media playback
public class SambaPlayer : UIViewController {
	
	private var _player: GMFPlayerViewController?
	private var _asset: AVURLAsset?
	private var _parentView: UIView?
	private var _currentMenu: UIViewController?
	private var _currentScreen: UIViewController?
	private var _delegates = [SambaPlayerDelegate]()
	private var _progressTimer = Timer()
	private var _hasStarted = false
	private var _stopping = false
	private var _fullscreenAnimating = false
	private var _isFullscreen = false
	private var _hasMultipleOutputs = false
	private var _pendingPlay = false
	private var _duration: Float = 0
	private var _currentOutput = -1
	private var _wasPlayingBeforePause = false
	private var _state = kGMFPlayerStateEmpty
	private var _thumb: UIButton?
	private var _decryptDelegate: AssetLoaderDelegate?
	private var _disabled = false
	
	// MARK: Properties
	
	/// Stores the delegated methods for the player events
	public var delegate: SambaPlayerDelegate = FakeListener() {
		didSet {
			_delegates.append(delegate)
		}
	}
	
	/// Current media time
	public var currentTime: Float {
		return Float(_player?.currentMediaTime() ?? 0)
	}
	
	/// Current media duration
	public var duration: Float {
		if _duration == 0,
			let d = _player?.totalMediaTime(), d > 0 {
			_duration = Float(d)
		}
		
		return _duration
	}
	
	/// Current media
	public var media: SambaMedia = SambaMedia() {
		didSet {
			if let m = media as? SambaMediaConfig,
				m.blockIfRooted && GMFHelpers.isDeviceJailbroken() {
				dispatchError(SambaPlayerError.rootedDevice)
				return
			}
			
			if let index = media.outputs?.index(where: { $0.isDefault }) {
				_currentOutput = index
			}
			
			DispatchQueue.main.async {
				if self.media.isAudio {
					self.create(false)
				}
				else {
					self.createThumb()
				}
			}
		}
	}
	
	/// Flag if the media is playing or not
	public var isPlaying: Bool {
		return _state == kGMFPlayerStatePlaying || _state == kGMFPlayerStateBuffering
	}
	
	/// Flag whether controls should be visible or not
	public var controlsVisible: Bool = true {
		didSet {
			(_player?.playerOverlayView() as? GMFPlayerOverlayView)?.visible = controlsVisible
		}
	}
	
	// MARK: Public Methods
	/**
	Default initializer
	*/
	public init() {
		super.init(nibName: nil, bundle: nil)
	}
	
	/**
	Convenience initializer
	
	- parameter parentViewController: The view-controller in which the player view-controller and view should be embedded
	*/
	public convenience init(parentViewController: UIViewController) {
		self.init(parentViewController: parentViewController, andParentView: parentViewController.view)
	}
	
	/**
	Convenience initializer
	
	- parameter parentViewController: The view-controller in which the player view-controller should be embedded
	- parameter parentView: The view in which the player view should be embedded
	*/
	public convenience init(parentViewController: UIViewController, andParentView parentView: UIView) {
		self.init()
		
		DispatchQueue.main.async {
			parentViewController.addChildViewController(self)
			self.didMove(toParentViewController: parentViewController)
			self.view.frame = parentView.bounds
			parentView.addSubview(self.view)
			parentView.setNeedsDisplay()
		}
		
		self._parentView = parentView
	}
	
	/**
	Required initializer
	
	- parameter aDecoder: (NSCoder)
	*/
	public required init?(coder aDecoder: NSCoder) {
	    fatalError("init(coder:) has not been implemented")
	}
	
	/**
	Plays the media
		
		player.play()
	*/
	public func play() {
		if _disabled { return }
		
		guard let player = _player else {
			DispatchQueue.main.async { self.create() }
			return
		}
		
		player.play()
	}
	
	/**
	Pauses the media
	
		player.pause()
	*/
	public func pause() {
		_wasPlayingBeforePause = isPlaying
		_player?.pause()
	}
	
	/**
	Stops the media returning it to its initial time
	
		player.stop()
	*/
	public func stop() {
		// avoid dispatching events
		_stopping = true
		
		pause()
		seek(0)
	}
	
	/**
	Moves the media to a given time
	
	- parameter pos: Time in seconds
			
		player.seek(20)
	*/
    public func seek(_ pos: Float) {
		// do not seek on live
		guard !media.isLive else { return }
		
		_player?.player.seek(toTime: TimeInterval(pos))
    }
	
	/**
	Changes the current output
	
	- parameter value: Index of the output
	
		player.switchOutput(1)
	*/
	public func switchOutput(_ value: Int) {
		guard value != _currentOutput,
			let outputs = media.outputs,
			value < outputs.count else { return }
		
		_currentOutput = value
		
		guard let url = URL(string: outputs[value].url) else {
			dispatchError(SambaPlayerError.invalidUrl)
			return
		}
		
		let asset = AVURLAsset(url: url)
		
		if let m = media as? SambaMediaConfig,
			let drmRequest = m.drmRequest {
			_decryptDelegate = AssetLoaderDelegate(asset: asset, assetName: "MrPoppersPenguins", drmRequest: drmRequest)
		}
		
		_player?.player.switch(asset)
	}
	
	/**
	Destroys the player instance
	
	- parameter error: Error type to show (optional)
	
		player.destroy()
	*/
	public func destroy(withError error: SambaPlayerError? = nil) {
		if let error = error { showError(error) }
		else { destroyScreen() }
		
		guard let player = _player else { return }
		
		for delegate in _delegates { delegate.onDestroy() }
		
		stopTimer()
		player.player.reset()
		detachVC(player)
		NotificationCenter.default.removeObserver(self)
		
		_player = nil
	}
	
	// MARK: Overrides
	
	public override var supportedInterfaceOrientations : UIInterfaceOrientationMask {
		return .allButUpsideDown
	}
	
	public override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
		super.viewWillTransition(to: size, with: coordinator)
		
		guard !_fullscreenAnimating,
			let player = _player else { return }
		
		guard !media.isAudio else {
			var f = player.view.frame
			f.size.width = size.width
			player.view.frame = f
			player.view.setNeedsDisplay()
			return
		}
		
		if let menu = _currentMenu {
			hideMenu(menu, true)
		}
		
		let callback = {
			self._fullscreenAnimating = false
			
			if let menu = self._currentMenu {
				self.showMenu(menu, true)
			}
		}
		
		if player.parent == self {
			if UIDeviceOrientationIsLandscape(UIDevice.current.orientation) {
				_fullscreenAnimating = true
				_isFullscreen = true
				
				player.getControlsView().setMinimizeButtonImage(GMFResources.playerBarMaximizeButtonImage())
				detachVC(player)
				
				DispatchQueue.main.async {
					self.present(player, animated: true, completion: callback)
				}
			}
		}
		else if UIDeviceOrientationIsPortrait(UIDevice.current.orientation) {
			_fullscreenAnimating = true
			
			detachVC(player) {
				self._isFullscreen = false
				
				player.getControlsView().setMinimizeButtonImage(GMFResources.playerBarMinimizeButtonImage())
				self.attachVC(player)
				callback()
			}
		}
	}
	
	public override func viewWillDisappear(_ animated: Bool) {
		super.viewWillDisappear(animated)
		
		guard !_fullscreenAnimating else { return }
		
		destroy()
	}
	
	// MARK: Internal Methods (may we publish them?)
	
	func showMenu(_ menu: UIViewController, _ mainActionOnly: Bool = false) {
		guard _hasStarted else { return }
		
		_currentMenu = menu
		
		if !mainActionOnly {
			pause()
		}
		
		if _isFullscreen {
			attachVC(menu, _player)
		}
		else {
			DispatchQueue.main.async {
				self.present(menu, animated: false, completion: nil)
			}
		}
	}
	
	func hideMenu(_ menu: UIViewController, _ mainActionOnly: Bool = false) {
		detachVC(menu, _player, false)
		
		_currentMenu = nil
		
		if !mainActionOnly && _wasPlayingBeforePause {
			play()
		}
	}
	
	// MARK: Private Methods
	
	private func create(_ autoPlay: Bool = true) {
		if let player = _player {
			if autoPlay { player.play() }
			return
		}
		
		_pendingPlay = false
		
		var urlOpt = media.url
		
		if let outputs = media.outputs, outputs.count > 0 {
			urlOpt = outputs[0].url
			
			for output in outputs where output.isDefault {
				urlOpt = output.url
			}
			
			_hasMultipleOutputs = outputs.count > 1
		}
		
		guard let urlString = urlOpt,
			let url = URL(string: urlString) else {
			dispatchError(SambaPlayerError.invalidUrl)
			return
		}
		
		let asset = AVURLAsset(url: url)
		
		_asset = asset
		
		if let m = media as? SambaMediaConfig,
			let drmRequest = m.drmRequest {
			// weak reference delegate, must retain a reference to it
			_decryptDelegate = AssetLoaderDelegate(asset: asset, assetName: m.id, drmRequest: drmRequest)
		}
		
		guard let gmf = (GMFPlayerViewController(controlsPadding: CGRect(x: 0, y: 0, width: 0, height: media.isAudio ? 10 : 0)) {
			guard let player = self._player else { return }
			
			if self._hasMultipleOutputs {
				player.getControlsView().showHdButton()
			}
			
			if self.media.isAudio {
				player.hideBackground()
				player.getControlsView().hideFullscreenButton()
				player.getControlsView().showPlayButton()
				(player.playerOverlayView() as! GMFPlayerOverlayView).controlsOnly = true
				player.playerOverlay().autoHideEnabled = false
				player.playerOverlay().controlsHideEnabled = false
				
				if !self.media.isLive {
					(player.playerOverlayView() as! GMFPlayerOverlayView).hideBackground()
					(player.playerOverlayView() as! GMFPlayerOverlayView).disableTopBar()
				}
			}
			
			if self.media.isLive {
				player.getControlsView().hideScrubber()
				player.getControlsView().hideTotalTime()
				player.addActionButton(with: GMFResources.playerTitleLiveIcon(), name:"Live", target:player, selector:nil)
				(player.playerOverlayView() as! GMFPlayerOverlayView).hideBackground()
				(player.playerOverlayView() as! GMFPlayerOverlayView).topBarHideEnabled = false
			}
			
			if !self.controlsVisible {
				self.controlsVisible = false
			}
		}) else {
			dispatchError(SambaPlayerError.creatingPlayer)
			return
		}
	
		_player = gmf
		
		gmf.videoTitle = media.title
		gmf.controlTintColor = UIColor(media.theme)
		
		if media.isAudio {
			gmf.backgroundColor = UIColor(0x434343)
		}
		
		destroyThumb()
		attachVC(gmf)
		
		let nc = NotificationCenter.default
		
		nc.addObserver(self, selector: #selector(playbackStateHandler),
		               name: NSNotification.Name.gmfPlayerPlaybackStateDidChange, object: gmf)
		
		nc.addObserver(self, selector: #selector(fullscreenTouchHandler),
		               name: NSNotification.Name.gmfPlayerDidMinimize, object: gmf)
		
		nc.addObserver(self, selector: #selector(hdTouchHandler),
		               name: NSNotification.Name.gmfPlayerDidPressHd, object: gmf)
		
		// Tracking
		
		if !media.isLive && !media.isAudio {
			let _ = Tracking(self)
		}
		
		// IMA
		if !media.isAudio, let adUrl = media.adUrl {
			let mediaId = (media as? SambaMediaConfig)?.id ?? ""
			gmf.loadStream(with: asset, imaTag: "\(adUrl)&vid=[\(mediaId.isEmpty ? "live" : mediaId)]")
		}
		// default
		else {
			_pendingPlay = autoPlay
			gmf.loadStream(with: asset)
		}
	}
	
	private func createThumb() {
		guard let thumbImage = media.thumb else {
			#if DEBUG
			print("\(type(of: self)): no thumb found.")
			#endif
			return
		}
		
		let thumb = UIButton(frame: view.frame)
		let size = CGSize(width: view.frame.width, height: view.frame.height)
		let play = GMFResources.playerBarPlayLargeButtonImage()
		
		UIGraphicsBeginImageContextWithOptions(size, true, 0)
		thumbImage.draw(in: CGRect(x: 0, y: 0, width: size.width, height: size.height))
		play?.draw(in: CGRect(x: (size.width - (play?.size.width)!)/2, y: (size.height - (play?.size.height)!)/2, width: (play?.size.width)!, height: (play?.size.height)!))
		thumb.setImage(UIGraphicsGetImageFromCurrentImageContext(), for: UIControlState())
		UIGraphicsEndImageContext()
		
		thumb.addTarget(self, action: #selector(thumbTouchHandler), for: .touchUpInside)
		
		_thumb = thumb
		
		view.addSubview(thumb)
		view.setNeedsLayout()
	}
	
	private func destroyThumb() {
		guard let thumb = _thumb else { return }
		
		thumb.removeTarget(self, action: #selector(thumbTouchHandler), for: .touchUpInside)
		thumb.removeFromSuperview()
		_thumb = nil
	}
	
	private func dispatchError(_ error: SambaPlayerError) {
		#if DEBUG
		print(error.localizedDescription)
		#endif
		
		_disabled = true
		
		DispatchQueue.main.async {
			for delegate in self._delegates { delegate.onError(error) }
			self.destroy(withError: error)
		}
	}
	
	private func showError(_ error: SambaPlayerError) {
		let screen = ErrorScreenViewController(error)
		
		attachVC(screen)
		
		_disabled = true
		_currentScreen = screen
	}
	
	private func destroyScreen() {
		_disabled = false
		
		guard let screen = _currentScreen else { return }
		
		detachVC(screen)
	}
	
	// MARK: Handlers
	
	@objc private func thumbTouchHandler() {
		play()
	}
	
	@objc private func playbackStateHandler() {
		guard let player = _player else { return }
		
		let lastState = _state
		
		_state = player.playbackState()
		
		#if DEBUG
		print("state: \(lastState) => \(_state)")
		#endif
		
		switch _state {
		case kGMFPlayerStateReadyToPlay:
			for delegate in _delegates { delegate.onLoad() }
			
			if _pendingPlay {
				play()
				_pendingPlay = false
			}
			
		case kGMFPlayerStatePlaying:
			if !_hasStarted {
				_hasStarted = true
				for delegate in _delegates { delegate.onStart() }
			}
			
			if !player.isUserScrubbing && lastState != kGMFPlayerStateSeeking {
				for delegate in _delegates { delegate.onResume() }
			}
			
			startTimer()
			
		case kGMFPlayerStatePaused:
			stopTimer()
			
			if _stopping { _stopping = false }
			else if lastState != kGMFPlayerStateSeeking {
				if !player.isUserScrubbing {
					for delegate in _delegates { delegate.onPause() }
				}
			}
			// when paused seek dispatch extra progress event to update external infos
			else { progressEventHandler() }
		
		case kGMFPlayerStateFinished:
			stopTimer()
			for delegate in _delegates { delegate.onFinish() }
		
		case kGMFPlayerStateError:
			if player.player != nil && player.player.error != nil {
				dispatchError(SambaPlayerError.unknown.setMessage(player.player.error.localizedDescription))
			}
			
		default: break
		}
	}
	
	@objc private func progressEventHandler() {
		for delegate in _delegates { delegate.onProgress() }
	}
	
	@objc private func fullscreenTouchHandler() {
		UIDevice.current.setValue(_isFullscreen ? UIInterfaceOrientation.portrait.rawValue :
			UIInterfaceOrientation.landscapeLeft.rawValue, forKey: "orientation")
	}
	
	@objc private func hdTouchHandler() {
		showMenu(OutputMenuViewController(self, _currentOutput))
	}
	
	private func attachVC(_ vc: UIViewController, _ vcParent: UIViewController? = nil) {
		let p: UIViewController = vcParent ?? self
		
		DispatchQueue.main.async {
			p.addChildViewController(vc)
			vc.didMove(toParentViewController: p)
			vc.view.frame = p.view.frame
			p.view.addSubview(vc.view)
			p.view.setNeedsDisplay()
		}
	}
	
	private func detachVC(_ vc: UIViewController, _ vcParent: UIViewController? = nil, _ animated: Bool = true, callback: (() -> Void)? = nil) {
		DispatchQueue.main.async {
			if vc.parent != (vcParent ?? self) {
				vc.dismiss(animated: animated, completion: callback)
			}
			else {
				vc.view.removeFromSuperview()
				vc.removeFromParentViewController()
				callback?()
			}
		}
	}
	
	private func startTimer() {
		stopTimer()
		_progressTimer = Timer.scheduledTimer(timeInterval: 0.25, target: self, selector: #selector(progressEventHandler), userInfo: nil, repeats: true)
	}
	
	private func stopTimer() {
		_progressTimer.invalidate()
	}
	
	private class FakeListener : NSObject, SambaPlayerDelegate {
		func onLoad() {}
		func onStart() {}
		func onResume() {}
		func onPause() {}
		func onProgress() {}
		func onFinish() {}
		func onDestroy() {}
		func onError(_ error: SambaPlayerError) {error.setMessage("")}
	}
}

/**
Player error list
*/
@objc public class SambaPlayerError : NSObject, Error {
	public static let invalidUrl = SambaPlayerError(0, "Invalid URL format")
	public static let creatingPlayer = SambaPlayerError(1, "Error creating player")
	public static let rootedDevice = SambaPlayerError(2, "Specified media cannot play on a rooted device")
	public static let unknown = SambaPlayerError(3, "Unknown error")
	
	public let code: Int
	
	private let _message: String
	private var _messageAlt: String?
	
	private init(_ code: Int, _ message: String) {
		self.code = code
		_message = message
	}

	/**
	Customizes an error message associated to a given error type.
	
	- parameter error: Instance error type
	- parameter message: The message to be replaced
	*/
	public static func setMessage(error: SambaPlayerError, message: String) {
		error.setMessage(message)
	}
	
	/**
	Customizes the current error message and returns it.
	
	- parameter message: The message to be replaced
	- returns: The current error
	*/
	public func setMessage(_ message: String) -> SambaPlayerError {
		_messageAlt = message
		return self
	}
	
	public var localizedDescription: String {
		return _messageAlt ?? _message
	}
}

/**
Listens to player events
*/
@objc public protocol SambaPlayerDelegate {
	/// Fired up when player is loaded
	func onLoad()
	
	/// Fired up when player is started
	func onStart()
	
	/// Fired up when player is resumed ( from paused to play )
	func onResume()
	
	/// Fired up when player is paused
	func onPause()
	
	/// Fired up when player is playing ( fired each second of playing )
	func onProgress()
	
	/// Fired up when player is finished
	func onFinish()
	
	/// Fired up when player is destroyed
	func onDestroy()
	
	/// Fired up when some error occurs
	func onError(_ error: SambaPlayerError)
}
