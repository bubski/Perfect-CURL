//
//  cURL.swift
//  PerfectLib
//
//  Created by Kyle Jessup on 2015-08-10.
//	Copyright (C) 2015 PerfectlySoft, Inc.
//
//===----------------------------------------------------------------------===//
//
// This source file is part of the Perfect.org open source project
//
// Copyright (c) 2015 - 2016 PerfectlySoft Inc. and the Perfect project authors
// Licensed under Apache License v2.0
//
// See http://perfect.org/licensing.html for license information
//
//===----------------------------------------------------------------------===//
//

import cURL
import PerfectThread
import PerfectNet

/// This class is a wrapper around the CURL library. It permits network operations to be completed using cURL in a block or non-blocking manner.
public class CURL {

	static var sInit:Int = {
		curl_global_init(Int(CURL_GLOBAL_SSL | CURL_GLOBAL_WIN32))
		return 1
	}()

	var curl: UnsafeMutableRawPointer?
	var multi: UnsafeMutableRawPointer?

	var slists = UnsafeMutablePointer<curl_slist>(nil as OpaquePointer?)

	var headerBytes = [UInt8]()
	var bodyBytes = [UInt8]()

	/// The CURLINFO_RESPONSE_CODE for the last operation.
	public var responseCode: Int {
		return self.getInfo(CURLINFO_RESPONSE_CODE).0
	}

	/// Get or set the current URL.
	public var url: String {
		get {
			return self.getInfo(CURLINFO_EFFECTIVE_URL).0
		}
		set {
			let _ = self.setOption(CURLOPT_URL, s: newValue)
		}
	}

	/// Initialize the CURL request.
	public init() {
		self.curl = curl_easy_init()
		setCurlOpts()
	}

	/// Initialize the CURL request with a given URL.
	public convenience init(url: String) {
		self.init()
		self.url = url
	}

	/// Duplicate the given request into a new CURL object.
	public init(dupeCurl: CURL) {
		if let copyFrom = dupeCurl.curl {
			self.curl = curl_easy_duphandle(copyFrom)
		} else {
			self.curl = curl_easy_init()
		}
		setCurlOpts() // still set options
	}

	func setCurlOpts() {
        guard let curl = self.curl else {
            return
        }
		curl_easy_setopt_long(curl, CURLOPT_NOSIGNAL, 1)
        let opaqueMe = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
		let _ = setOption(CURLOPT_HEADERDATA, v: opaqueMe)
		let _ = setOption(CURLOPT_WRITEDATA, v: opaqueMe)
		let _ = setOption(CURLOPT_READDATA, v: opaqueMe)

		let headerReadFunc: curl_func = {
			(a, size, num, p) -> Int in

            let crl = Unmanaged<CURL>.fromOpaque(p!).takeUnretainedValue()
			if let bytes = a?.assumingMemoryBound(to: UInt8.self) {
				let fullCount = size*num
				for idx in 0..<fullCount {
					crl.headerBytes.append(bytes[idx])
				}
				return fullCount
			}
			return 0
		}
		let _ = setOption(CURLOPT_HEADERFUNCTION, f: headerReadFunc)

		let writeFunc: curl_func = {
			(a, size, num, p) -> Int in

            let crl = Unmanaged<CURL>.fromOpaque(p!).takeUnretainedValue()
			if let bytes = a?.assumingMemoryBound(to: UInt8.self) {
				let fullCount = size*num
				for idx in 0..<fullCount {
					crl.bodyBytes.append(bytes[idx])
				}
				return fullCount
			}
			return 0
		}
		let _ = setOption(CURLOPT_WRITEFUNCTION, f: writeFunc)

		let _ = setOption(CURLOPT_READFUNCTION, f: { _,_,_,_ in 
		// it is dangerous to set the curl default fread function without READDATA
		// so the best option is to leave it blank
		//	fread($0, $1, $2, unsafeBitCast($3, to: UnsafeMutablePointer<FILE>.self)) 
			return 0
		})

	}

