(in-package #:cl-rpc/websocket)

;;; -----------------------------------------------------------------------
;;; SHA1 (RFC 3174) — inline implementation as an alternative to ironclad
;;; -----------------------------------------------------------------------

(defun %rol32 (x n)
  "32-bit left rotate"
  (logior (ldb (byte 32 0) (ash x n))
          (ldb (byte 32 0) (ash x (- n 32)))))

(defun sha1 (octets)
  "Return the SHA1 digest of OCTETS (an unsigned-byte 8 vector) as a 20-byte vector."
  (let* ((ml       (length octets))
         (ml-bits  (* ml 8))
         (pad-len  (* 64 (ceiling (+ ml 9) 64)))
         (msg      (make-array pad-len :element-type '(unsigned-byte 8) :initial-element 0)))
    (replace msg octets)
    (setf (aref msg ml) #x80)
    ;; Write the bit length at the end in 64-bit big-endian
    (loop for i from 1 to 8
          do (setf (aref msg (- pad-len i))
                   (ldb (byte 8 (* 8 (- i 1))) ml-bits)))
    (let ((h0 #x67452301) (h1 #xEFCDAB89) (h2 #x98BADCFE)
          (h3 #x10325476) (h4 #xC3D2E1F0))
      (loop for bs from 0 below pad-len by 64
            do (let ((w (make-array 80 :element-type '(unsigned-byte 32) :initial-element 0)))
                 (loop for i below 16
                       do (setf (aref w i)
                                (+ (ash (aref msg (+ bs (* i 4) 0)) 24)
                                   (ash (aref msg (+ bs (* i 4) 1)) 16)
                                   (ash (aref msg (+ bs (* i 4) 2))  8)
                                   (aref msg (+ bs (* i 4) 3)))))
                 (loop for i from 16 to 79
                       do (setf (aref w i)
                                (%rol32 (logxor (aref w (- i 3)) (aref w (- i 8))
                                               (aref w (- i 14)) (aref w (- i 16)))
                                       1)))
                 (let ((a h0) (b h1) (c h2) (d h3) (e h4))
                   (dotimes (i 80)
                     (multiple-value-bind (f k)
                         (cond ((< i 20) (values (logior (logand b c) (logand (lognot b) d)) #x5A827999))
                               ((< i 40) (values (logxor b c d) #x6ED9EBA1))
                               ((< i 60) (values (logior (logand b c) (logand b d) (logand c d)) #x8F1BBCDC))
                               (t        (values (logxor b c d) #xCA62C1D6)))
                       (let ((temp (ldb (byte 32 0)
                                        (+ (%rol32 a 5) (ldb (byte 32 0) f) e k (aref w i)))))
                         (setf e d  d c  c (%rol32 b 30)  b a  a temp))))
                   (setf h0 (ldb (byte 32 0) (+ h0 a))
                         h1 (ldb (byte 32 0) (+ h1 b))
                         h2 (ldb (byte 32 0) (+ h2 c))
                         h3 (ldb (byte 32 0) (+ h3 d))
                         h4 (ldb (byte 32 0) (+ h4 e))))))
      (let ((digest (make-array 20 :element-type '(unsigned-byte 8))))
        (loop for i below 5
              for h in (list h0 h1 h2 h3 h4)
              do (loop for j below 4
                       do (setf (aref digest (+ (* i 4) j))
                                (ldb (byte 8 (* 8 (- 3 j))) h))))
        digest))))

;;; -----------------------------------------------------------------------
;;; Base64 encoding — inline implementation as an alternative to cl-base64
;;; -----------------------------------------------------------------------

(defparameter +b64+ "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/")

(defun base64-encode (octets)
  "Encode OCTETS as a Base64 string."
  (let* ((n   (length octets))
         (out (make-array (* 4 (ceiling n 3)) :element-type 'character))
         (j   0))
    (loop for i from 0 below n by 3
          for r = (- n i)
          for b0 = (aref octets i)
          for b1 = (if (> r 1) (aref octets (+ i 1)) 0)
          for b2 = (if (> r 2) (aref octets (+ i 2)) 0)
          do (setf (aref out j)       (char +b64+ (ash b0 -2))
                   (aref out (+ j 1)) (char +b64+ (logior (ash (logand b0 3) 4) (ash b1 -4)))
                   (aref out (+ j 2)) (if (> r 1) (char +b64+ (logior (ash (logand b1 15) 2) (ash b2 -6))) #\=)
                   (aref out (+ j 3)) (if (> r 2) (char +b64+ (logand b2 63)) #\=))
             (incf j 4))
    (coerce out 'string)))

;;; -----------------------------------------------------------------------
;;; ASCII / UTF-8 conversion utilities (alternative to babel)
;;; -----------------------------------------------------------------------

(defun ascii-to-octets (str)
  "Convert an ASCII string to a byte vector."
  (map '(vector (unsigned-byte 8)) #'char-code str))

(defun octets-to-ascii (octets)
  "Convert a byte vector to an ASCII string (non-ASCII bytes are passed through as-is)."
  (map 'string #'code-char octets))

;;; -----------------------------------------------------------------------
;;; HTTP Upgrade handshake
;;; -----------------------------------------------------------------------

(defun read-byte-line (stream)
  "Read a line terminated by CRLF or LF from a binary stream and return it as a string.
  Returns nil upon reaching EOF."
  (let ((buf (make-array 256 :element-type '(unsigned-byte 8)
                             :adjustable t :fill-pointer 0)))
    (loop
      (let ((b (read-byte stream nil nil)))
        (when (null b) (return nil))
        (cond
          ((= b 13)  ; CR: skip the following LF
           (let ((next (read-byte stream nil nil)))
             (when (and next (not (= next 10)))
               (vector-push-extend next buf)))
           (return (octets-to-ascii buf)))
          ((= b 10)  ; LF
           (return (octets-to-ascii buf)))
          (t
           (vector-push-extend b buf)))))))

(defun read-http-request-lines (stream)
  "Return the header lines of an HTTP request as a list (up to the blank line)."
  (let ((result '()))
    (loop
      (let ((line (read-byte-line stream)))
        (when (null line) (return (nreverse result)))
        (let ((trimmed (string-right-trim '(#\return #\newline #\space) line)))
          (when (string= trimmed "") (return (nreverse result)))
          (push trimmed result))))))

(defun extract-header (lines name)
  "Return the value corresponding to the given header name (case-insensitive).
Whitespace around the value is optional (RFC 9110), so \"Origin:x\" is found too."
  (some (lambda (line)
          (let ((colon (position #\: line)))
            (when (and colon (string-equal name line :end2 colon))
              (string-trim '(#\space #\tab #\return #\newline)
                           (subseq line (1+ colon))))))
        lines))

(defun compute-accept-key (client-key)
  "RFC 6455 Section 1.3: Compute the value of the Sec-WebSocket-Accept header."
  (let* ((magic    "258EAFA5-E914-47DA-95CA-C5AB0DC85B11")
         (combined (concatenate 'string client-key magic)))
    (base64-encode (sha1 (micros/backend:string-to-utf8 combined)))))

(defun write-ascii-string (stream str)
  "Write a string as ASCII bytes to a binary stream."
  (write-sequence (ascii-to-octets str) stream))

(defparameter +crlf+ (coerce '(13 10) '(vector (unsigned-byte 8))))

(defun send-handshake-response (stream accept-key)
  "Send a successful WebSocket handshake response to a binary stream."
  (flet ((wl (str)
           (write-sequence (ascii-to-octets str) stream)
           (write-sequence +crlf+ stream)))
    (wl (concatenate 'string "HTTP/1.1 101 Switching Protocols"))
    (wl "Upgrade: websocket")
    (wl "Connection: Upgrade")
    (wl (concatenate 'string "Sec-WebSocket-Accept: " accept-key))
    (write-sequence +crlf+ stream)
    (finish-output stream)))

(defun handshake (stream &key lines)
  "Perform the WebSocket handshake. Returns t on success.
  If lines is provided, use those already-read header lines instead of reading from the stream."
  (let* ((lines (or lines (read-http-request-lines stream)))
         (key   (extract-header lines "Sec-WebSocket-Key")))
    (unless key
      (error "No Sec-WebSocket-Key in request"))
    (send-handshake-response stream (compute-accept-key key))
    t))

;;; -----------------------------------------------------------------------
;;; WebSocket frame read/write (RFC 6455 Section 5)
;;; -----------------------------------------------------------------------

(defun read-exact-bytes (stream n)
  "Read exactly n bytes from stream and return them as an (unsigned-byte 8) array."
  (let ((buf (make-array n :element-type '(unsigned-byte 8))))
    (let ((read-count (read-sequence buf stream)))
      (unless (= read-count n)
        (error "Unexpected end of stream: expected ~D bytes, got ~D" n read-count)))
    buf))

(defun read-frame (stream)
  "Read a WebSocket frame and return (values opcode-keyword payload-string-or-nil)."
  (let* ((b0           (read-byte stream))
         (b1           (read-byte stream))
         (opcode       (logand b0 #x0f))
         (masked       (logbitp 7 b1))
         (payload-len  (logand b1 #x7f))
         (actual-len   (cond ((= payload-len 126)
                              (let ((b (read-exact-bytes stream 2)))
                                (+ (ash (aref b 0) 8) (aref b 1))))
                             ((= payload-len 127)
                              (let ((b (read-exact-bytes stream 8)))
                                (+ (ash (aref b 4) 24) (ash (aref b 5) 16)
                                   (ash (aref b 6) 8)  (aref b 7))))
                             (t payload-len)))
         (mask-key     (when masked (read-exact-bytes stream 4)))
         (payload      (read-exact-bytes stream actual-len)))
    (when masked
      (dotimes (i actual-len)
        (setf (aref payload i)
              (logxor (aref payload i) (aref mask-key (mod i 4))))))
    (case opcode
      (#x0 (values :continuation (micros/backend:utf8-to-string payload)))
      (#x1 (values :text         (micros/backend:utf8-to-string payload)))
      (#x2 (values :binary       payload))
      (#x8 (values :close        nil))
      (#x9 (values :ping         nil))
      (#xa (values :pong         nil))
      (t   (error "Unsupported WebSocket opcode: #x~X" opcode)))))

(defun write-text-frame (stream text)
  "Write a text frame to a binary stream (server side sends frames unmasked)."
  (let* ((octets (micros/backend:string-to-utf8 text))
         (len    (length octets)))
    (write-byte #x81 stream)
    (cond ((< len 126)
           (write-byte len stream))
          ((< len 65536)
           (write-byte 126 stream)
           (write-byte (ash len -8) stream)
           (write-byte (logand len #xff) stream))
          (t
           (write-byte 127 stream)
           (loop for shift from 56 downto 0 by 8
                 do (write-byte (ldb (byte 8 shift) len) stream))))
    (write-sequence octets stream)
    (finish-output stream)))

(defun write-pong-frame (stream)
  (write-byte #x8a stream) (write-byte #x00 stream) (finish-output stream))

(defun write-close-frame (stream)
  (write-byte #x88 stream) (write-byte #x00 stream) (finish-output stream))
