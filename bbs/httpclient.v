module main

// A small HTTPS client for the AWS calls (SES, S3): V's net.mbedtls for the TLS, and a deadline on every step. It exists because net.http can wait forever to
// connect (V's dial has no connect timeout), and the daemon makes these calls from the loop that also drives the radio. It does what those calls need and
// nothing more: https only, one request per connection ("Connection: close"), no redirects, no proxies, no compression.
//
// The parts that decide things (reading a URL, writing the request, reading the answer) are plain functions on bytes and strings, tested in httpclient_test.v.
import net
import net.mbedtls
import os
import time

#include <poll.h>
#include <sys/socket.h>

struct C.pollfd {
mut:
	fd      int
	events  i16
	revents i16
}

fn C.poll(fds &C.pollfd, nfds u32, timeout int) int
fn C.close(fd int) int
fn C.connect(fd int, addr voidptr, len u32) int
fn C.getsockopt(fd int, level int, name int, val voidptr, len voidptr) int

const http_connect_wait = 8 * time.second // to reach the server, in all
const http_total_wait = 30 * time.second // for the whole request, connecting included
const http_step_wait = 2 * time.second // one read, so the deadline is looked at often
const http_max_head = 65536
const http_max_body = 20_000_000

struct HttpsTarget {
	host string
	port int
	path string // starts with /, includes the query
}

// The pieces of an https URL, or none for anything else (http, no host, spaces or control characters, a user:password@ part).
fn parse_https_url(url string) ?HttpsTarget {
	if !url.starts_with('https://') || url.bytes().any(it <= 32 || it == 127) {
		return none
	}
	rest := url['https://'.len..]
	slash := rest.index_u8(`/`)
	hostport := if slash >= 0 { rest[..slash] } else { rest }
	mut path := if slash >= 0 { rest[slash..] } else { '/' }
	if hostport == '' || hostport.contains('@') || hostport.starts_with('[') {
		return none
	}
	hash := path.index_u8(`#`)
	if hash >= 0 {
		path = path[..hash]
	}
	host := hostport.all_before(':')
	port := if hostport.contains(':') { hostport.all_after(':') } else { '443' }
	if host == '' || port == '' || !port.bytes().all(it.is_digit()) || port.int() < 1 || port.int() > 65535 {
		return none
	}
	return HttpsTarget{
		host: host.to_lower()
		port: port.int()
		path: path
	}
}

// The request as it goes on the wire. none when a header could not be written safely (a line break in a name or value would start another header).
fn build_http_request(method string, t HttpsTarget, headers map[string]string, body string) ?string {
	if method !in ['GET', 'POST', 'DELETE'] {
		return none
	}
	mut out := '${method} ${t.path} HTTP/1.1\r\nHost: ${if t.port == 443 {
		t.host
	} else {
		'${t.host}:${t.port}'
	}}\r\nConnection: close\r\nAccept-Encoding: identity\r\n'
	for k, v in headers {
		lower := k.to_lower()
		if lower in ['host', 'content-length', 'connection', 'accept-encoding', 'transfer-encoding'] {
			continue // the ones this function owns
		}
		if k == '' || k.bytes().any(it <= 32 || it == 127 || it == `:`) || v.bytes().any(it < 32 && it != `\t`) {
			return none
		}
		out += '${k}: ${v}\r\n'
	}
	if body != '' || method == 'POST' {
		out += 'Content-Length: ${body.len}\r\n'
	}
	return out + '\r\n' + body
}

struct ResponseHead {
	status  int // 0: it was not an HTTP answer
	length  i64 = -1 // Content-Length, or -1
	chunked bool
	body_at int // where the body starts in the bytes read
}

