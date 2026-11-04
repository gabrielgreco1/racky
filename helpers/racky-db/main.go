package main

import (
	"context"
	"encoding/json"
	"os"
	"time"
)

func main() {
	// stdout carries exactly one JSON document; nothing else is ever printed (and never the request).
	out := json.NewEncoder(os.Stdout)
	req, err := ParseRequest(os.Stdin)
	if err != nil {
		_ = out.Encode(fail(err))
		os.Exit(0)
	}
	deadline := time.Duration(req.TimeoutSeconds * float64(time.Second))
	ctx, cancel := context.WithTimeout(context.Background(), deadline)
	defer cancel()
	// Some drivers ignore a cancelled context while blocked on the socket: this timer ends the process regardless.
	watchdog := time.AfterFunc(deadline+2*time.Second, func() {
		_ = out.Encode(Response{Error: &ErrorBody{Kind: KindTimeout, Message: "The server did not answer in time."}})
		os.Exit(0)
	})
	defer watchdog.Stop()
	_ = out.Encode(run(ctx, req))
}

func run(ctx context.Context, req *Request) Response {
	t, err := ParseDSN(req.Engine, req.Dsn)
	if err != nil {
		return fail(err)
	}
	s, err := openSession(ctx, dialect(req.Engine), t)
	if err != nil {
		return fail(err, t.secrets...)
	}
	defer s.close()
	resp := Execute(ctx, s, req)
	if resp.Error != nil {
		resp.Error.Message = scrub(resp.Error.Message, t.secrets...)
	}
	return resp
}
