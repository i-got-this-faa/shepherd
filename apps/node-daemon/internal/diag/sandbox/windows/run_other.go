//go:build !windows

package windows

import (
	"context"
	"errors"
)

var ErrUnsupported = errors.New("Windows JEA sandbox is unavailable on this platform")

func Install(context.Context) error {
	return ErrUnsupported
}

func RunReadOnlyShell(context.Context, string, uint32) (Result, error) {
	return Result{}, ErrUnsupported
}
