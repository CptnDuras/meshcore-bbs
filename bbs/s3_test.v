module main

// A network that answers from a script and remembers every request.
struct S3Fake {
mut:
	replies  []HttpReply
	requests []string
	headers  []map[string]string
}

fn (mut f S3Fake) request(method string, url string, headers map[string]string, body string) HttpReply {
	f.requests << '${method} ${url}'
	f.headers << headers
	if f.replies.len == 0 {
		return HttpReply{}
	}
	r := f.replies[0]
	f.replies = f.replies[1..].clone()
	return r
}

fn s3_cfg() SesConfig {
	return parse_ses_config('access_key_id=AKIAEXAMPLE\nsecret_access_key=secretexample\nfrom=mesh@xerokuhl.com\ninbound_bucket=meshbbs-mail-123\ninbound_group=mesh\n') or {
		panic(err)
	}
}

// ---- signing, against the example AWS publishes for S3 (a GET of one object, with a Range header) ----

fn test_s3_signing_matches_the_documented_example() {
	creds := AwsCreds{
		access_key: 'AKIAIOSFODNN7EXAMPLE'
		secret_key: 'wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY'
	}
	auth := sign_v4(creds, SignInput{
		method:   'GET'
		path:     '/test.txt'
		headers:  {
			'host':                 'examplebucket.s3.amazonaws.com'
			'range':                'bytes=0-9'
			'x-amz-content-sha256': empty_sha256
			'x-amz-date':           '20130524T000000Z'
		}
		region:   'us-east-1'
		service:  's3'
		amz_date: '20130524T000000Z'
	})
	assert auth == 'AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request, SignedHeaders=host;range;x-amz-content-sha256;x-amz-date, Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41'
}

fn test_the_empty_payload_hash_is_the_hash_of_nothing() {
	assert sha256_hex('') == empty_sha256
}

// ---- requests ----

fn test_a_list_request_goes_to_the_bucket_with_the_prefix_and_is_signed() {
	r := s3_request(s3_cfg(), 'GET', '/', 'list-type=2&max-keys=20&prefix=inbound%2F', 1440938160)
	assert r.url == 'https://meshbbs-mail-123.s3.us-west-2.amazonaws.com/?list-type=2&max-keys=20&prefix=inbound%2F'
	assert r.headers['x-amz-date'] == '20150830T123600Z' && r.headers['x-amz-content-sha256'] == empty_sha256
	assert r.headers['Authorization'].starts_with('AWS4-HMAC-SHA256 Credential=AKIAEXAMPLE/20150830/us-west-2/s3/aws4_request, SignedHeaders=host;x-amz-content-sha256;x-amz-date, Signature=')
}

fn test_encoding_a_query_value() {
	assert uri_encode('inbound/') == 'inbound%2F'
	assert uri_encode('a b&c=d') == 'a%20b%26c%3Dd'
	assert uri_encode('AZaz09-_.~') == 'AZaz09-_.~'
}

// ---- keys ----

fn test_only_keys_that_are_messages_under_the_prefix_are_accepted() {
	for k in ['inbound/abc123', 'inbound/a-b_c.d', 'inbound/' + 'x'.repeat(100)] {
		assert valid_object_key(k, 'inbound/'), k
	}
	for k in ['', 'inbound/', 'other/abc', 'inbound/../etc', 'inbound/a/b', 'inbound/a b',
		'inbound/a&amp;b', 'inbound/a?x=1', 'inbound/' + 'x'.repeat(300), 'abc'] {
		assert !valid_object_key(k, 'inbound/'), k
	}
	assert valid_object_key('abc123', '') && !valid_object_key('a/b', '')
}

// ---- reading the list ----

const list_xml = '<?xml version="1.0" encoding="UTF-8"?>
<ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><Name>meshbbs-mail-123</Name><Prefix>inbound/</Prefix><KeyCount>4</KeyCount><MaxKeys>20</MaxKeys><IsTruncated>false</IsTruncated>
<Contents><Key>inbound/AMAZONSESSETUPNOTIFICATION</Key><LastModified>2026-11-04T12:00:00.000Z</LastModified><ETag>"x"</ETag><Size>40</Size><StorageClass>STANDARD</StorageClass></Contents>
<Contents><Key>inbound/6t0qf8g1</Key><LastModified>2026-11-04T12:01:00.000Z</LastModified><Size>2048</Size></Contents>
<Contents><Key>inbound/evil/../key</Key><Size>1</Size></Contents>
<Contents><Key>inbound/bad&amp;key</Key><Size>1</Size></Contents>
</ListBucketResult>'