// The status line and headers, or none while the blank line that ends them has not arrived.
fn parse_response_head(raw []u8) ?ResponseHead {
	end := bytes_index(raw, [u8(`\r`), `\n`, `\r`, `\n`]) or { return none }
	lines := raw[..end].bytestr().split('\r\n')
	first := lines[0].split(' ')
	if first.len < 2 || !first[0].starts_with('HTTP/1.') || !first[1].bytes().all(it.is_digit()) || first[1].len != 3 {
		return ResponseHead{
			body_at: end + 4
		}
	}
	mut length := i64(-1)
	mut chunked := false
	for l in lines[1..] {
		name := l.all_before(':').to_lower().trim_space()
		val := l.all_after(':').trim_space()
		if name == 'content-length' && val.len > 0 && val.bytes().all(it.is_digit()) && val.len < 12 {
			length = val.i64()
		} else if name == 'transfer-encoding' && val.to_lower().contains('chunked') {
			chunked = true
		}
	}
	return ResponseHead{
		status:  first[1].int()
		length:  length
		chunked: chunked
		body_at: end + 4
	}
}

fn bytes_index(hay []u8, needle []u8) ?int {
	if needle.len == 0 || hay.len < needle.len {
		return none
	}
	for i in 0 .. hay.len - needle.len + 1 {
		if hay[i] == needle[0] && hay[i..i + needle.len] == needle {
			return i
		}
	}
	return none
}

// The body of a chunked answer, or none if it is not all there yet or is not well formed.
fn decode_chunked(data []u8) ?[]u8 {
	mut out := []u8{}
	mut i := 0
	for {
		eol := bytes_index(data[i..], [u8(`\r`), `\n`]) or { return none }
		size_text := data[i..i + eol].bytestr().all_before(';').trim_space()
		if size_text == '' || size_text.len > 8 || !size_text.bytes().all(it.is_hex_digit()) {
			return none
		}
		size := int(size_text.parse_int(16, 32) or { return none })
		i += eol + 2
		if size == 0 {
			return out // (trailers, if any, are ignored)
		}
		if i + size + 2 > data.len {
			return none
		}
		out << data[i..i + size]
		i += size + 2
		if out.len > http_max_body {
			return none
		}
	}
	return none
}

// The body once all of it has arrived, or none while more is to come (a body that ends when the server closes is only known to be whole at that point).
fn complete_body(raw []u8, h ResponseHead) ?[]u8 {
	if h.status in [204, 304] || h.status < 200 {
		return []u8{}
	}
	have := raw[h.body_at..]
	if h.chunked {
		return decode_chunked(have)
	}
	if h.length >= 0 {
		if have.len >= h.length {
			return have[..int(h.length)].clone()
		}
	}
	return none
}

fn is_http_timeout(err IError) bool {
	return mqtt_is_timeout(err)
}

// Opens a connection to one address and waits at most `wait` for it.
fn connect_one(addr net.Addr, wait time.Duration) !&net.TcpConn {
	mut s := net.new_tcp_socket(addr.family())!
	net.set_blocking(s.handle, false) or {
		C.close(s.handle)
		return err
	}
	size := if addr.family() == .ip6 { u32(28) } else { u32(16) } // sockaddr_in6, sockaddr_in
	res := C.connect(s.handle, voidptr(&addr), size)
	if res != 0 && net.error_code() !in [int(net.error_einprogress), int(net.error_ewouldblock),
		4] { // 4: EINTR
		C.close(s.handle)
		return error('could not connect: ${net.error_code()}')
	}
	if res != 0 {
		mut p := C.pollfd{
			fd:     s.handle
			events: 4 // POLLOUT
		}
		n := C.poll(&p, 1, int(wait / time.millisecond))
		if n <= 0 {
			C.close(s.handle)
			return error('timed out connecting')
		}
		mut soerr := i32(0)
		mut len := u32(sizeof(soerr))
		if C.getsockopt(s.handle, C.SOL_SOCKET, C.SO_ERROR, &soerr, &len) != 0 || soerr != 0 {
			C.close(s.handle)
			return error('could not connect: ${soerr}')
		}
	}
	net.set_blocking(s.handle, true) or {
		C.close(s.handle)
		return err
	}
	return &net.TcpConn{
		sock:          s
		read_timeout:  http_step_wait
		write_timeout: http_connect_wait
	}
}