	/// Clean up and reset the CURL object for further use.
	/// Sets default options such as header/body read callbacks.
	public func reset() {
		guard let curl = self.curl else {
            return
        }
        if let multi = self.multi {
            curl_multi_remove_handle(multi, curl)
            self.multi = nil
        }
		if let slists = self.slists {
			curl_slist_free_all(slists)
			self.slists = UnsafeMutablePointer<curl_slist>(nil as OpaquePointer?)
		}
        curl_easy_reset(curl)
        setCurlOpts()
	}
	
	/// Cleanup and close the CURL request. Object should not be used again.
	/// This is called automatically when the object goes out of scope.
	/// It is safe to call this multiple times.
	public func close() {
		guard let curl = self.curl else {
			return
		}
		if let multi = self.multi {
			curl_multi_cleanup(multi)
			self.multi = nil
		}
		if let slists = self.slists {
			curl_slist_free_all(slists)
			self.slists = UnsafeMutablePointer<curl_slist>(nil as OpaquePointer?)
		}
		curl_easy_cleanup(curl)
		self.curl = nil
	}
	
	deinit {
		self.close()
	}

	private class ResponseAccumulator {
		var header = [UInt8]()
		var body = [UInt8]()
	}

	/// Perform the CURL request in a non-blocking manner. The closure will be called with the resulting code, header and body data.
	public func perform(closure: @escaping (Int, [UInt8], [UInt8]) -> ()) {
        guard let curl = self.curl else {
            return closure(-1, [UInt8](), [UInt8]())
        }
		let accum = ResponseAccumulator()
		if nil == self.multi {
			self.multi = curl_multi_init()
		}
		curl_multi_add_handle(multi, curl)

		performInner(accumulator: accum, closure: closure)
	}

	private func performInner(accumulator: ResponseAccumulator, closure: @escaping (Int, [UInt8], [UInt8]) -> ()) {
		let perf = self.perform()
		if let h = perf.2 {
			_ = accumulator.header.append(contentsOf: h)
		}
		if let b = perf.3 {
			_ = accumulator.body.append(contentsOf: b)
		}
		if perf.0 == false { // done
			closure(perf.1, accumulator.header, accumulator.body)
		} else {
			
			var timeout = 0
			curl_multi_timeout(self.multi, &timeout)
			if timeout == 0 {
				return self.performInner(accumulator: accumulator, closure: closure)
			}
			let timeoutSeconds: Double
			if timeout == -1 {
				timeoutSeconds = 0.1
			} else {
				timeoutSeconds = Double(timeout) / 1000
			}
			
			var fdsRd = fd_set(), fdsWr = fd_set(), fdsEx = fd_set()
			var fdsZero = fd_set()
			memset(&fdsZero, 0, MemoryLayout<fd_set>.size)
			memset(&fdsRd, 0, MemoryLayout<fd_set>.size)
			memset(&fdsWr, 0, MemoryLayout<fd_set>.size)
			memset(&fdsEx, 0, MemoryLayout<fd_set>.size)
			var max = Int32(0)
			curl_multi_fdset(self.multi, &fdsRd, &fdsWr, &fdsEx, &max)
			if max == -1 {
				Threading.dispatch {
					self.performInner(accumulator: accumulator, closure: closure)
				}
			} else if 0 != memcmp(&fdsZero, &fdsRd, MemoryLayout<fd_set>.size) {
				// wait for read
				NetEvent.add(socket: max, what: .read, timeoutSeconds: timeoutSeconds) {
					_, w in
					self.performInner(accumulator: accumulator, closure: closure)
				}
			} else if 0 != memcmp(&fdsZero, &fdsWr, MemoryLayout<fd_set>.size) {
				// wait for write
				NetEvent.add(socket: max, what: .write, timeoutSeconds: timeoutSeconds) {
					_, w in
					self.performInner(accumulator: accumulator, closure: closure)
				}
			} else {
				Threading.dispatch {
					self.performInner(accumulator: accumulator, closure: closure)
				}
			}
		}
	}

	/// Performs the request, blocking the current thread until it completes.
	/// - returns: A tuple consisting of: Int - the result code, [UInt8] - the header bytes if any, [UInt8] - the body bytes if any
	public func performFully() -> (Int, [UInt8], [UInt8]) {
		// revisit this deprecation for a minor point release @available(*, deprecated, message: "Use performFullySync() instead")
		guard let curl = self.curl else {
			return (-1, [UInt8](), [UInt8]())
		}
		let code = curl_easy_perform(curl)
		defer {
			self.headerBytes = [UInt8]()
			self.bodyBytes = [UInt8]()
			self.reset()
		}
		if code != CURLE_OK {
			let str = self.strError(code: code)
			print(str)
		}
		return (Int(code.rawValue), self.headerBytes, self.bodyBytes)
	}
	
