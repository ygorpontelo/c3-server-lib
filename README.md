## Asynchronous networking library for C3

### Main goals

- Build on top of polling events, tasks are async.
- Provide implementations of server and client.
- Provide websockets and http/3 (this one will take some time).
- Provide connections pools, useful for db conns for example.
- Provide ways to deal with files.
- Improve correctness and security.
- Improve usability, keep things simple where possible.
- This should not be a full comprehensive "framework".

### General notes and "sidequests"

- How to deal with json? Maybe it's best to have a separate lib just that or maybe provide basic functions for it.
- Same problem with TLS, maybe incorporate a separate lib for it.
- I think it would be nice to provide a function attribute that works as the "add_endpoint" function.
- I would love to have a templating engine, so we can build http responses (possible other stuff too). Something like [jinja]("https://jinja.palletsprojects.com/en/stable/").

This is very experimental, i would not recommend to use in production in any way. The internals __will__ change and C3 is also changing rapidly at the moment.

Discussions and PRs are welcome :D.