// A TCP connection to host:port that gives up when `wait` is up, trying each address the name has.
fn dial_within(host string, port int, wait time.Duration) !&net.TcpConn {
	addrs := net.resolve_addrs_fuzzy('${host}:${port}', .tcp)!
	if addrs.len == 0 {
		return error('no address for ${host}')
	}
	deadline := time.now().add(wait)
	each := if addrs.len > 1 { wait / 2 } else { wait }
	mut last := 'no address for ${host}'
	for addr in addrs {
		left := deadline - time.now()
		if left <= 0 {
			break
		}
		return connect_one(addr, if left < each { left } else { each }) or {
			last = err.msg()
			continue
		}
	}
	return error(last)
}

// The one request, start to finish, inside `total`. Errors are for the log; the sender turns them into "no answer".
fn https_exchange(method string, url string, headers map[string]string, body string, total time.Duration) !HttpReply {
	t := parse_https_url(url) or { return error('not a usable https URL') }
	req := build_http_request(method, t, headers, body) or { return error('request could not be built') }
	ca := mqtt_ca_file()!
	deadline := time.now().add(total)
	mut tcp := dial_within(t.host, t.port, http_connect_wait)!
	mut tls := mbedtls.new_ssl_conn(
		verify:       ca
		validate:     true
		read_timeout: http_step_wait
	) or {
		tcp.close() or {}
		return err
	}
	tls.connect(mut tcp, t.host) or {
		tcp.close() or {}
		return error('TLS to ${t.host}: ${err.msg()}')
	}
	defer {
		tls.shutdown() or {}
	}
	tls.set_read_timeout(http_step_wait)
	data := req.bytes()
	mut off := 0
	for off < data.len {
		if time.now() > deadline {
			return error('timed out sending')
		}
		n := tls.write(data[off..])!
		if n <= 0 {
			return error('connection closed while sending')
		}
		off += n
	}
	mut raw := []u8{}
	mut buf := []u8{len: 16384}
	mut closed := false
	for {
		if head := parse_response_head(raw) {
			if head.status == 0 {
				return error('not an HTTP answer')
			}
			if full := complete_body(raw, head) {
				return HttpReply{
					status: head.status
					body:   full.bytestr()
				}
			}
			if head.length > http_max_body {
				return error('answer too large')
			}
			if closed {
				if head.chunked || head.length >= 0 {
					return error('the answer was cut short')
				}
				return HttpReply{
					status: head.status
					body:   raw[head.body_at..].bytestr()
				}
			}
		} else if closed {
			return error('closed before an answer')
		}
		if time.now() > deadline {
			return error('timed out waiting for the answer')
		}
		if raw.len > http_max_body + http_max_head {
			return error('answer too large')
		}
		n := tls.read(mut buf) or {
			if is_http_timeout(err) {
				continue
			}
			closed = true
			0
		}
		if n > 0 {
			raw << buf[..n]
		} else {
			closed = true
		}
	}
	return error('unreachable')
}

// HttpsSender is the real HttpSender: it never raises, an answer it could not get is a status of 0.
struct HttpsSender {
mut:
	started bool
}

fn (mut c HttpsSender) request(method string, url string, headers map[string]string, body string) HttpReply {
	if !c.started {
		c.started = true
		// A TLS write to a connection the other end has already closed would end the process with SIGPIPE (the "crash" the older pollers were written around).
		os.signal_opt(.pipe, fn (_ os.Signal) {}) or {}
	}
	return https_exchange(method, url, headers, body, http_total_wait) or {
		eprintln('[http] ${method} ${url.all_before('?')}: ${err.msg()}')
		HttpReply{}
	}
}
