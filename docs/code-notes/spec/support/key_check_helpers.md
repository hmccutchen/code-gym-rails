# spec/support/key_check_helpers.rb

## The default stub

`PATCH /setup` asks a provider about every pasted key, and dozens of request
specs paste one. Without a default each would send a real request. Every
example therefore gets `AiService#check_key` answering `:accepted`, the
result that leaves the old behaviour unchanged. `FakeService` defines its
own `#check_key`, which the stub on `AiService` does not replace.

A spec of the check itself is tagged `real_key_check`, which skips the stub.

## `#stub_key_check`

It wraps `#key_check_connection` and swaps only the adapter on the
connection the service built. The headers, the timeouts and the absence of
retry middleware are then the real ones, so "one request after a 503" is
proved against the stack production uses. It returns the list of request
environments the adapter saw. Each is the environment Faraday goes on to
fill with the response, so read its method, URL and request headers, not
its body.
