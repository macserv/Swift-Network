//
//  NetworkOperation.swift
//  Radiant Tap Essentials
//
//  Copyright © 2017 Radiant Tap
//  MIT License · http://choosealicense.com/licenses/mit/
//

import Foundation

/// Subclass of [AsyncOperation](https://github.com/radianttap/Swift-Essentials/blob/master/Operation/AsyncOperation.swift)
///	that handles most aspects of direct data download over network.
///
///	In the simplest case, you can supply just `URLRequest` and a `Callback` which accepts `NetworkPayload` instance.
///	Or you can also supply custom `URLSessionConfiguration` just for this request (otherwise `.default` will be used).
///	Or `URLSession` instance if you have it somewhere else.
///
///	If you don't supply URLSession instance, it will internally create one and use it, just for this one request.
///	In this case, no delegate callback execute and thus Auth challenges are not handled. If you need that, make `NetworkSession` subclass.
///	Note: if you don‘t use the URLSession with delegate, you have no way to handle HTTP Authentication challenges.
///
///	If you are using `.background` URLSessionConfiguration, you **must** use URLSessionDelegate thus you must supply URLSession instance to the `init`.
final class NetworkOperation: AsyncOperation {
	typealias Callback = (NetworkPayload) -> Void

	required init() {
		fatalError("Use the `init(urlRequest:urlSessionConfiguration:callback:)`")
	}


	/// Designated initializer, allows to create one URLSession per Operation.
	///	URLSession.dataTask will use completionHandler form.
	///
	/// - Parameters:
	///   - urlRequest: `URLRequest` value to execute
	///   - urlSessionConfiguration: `URLSessionConfiguration` for this particular network call. Fallbacks to `default` if not specified
	///   - callback: A closure to pass the result back
	init(urlRequest: URLRequest,
		 urlSessionConfiguration: URLSessionConfiguration = URLSessionConfiguration.default,
		 callback: @escaping (NetworkPayload) -> Void)
	{
		self.payload = NetworkPayload(urlRequest: urlRequest)
		self.callback = callback
		self.urlSessionConfiguration = urlSessionConfiguration
		super.init()

		processHTTPMethod()
	}

	/// Designated initializer, it will execute the URLRequest using supplied URLSession instance.
	///	It‘s assumed that URLSessionDelegate is defined elsewhere (see NetworkSession.swift) and stuff will be called-in here (see `setupCallbacks()`).
	///
	/// - Parameters:
	///   - urlRequest: `URLRequest` value to execute
	///   - urlSession: URLSession instance to use for this Operation
	///   - callback: A closure to pass the result back
	init(urlRequest: URLRequest,
		 urlSession: URLSession,
		 callback: @escaping (NetworkPayload) -> Void)
	{
		self.payload = NetworkPayload(urlRequest: urlRequest)
		self.callback = callback
		self.urlSessionConfiguration = urlSession.configuration
		self.localURLSession = urlSession
		super.init()

		processHTTPMethod()
	}

	private(set) var payload: NetworkPayload
	private(set) var callback: Callback

	///	Configuration to use for the URLSession that will handle `urlRequest`
	private(set) var urlSessionConfiguration : URLSessionConfiguration

	///	URLSession that will be used for this particular request.
	///	If you don't supply it in the `init`, it will be created locally for this one request
	private var localURLSession: URLSession!
	private(set) var shouldCleanupURLSession = false

	///	Actual network task, generated by `localURLSession`
	private(set) var task: URLSessionDataTask?

	///	By default, Operation will not treat empty data in the response as error.
	///	This is normal with HEAD, PUT or DELETE methods, so this value will be changed
	///	based on the URLRequest.httpMethod value.
	///
	///	If you want to enforce a particular value, make sure to set it
	///	*after* you create the NetworkOperation instance but *before* you add to the OperationQueue.
	var allowEmptyData: Bool = true
	private var incomingData = Data()


	//	MARK: AsyncOperation

	/// Set network start timestamp, creates URLSessionDataTask and starts it (resume)
	override func workItem() {
		payload.start()

		if localURLSession == nil {
			//	Create local instance of URLSession, no delegate will be used
			localURLSession = URLSession(configuration: self.urlSessionConfiguration)
			//	we need to finish and clean-up tasks at the end
			shouldCleanupURLSession = true

			//	Create task, using `completionHandler` form
			task = localURLSession.dataTask(with: payload.urlRequest, completionHandler: {
				[weak self] data, response, error in
				guard let `self` = self else { return }

				self.payload.response = response as? HTTPURLResponse
				if let e = error {
					self.payload.error = .urlError(e as? URLError)

				} else {
					self.payload.data = data

					if let data = data {
						if data.isEmpty && !self.allowEmptyData {
							self.payload.error = .noData
						}
					} else {
						if !self.allowEmptyData {
							self.payload.error = .noData
						}
					}
				}

				self.finish()
			})
			//	start the task
			task?.resume()

			return
		}


		//	First create the task
		task = localURLSession.dataTask(with: payload.urlRequest)
		//	then setup handlers for URLSessionDelegate calls
		setupCallbacks()
		//	and start it
		task?.resume()
	}

	private func finish() {
		if shouldCleanupURLSession {
			//	this cancels immediatelly
//			localURLSession.invalidateAndCancel()
			//	this will allow background tasks to finish-up first
			localURLSession.finishTasksAndInvalidate()
		}

		payload.end()
		markFinished()

		callback(payload)
	}

	internal override func cancel() {
		super.cancel()

		task?.cancel()
		payload.error = .cancelled

		finish()
	}
}

//	MARK:- Internal

private extension NetworkOperation {

	func processHTTPMethod() {
		guard
			let method = payload.originalRequest.httpMethod,
			let m = NetworkHTTPMethod(rawValue: method)
		else { return }

		allowEmptyData = m.allowsEmptyResponseData
	}

	func setupCallbacks() {
		guard let task = task else { return }

		task.errorCallback = {
			[weak self] error in
			self?.payload.error = error
			self?.finish()
		}

		task.responseCallback = {
			[weak self] httpResponse in
			self?.payload.response = httpResponse
		}

		task.dataCallback = {
			[weak self] data in
			self?.incomingData.append(data)
		}

		task.finishCallback = {
			[weak self] in
			guard let `self` = self else { return }

			if self.incomingData.isEmpty && !self.allowEmptyData {
				self.payload.error = .noData
				self.finish()
				return
			}

			self.payload.data = self.incomingData
			self.finish()
		}
	}
}
