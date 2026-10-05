package version

import (
	"fmt"
	"runtime"
)

var (
	// Version is populated at build time via -ldflags "-X ...Version=x.y.z".
	Version = "dev"
	// Commit is populated at build time via -ldflags "-X ...Commit=sha".
	Commit = "none"
	// Date is populated at build time via -ldflags "-X ...Date=rfc3339".
	Date = "unknown"
)

// Details holds structured runtime and build metadata.
type Details struct {
	Binary    string `json:"binary"`
	Version   string `json:"version"`
	Commit    string `json:"commit"`
	BuildDate string `json:"build_date"`
	GoVersion string `json:"go_version"`
	OS        string `json:"os"`
	Arch      string `json:"arch"`
}

// Get returns the build and runtime information for binary.
func Get(binary string) Details {
	return Details{
		Binary:    binary,
		Version:   Version,
		Commit:    Commit,
		BuildDate: Date,
		GoVersion: runtime.Version(),
		OS:        runtime.GOOS,
		Arch:      runtime.GOARCH,
	}
}

// String returns a single-line summary formatted for CLI --version output.
func (d Details) String() string {
	return fmt.Sprintf("%s version %s (commit %s, built %s, %s/%s, %s)",
		d.Binary, d.Version, d.Commit, d.BuildDate, d.OS, d.Arch, d.GoVersion)
}