	/// Performs the request, blocking the current thread until it completes.
	/// - returns: A tuple consisting of: Int - the result code, Int - the response code, [UInt8] - the header bytes if any, [UInt8] - the body bytes if any
	public func performFullySync() -> (resultCode: Int, responseCode: Int, headerBytes: [UInt8], bodyBytes: [UInt8]) {
		guard let curl = self.curl else {
			return (-1, -1, [UInt8](), [UInt8]())
		}
		let code = curl_easy_perform(curl)
		defer {
			self.headerBytes = [UInt8]()
			self.bodyBytes = [UInt8]()
			self.reset()
		}
		if code != CURLE_OK {
			let str = self.strError(code: code)
			print(str)
		}
		return (Int(code.rawValue), self.responseCode, self.headerBytes, self.bodyBytes)
	}

	/// Performs a bit of work on the current request.
	/// - returns: A tuple consisting of: Bool - should perform() be called again, Int - the result code, [UInt8] - the header bytes if any, [UInt8] - the body bytes if any
    public func perform() -> (Bool, Int, [UInt8]?, [UInt8]?) {
        guard let curl = self.curl else {
            return (false, -1, nil, nil)
        }
		if self.multi == nil {
			let multi = curl_multi_init()
            self.multi = multi
			curl_multi_add_handle(multi, curl)
		}
        guard let multi = self.multi else {
            return (false, -1, nil, nil)
        }
		var one: Int32 = 0
		var code = CURLM_OK
		repeat {

			code = curl_multi_perform(multi, &one)

		} while code == CURLM_CALL_MULTI_PERFORM

		guard code == CURLM_OK else {
			return (false, Int(code.rawValue), nil, nil)
		}
		var two: Int32 = 0
		let msg = curl_multi_info_read(multi, &two)

		defer {
			if self.headerBytes.count > 0 {
				self.headerBytes = [UInt8]()
			}
			if self.bodyBytes.count > 0 {
				self.bodyBytes = [UInt8]()
			}
		}

		if msg != nil {
			let msgResult = curl_get_msg_result(msg)
			guard msgResult == CURLE_OK else {
				return (false, Int(msgResult.rawValue), nil, nil)
			}
			return (false, Int(msgResult.rawValue),
				self.headerBytes.count > 0 ? self.headerBytes : nil,
				self.bodyBytes.count > 0 ? self.bodyBytes : nil)
		}
		return (true, 0,
			self.headerBytes.count > 0 ? self.headerBytes : nil,
			self.bodyBytes.count > 0 ? self.bodyBytes : nil)
	}

	/// Returns the String message for the given CURL result code.
	public func strError(code cod: CURLcode) -> String {
		return String(validatingUTF8: curl_easy_strerror(cod))!
	}

	/// Returns the Int value for the given CURLINFO.
    public func getInfo(_ info: CURLINFO) -> (Int, CURLcode) {
        guard let curl = self.curl else {
            return (-1, CURLE_FAILED_INIT)
        }
		var i = 0
		let c = curl_easy_getinfo_long(curl, info, &i)
		return (i, c)
	}

	/// Returns the String value for the given CURLINFO.
    public func getInfo(_ info: CURLINFO) -> (String, CURLcode) {
        guard let curl = self.curl else {
            return ("Not initialized", CURLE_FAILED_INIT)
        }
		let i = UnsafeMutablePointer<UnsafePointer<Int8>?>.allocate(capacity: 1)
		defer { i.deinitialize(count: 1); i.deallocate(capacity: 1) }
		let code = curl_easy_getinfo_cstr(curl, info, i)
		return (code != CURLE_OK ? "" : String(validatingUTF8: i.pointee!)!, code)
	}
	
