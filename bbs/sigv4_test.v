module main

import encoding.hex

// Request signing, against the example AWS publishes in its Signature Version 4 documentation (a GET of IAM's ListUsers with the documentation's own
// example credentials). If these values do not come out exactly, every call to the real service would be refused.

const doc_creds = AwsCreds{
	access_key: 'AKIDEXAMPLE'
	secret_key: 'wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY'
}

fn doc_input() SignInput {
	return SignInput{
		method:   'GET'
		path:     '/'
		query:    'Action=ListUsers&Version=2010-05-08'
		headers:  {
			'content-type': 'application/x-www-form-urlencoded; charset=utf-8'
			'host':         'iam.amazonaws.com'
			'x-amz-date':   '20150830T123600Z'
		}
		region:   'us-east-1'
		service:  'iam'
		amz_date: '20150830T123600Z'
	}
}

fn test_the_documented_canonical_request_has_the_documented_hash() {
	canon, signed := canonical_request(doc_input())
	assert signed == 'content-type;host;x-amz-date'
	assert sha256_hex(canon) == 'f536975d06c0309214f805bb90ccff089219ecd68b2577efef23edd43b7e1a59'
}

fn test_the_documented_signing_key() {
	key := signing_key(doc_creds.secret_key, '20150830', 'us-east-1', 'iam')
	assert hex.encode(key) == 'c4afb1cc5771d871763a393e44b703571b55cc28424d1a5e86da6ed3c154a4b9'
}

fn test_the_documented_signature() {
	auth := sign_v4(doc_creds, doc_input())
	assert auth == 'AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/iam/aws4_request, SignedHeaders=content-type;host;x-amz-date, Signature=5d672d79c15b13162d9279b0855cfba6789a8edb4c82c400e06b5924a6f2b5d7'
}

fn test_the_signature_changes_with_the_body_and_with_the_secret() {
	a := sign_v4(doc_creds, doc_input())
	mut other := doc_input()
	other = SignInput{
		...other
		body: '{"x":1}'
	}
	assert sign_v4(doc_creds, other) != a
	assert sign_v4(AwsCreds{
		...doc_creds
		secret_key: 'another'
	}, doc_input()) != a
}

fn test_the_date_header_is_the_utc_time_in_the_form_aws_wants() {
	assert amz_date_of(1440938160) == '20150830T123600Z'
	assert amz_date_of(0) == '19700101T000000Z'
}
