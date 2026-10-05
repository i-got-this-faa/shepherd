package version

import (
	"strings"
	"testing"
)

func TestGetAndString(t *testing.T) {
	d := Get("shepherd-test")

	if d.Binary != "shepherd-test" {
		t.Fatalf("expected binary shepherd-test, got %q", d.Binary)
	}
	if d.Version != "dev" {
		t.Fatalf("expected default version dev, got %q", d.Version)
	}
	if d.OS == "" || d.Arch == "" {
		t.Fatal("expected OS and Arch to be set")
	}

	str := d.String()
	if !strings.Contains(str, "shepherd-test version dev") {
		t.Fatalf("unexpected string output: %s", str)
	}
}
