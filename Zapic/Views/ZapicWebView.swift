//
//  ZapicWebView.swift
//  Zapic
//
//  Created by Daniel Sarfati on 7/10/17.
//  Copyright © 2017 Zapic. All rights reserved.
//

import Foundation
import WebKit

protocol ZapicWebClient {
  var zapicDelegate: ZapicDelegate? { get set }
  func submitEvent(eventId: String, timestamp: Date, value: Int?)
  func dispatchToJS(type: WebFunction, payload:Any)
  func dispatchToJS(type: WebFunction, payload:Any, isError: Bool)

  /// Load the web client
  func load()

  /// Attempt to resend all events that we unable to send
  func resendFailedEvents()
}

enum WebEvent: String {
  case getSignature = "sdk/GET_VERIFICATION_SIGNATURE"
  case appReady = "sdk/APP_READY"
  case showBanner = "sdk/SHOW_BANNER"
  case pageReady = "sdk/PAGE_READY"
  case closePageRequest = "sdk/CLOSE_PAGE_REQUESTED"
}

enum WebFunction: String {
  case setSignature = "sdk/SET_VERIFICATION_SIGNATURE"
  case submitEvent = "sdk/SUBMIT_EVENT"
  case openPage = "sdk/OPEN_PAGE"
  case closePage = "sdk/CLOSE_PAGE"
}

struct Event {
  let type: WebFunction
  let payload: Any
  let isError: Bool

  init(type: WebFunction, payload: Any, isError: Bool) {
    self.type = type
    self.payload = payload
    self.isError = isError
  }
}

protocol ZapicDelegate : class {

  /// Triggers the generation of the
  /// Game Center verification signature
  func getVerificationSignature()

  /// Trigger when the web client is ready for
  /// the native client to call it
  func onAppReady()

  /// Trigger when the web client has an error
  func onAppError(error: Error)

  /// Trigger when a banner should be shown
  func showBanner(title: String, subTitle: String?, icon: UIImage?)
}

protocol ZapicViewControllerDelegate : class {
  func onPageReady()
  func onAppError(error: Error)
  func closePage()
}

enum WebClientStatus {
  case none
  case loading
  case ready
  case error
}

class ZapicWebView: WKWebView, WKScriptMessageHandler, UIScrollViewDelegate, ZapicWebClient {

  private let appUrl = "https://client.zapic.net"

  private let events: [String]

  private var eventQueue = Queue<Event>()

  private (set) var isPageReady = false

  private(set) var status = WebClientStatus.none

  weak var zapicDelegate: ZapicDelegate?

  weak var controllerDelegate: ZapicViewControllerDelegate?

  init() {

    let config = WKWebViewConfiguration()
    let controller = WKUserContentController()
    config.userContentController = controller

    events = ["dispatch"]

    super.init(frame: .zero, configuration: config)

    super.navigationDelegate = self
    super.scrollView.delegate = self

    for event in events {
      controller.add(self, name: event)
    }
  }

  // Disable zooming in webView
  func viewForZooming(scroll: UIScrollView) -> UIView? {
    return nil
  }

  required init?(coder aDecoder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func load() {

    if status == .ready {
      ZLog.debug("Web application is already ready")
      return
    }

    if status == .loading {
      ZLog.debug("Web application is already loading")
      return
    }

    ZLog.info("Loading Zapic web application")

    status = .loading

    guard let myURL = URL(string: appUrl) else {
      ZLog.error("Invalid URL for web application")
      return
    }

    super.load(URLRequest(url: myURL, timeoutInterval:30))
  }

  func onAppError(error: Error) {
    status = .error
    controllerDelegate?.onAppError(error:error)
    zapicDelegate?.onAppError(error: error)
  }

  /// Receive messages from JS code
  func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {

    guard let json = message.body as? [String: Any] else {
      ZLog.warn("Received invalid message format")
      return
    }

    guard let type = WebEvent(rawValue:(json["type"] as? String)!) else {
      ZLog.warn("Received unknown message type")
      return
    }

    ZLog.info("Received from JS: \(type) ")

    switch type {
    case .getSignature:
      zapicDelegate?.getVerificationSignature()
      break
    case .appReady:
      status = .ready
      zapicDelegate?.onAppReady()
      break
    case .pageReady:
      isPageReady = true
      controllerDelegate?.onPageReady()
      break
    case .showBanner:

      guard let msg = json["payload"] as? [String:Any] else {
        ZLog.warn("Received invalid ShowBanner payload")
        return
      }

      guard let title = msg["title"] as? String else {
        ZLog.warn("ShowBanner title is required")
        return
      }

      let icon: UIImage? = decode(base64:msg["icon"] as? String)

      let subTitle = msg["subtitle"] as? String

      zapicDelegate?.showBanner(title: title, subTitle: subTitle, icon: icon)

    case .closePageRequest:
      controllerDelegate?.closePage()
      break
    }
  }

  private func decode(base64: String?) -> UIImage? {

    guard let string = base64 else {
      return nil
    }

    if let dataDecoded = Data(base64Encoded: string, options: NSData.Base64DecodingOptions(rawValue: 0)) {
      return UIImage(data: dataDecoded)
    } else {
      ZLog.warn("Invalid base64 string")
      return nil
    }
  }

  // MARK: - Events

  func dispatchToJS(type: WebFunction, payload:Any) {
    dispatchToJS(type: type, payload: payload, isError: false)
  }

  func dispatchToJS(type: WebFunction, payload:Any, isError: Bool) {

    //Ensure setSignature is the only method that can be sent before
    //the app is ready
    if status != .ready && type != .setSignature {
      ZLog.info("Web client is not ready to run JS. Adding to queue")

      eventQueue.enqueue(Event(type: type, payload: payload, isError: isError))
      return
    }

    ZLog.info("Dispatching JS event \(type)")

    var msg = ["type": type.rawValue, "payload": payload]

    if isError {
      msg["error"]=true
    }

    guard let json = ZapicUtils.serialize(data: msg) else {
      return
    }

    let js = "zapic.dispatch(\(json))"

    //    ZLog.debug("Dispatching \(js)")

    super.evaluateJavaScript(js) { (result, error) in
      if let error = error {
        ZLog.error("JS Error \(error)")
      } else if let result = result {
        ZLog.debug("JS Result \(result)")
      }
    }
  }

  func submitEvent(eventId: String, timestamp: Date, value: Int? = nil) {

    if status != .ready {
      ZLog.info("Web client is not ready to accept events")
      return
    }

    ZLog.debug("Submitting event to web client")

    var msg: [String:Any] = ["eventId": eventId, "timestamp": timestamp.iso8601]

    if let v = value {
      msg["value"] = v
    }

    dispatchToJS(type:.submitEvent, payload: msg)
  }

  /// Attempt to resend all events that we unable to send
  func resendFailedEvents() {
    ZLog.debug("Started resending \(eventQueue.count) events")

    while eventQueue.count > 0 {

      guard let event = eventQueue.dequeue() else {
        ZLog.warn("Resending invalid event")
        break
      }

      dispatchToJS(type: event.type, payload: event.payload, isError: event.isError)
    }

    ZLog.debug("Finished resending events")

  }
}

extension ZapicWebView: WKNavigationDelegate {

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    ZLog.info("Finished loading webview content")
  }

  /// Handle errors loading web application
  func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
    ZLog.warn("Error loading Zapic webview")
    self.onAppError(error: error)
  }

}
