# Spec 41 — Request failover and load distribution

## Dependencies
Spec 39 (multi-server), Spec 40 (sync).

## Concept
Client sends request; any capable server can respond. Automatic failover.

## Behavior
- Client sends request to channel (not specific server)
- First capable server responds
- Other servers see response, don't duplicate
- If no response in Xms, client retries

## Coordination
- **Response claim (0x05)**: server claims "I'm handling this req_id"
- Other servers back off on seeing claim
- Prevents duplicate responses wasting airtime

## Deliverables
- `encode_response_claim(req_id, server_id)`
- Daemon: check for existing claim before responding
- Client: retry logic if no response

## Acceptance criteria
- [ ] Request answered by one server only
- [ ] If that server dies mid-request, another takes over on retry
- [ ] No duplicate responses

## Test
Send request, kill responder mid-flight, verify retry succeeds with other server.