fn test_the_list_gives_the_messages_and_their_sizes_and_skips_odd_keys() {
	got := parse_object_list(list_xml, 'inbound/')
	assert got.map(it.key) == ['inbound/AMAZONSESSETUPNOTIFICATION', 'inbound/6t0qf8g1']
	assert got.map(it.size) == [40, 2048]
}

fn test_an_empty_or_odd_list_is_nothing() {
	assert parse_object_list('<ListBucketResult><KeyCount>0</KeyCount></ListBucketResult>', 'inbound/').len == 0
	assert parse_object_list('', 'inbound/').len == 0
	assert parse_object_list('<Contents><Key>inbound/a</Key>', 'inbound/').len == 0 // not closed
}

// ---- the store ----

fn test_listing_asks_the_bucket_and_returns_what_is_there() {
	mut fake := &S3Fake{
		replies: [HttpReply{
			status: 200
			body:   list_xml
		}]
	}
	mut s := S3Store{
		cfg:    s3_cfg()
		sender: fake
	}
	got := s.list(20) or { panic(err) }
	assert got.len == 2
	assert fake.requests.len == 1 && fake.requests[0].starts_with('GET https://meshbbs-mail-123.s3.us-west-2.amazonaws.com/?list-type=2&max-keys=20&prefix=inbound%2F')
}

fn test_a_refusal_from_s3_is_an_error_with_its_words() {
	mut fake := &S3Fake{
		replies: [
			HttpReply{
				status: 403
				body:   '<Error><Code>AccessDenied</Code><Message>Access Denied</Message></Error>'
			},
			HttpReply{},
		]
	}
	mut s := S3Store{
		cfg:    s3_cfg()
		sender: fake
	}
	s.list(5) or {
		assert err.msg() == 'S3 answered 403 AccessDenied: Access Denied'
		s.list(5) or {
			assert err.msg() == 'no answer from S3'
			return
		}
		assert false
	}
	assert false
}

fn test_get_fetches_one_message_and_delete_removes_it() {
	mut fake := &S3Fake{
		replies: [HttpReply{
			status: 200
			body:   'From: a@b.co\n\nhi'
		}, HttpReply{
			status: 204
		}, HttpReply{
			status: 404
		}]
	}
	mut s := S3Store{
		cfg:    s3_cfg()
		sender: fake
	}
	assert (s.get('inbound/abc123') or { panic(err) }) == 'From: a@b.co\n\nhi'
	s.delete('inbound/abc123') or { panic(err) }
	s.delete('inbound/abc123') or { panic('a message already gone is fine: ${err}') }
	assert fake.requests == [
		'GET https://meshbbs-mail-123.s3.us-west-2.amazonaws.com/inbound/abc123',
		'DELETE https://meshbbs-mail-123.s3.us-west-2.amazonaws.com/inbound/abc123',
		'DELETE https://meshbbs-mail-123.s3.us-west-2.amazonaws.com/inbound/abc123',
	]
}

fn test_a_key_that_is_not_a_message_is_never_requested() {
	mut fake := &S3Fake{}
	mut s := S3Store{
		cfg:    s3_cfg()
		sender: fake
	}
	for k in ['inbound/../../secret', 'other/x', 'inbound/a/b', ''] {
		s.get(k) or { continue }
		assert false, 'fetched ${k}'
	}
	s.delete('inbound/../x') or {
		assert fake.requests.len == 0
		return
	}
	assert false
}

fn test_a_failed_get_or_delete_says_so() {
	mut fake := &S3Fake{
		replies: [HttpReply{
			status: 500
		}, HttpReply{
			status: 403
			body:   '<Error><Code>AccessDenied</Code><Message>no</Message></Error>'
		}]
	}
	mut s := S3Store{
		cfg:    s3_cfg()
		sender: fake
	}
	s.get('inbound/abc') or { assert err.msg().contains('500') }
	s.delete('inbound/abc') or {
		assert err.msg().contains('AccessDenied')
		return
	}
	assert false
}
