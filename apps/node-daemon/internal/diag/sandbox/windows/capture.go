package windows

import (
	"bytes"
	"context"
	"errors"
	"sync"
)

const maxOutputBytes = 64 * 1024

var ErrOutputLimit = errors.New("PowerShell output exceeded 64 KiB")

type outputCapture struct {
	mutex    sync.Mutex
	stdout   bytes.Buffer
	stderr   bytes.Buffer
	size     int
	cancel   context.CancelFunc
	overflow bool
}

type outputWriter struct {
	capture *outputCapture
	stdout  bool
}

func newOutputCapture(cancel context.CancelFunc) *outputCapture {
	return &outputCapture{cancel: cancel}
}

func (capture *outputCapture) writer(stdout bool) outputWriter {
	return outputWriter{capture: capture, stdout: stdout}
}

func (writer outputWriter) Write(value []byte) (int, error) {
	capture := writer.capture
	capture.mutex.Lock()
	defer capture.mutex.Unlock()
	remaining := maxOutputBytes - capture.size
	written := len(value)
	if written > remaining {
		written = remaining
		capture.overflow = true
		capture.cancel()
	}
	if writer.stdout {
		_, _ = capture.stdout.Write(value[:written])
	} else {
		_, _ = capture.stderr.Write(value[:written])
	}
	capture.size += written
	if written < len(value) {
		return written, ErrOutputLimit
	}
	return written, nil
}

func (capture *outputCapture) result() (stdout, stderr string, overflow bool) {
	capture.mutex.Lock()
	defer capture.mutex.Unlock()
	return capture.stdout.String(), capture.stderr.String(), capture.overflow
}
