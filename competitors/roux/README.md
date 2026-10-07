# roux (Roc on fourneau)

A Roc app on roux, the Roc platform built on fourneau: the handler is
Roc, compiled with the server into one static binary (musl). The host
listens on `ROUX_ADDRESS`; the app names port 8080. Built with the pinned Roc
nightly against the roux and fourneau checkouts beside this repository.

`GET /menu`: `Menu.rocstache`, compiled to Roc by roux's rocstache-gen at build time (`Menu.roc` is generated, not committed).

`GET /sse`: roux's `Url.query_value` and Roc's `Json.parse` for the
signals, then roux's `Sse` effects, an event a `send!`, on the request's
fiber.