	/// Sets the Int64 option value.
	@discardableResult
    public func setOption(_ option: CURLoption, int: Int64) -> CURLcode {
        guard let curl = self.curl else {
            return CURLE_FAILED_INIT
        }
		return curl_easy_setopt_int64(curl, option, int)
	}

	/// Sets the Int option value.
	@discardableResult
    public func setOption(_ option: CURLoption, int: Int) -> CURLcode {
        guard let curl = self.curl else {
            return CURLE_FAILED_INIT
        }
		return curl_easy_setopt_long(curl, option, int)
	}

	/// Sets the pointer option value.
	/// Note that the pointer value is not copied or otherwise manipulated or saved.
	/// It is up to the caller to ensure the pointer value has a lifetime which corresponds to its usage.
	@discardableResult
    public func setOption(_ option: CURLoption, v: UnsafeMutableRawPointer) -> CURLcode {
        guard let curl = self.curl else {
            return CURLE_FAILED_INIT
        }
		return curl_easy_setopt_void(curl, option, v)
	}

	/// Sets the callback function option value.
	@discardableResult
    public func setOption(_ option: CURLoption, f: @escaping curl_func) -> CURLcode {
        guard let curl = self.curl else {
            return CURLE_FAILED_INIT
        }
		return curl_easy_setopt_func(curl, option, f)
	}

	/// Sets the String option value.
	@discardableResult
    public func setOption(_ option: CURLoption, s: String) -> CURLcode {
        guard let curl = self.curl else {
            return CURLE_FAILED_INIT
        }
		switch(option.rawValue) {
		case CURLOPT_HTTP200ALIASES.rawValue,
			CURLOPT_HTTPHEADER.rawValue,
			CURLOPT_POSTQUOTE.rawValue,
			CURLOPT_PREQUOTE.rawValue,
			CURLOPT_QUOTE.rawValue,
			//CURLOPT_MAIL_FROM.rawValue,
			CURLOPT_MAIL_RCPT.rawValue:
            let slists = curl_slist_append(self.slists, s)
			guard slists != nil else {
				return CURLE_OUT_OF_MEMORY
			}
            self.slists = slists
			return curl_easy_setopt_slist(curl, option, self.slists)
		default:
			()
		}
		return curl_easy_setopt_cstr(self.curl!, option, s)
	}

  public class POSTFields {
    internal var first = UnsafeMutablePointer<curl_httppost>(bitPattern: 0)
    internal var last = UnsafeMutablePointer<curl_httppost>(bitPattern: 0)

    /// constructor, create a blank form without any fields
    /// must append each field manually
    public init() { }

    /// add a post field
    /// - parameters:
    ///   - key: post field name
    ///   - value: post field value string
    ///   - type: post field type, e.g., "text/html".
    ///  - returns:
    ///   CURLFORMCode, 0 for ok
    public func append(key: String, value: String, mimeType: String = "") -> CURLFORMcode {
      return curl_formadd_content(&first, &last, key, value, 0, mimeType.isEmpty ? nil : mimeType)
    }//end append

    /// add a post field
    /// - parameters:
    ///   - key: post field name
    ///   - buffer: post field value, binary buffer
    ///   - type: post field type, e.g., "image/jpeg".
    ///  - throws:
    ///   CURLFORMCode, 0 for ok
    public func append(key: String, buffer: [Int8], mimeType: String = "") -> CURLFORMcode {
      return curl_formadd_content(&first, &last, key, buffer, buffer.count, mimeType.isEmpty ? nil : mimeType)
    }//end append

    /// add a post field
    /// - parameters:
    ///   - key: post field name
    ///   - value: post field value string
    ///   - type: post field mime type, e.g., "image/jpeg".
    ///  - throws:
    ///   CURLFORMCode, 0 for ok
    public func append(key: String, path: String, mimeType: String = "") -> CURLFORMcode {
      return curl_formadd_file(&first, &last, key, path, mimeType.isEmpty ? nil : mimeType)
    }//end append

    deinit {
      curl_formfree(first)
      //curl_formfree(last)
    }//end deinit
  }//end class

  /// Post a form with different fields.
  public func formAddPost(fields: POSTFields) ->CURLcode {
    guard let p = fields.first else {
      return CURLcode(rawValue: 4096)
    }//end guard
    return curl_form_post(self.curl, p)
  }//end formAddPost
}
