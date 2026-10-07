package windows

import (
	"context"
	"strings"
	"sync"
	"testing"
)

func TestOutputCaptureCapsCombinedStreams(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	capture := newOutputCapture(cancel)

	if written, err := capture.writer(true).Write([]byte(strings.Repeat("o", maxOutputBytes/2))); err != nil || written != maxOutputBytes/2 {
		t.Fatalf("stdout write = (%d, %v), want (%d, nil)", written, err, maxOutputBytes/2)
	}
	if written, err := capture.writer(false).Write([]byte(strings.Repeat("e", maxOutputBytes/2))); err != nil || written != maxOutputBytes/2 {
		t.Fatalf("stderr write = (%d, %v), want (%d, nil)", written, err, maxOutputBytes/2)
	}
	if written, err := capture.writer(true).Write([]byte("x")); written != 0 || err != ErrOutputLimit {
		t.Fatalf("overflow write = (%d, %v), want (0, ErrOutputLimit)", written, err)
	}
	if ctx.Err() != context.Canceled {
		t.Fatalf("overflow did not cancel the process context: %v", ctx.Err())
	}

	stdout, stderr, overflow := capture.result()
	if len(stdout)+len(stderr) != maxOutputBytes || !overflow {
		t.Fatalf("captured %d bytes with overflow=%t, want %d and true", len(stdout)+len(stderr), overflow, maxOutputBytes)
	}
}
func TestOutputCaptureSerializesConcurrentStreams(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	capture := newOutputCapture(cancel)

	var writers sync.WaitGroup
	for i := 0; i < 8; i++ {
		writers.Add(1)
		go func(stdout bool) {
			defer writers.Done()
			_, _ = capture.writer(stdout).Write([]byte(strings.Repeat("x", maxOutputBytes/4)))
		}(i%2 == 0)
	}
	writers.Wait()

	stdout, stderr, overflow := capture.result()
	if len(stdout)+len(stderr) != maxOutputBytes || !overflow || ctx.Err() != context.Canceled {
		t.Fatalf("combined output=%d bytes, overflow=%t, context error=%v; want bounded overflow cancellation", len(stdout)+len(stderr), overflow, ctx.Err())
	}
}
