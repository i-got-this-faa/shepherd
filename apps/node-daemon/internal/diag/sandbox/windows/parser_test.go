package windows

import (
	"strings"
	"testing"
)

func TestParseAcceptsAllowlistedReadPipelines(t *testing.T) {
	tests := []struct {
		name  string
		input string
		want  []string
	}{
		{
			name:  "service details with safe projection",
			input: "Get-Service -Name Spooler | Select-Object -Property Name,Status",
			want:  []string{"Get-Service", "Select-Object"},
		},
		{
			name:  "bounded event log query",
			input: "Get-WinEvent -LogName System -MaxEvents 25 | Select-Object -Property LogName,TimeCreated,LevelDisplayName",
			want:  []string{"Get-WinEvent", "Select-Object"},
		},
		{
			name:  "allowlisted operating system registry values",
			input: `Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion" -Name ProductName | Select-Object -Property ProductName`,
			want:  []string{"Get-ItemProperty", "Select-Object"},
		},
		{
			name:  "allowlisted registry UBR projection",
			input: `Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion" -Name UBR | Select-Object -Property UBR`,
			want:  []string{"Get-ItemProperty", "Select-Object"},
		},
		{
			name:  "process lookup with bounded projection",
			input: "Get-Process -Id 1234 | Sort-Object -Property Name | Select-Object -Property Name,Id",
			want:  []string{"Get-Process", "Sort-Object", "Select-Object"},
		},
		{
			name:  "interface lookup with bounded projection",
			input: "Get-NetIPConfiguration -InterfaceAlias Ethernet | Select-Object -Property InterfaceAlias,IPv4Address",
			want:  []string{"Get-NetIPConfiguration", "Select-Object"},
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := Parse(tt.input)
			if err != nil {
				t.Fatalf("Parse(%q) failed: %v", tt.input, err)
			}
			if len(got) != len(tt.want) {
				t.Fatalf("got %d pipeline commands, want %d", len(got), len(tt.want))
			}
			for i, name := range tt.want {
				if got[i].Name != name {
					t.Errorf("command %d = %q, want %q", i, got[i].Name, name)
				}
			}
		})
	}
}

func TestParseRejectsPowerShellAndOutOfPolicyQueries(t *testing.T) {
	const allowedKey = `HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion`
	tests := []struct {
		name  string
		input string
	}{
		{name: "script block", input: "& { Get-Process }"},
		{name: "variable expansion", input: "Get-Service -Name $env:PATH"},
		{name: "command separator", input: "Get-Service -Name Spooler; Remove-Item C:\\"},
		{name: "non-allowlisted cmdlet", input: "Remove-Item -Path C:\\Windows"},
		{name: "alias", input: "gps -Name explorer"},
		{name: "script block pipeline", input: "Get-Service | ForEach-Object { $_.Name }"},
		{name: "wildcard service name", input: "Get-Service -Name *"},
		{name: "secret event log", input: "Get-WinEvent -LogName Security"},
		{name: "unbounded event query", input: "Get-WinEvent -LogName System -MaxEvents 1001"},
		{name: "registry secret hive", input: `Get-ItemProperty -Path "HKLM:\SAM" -Name ProductName`},
		{name: "registry path traversal", input: `Get-ItemProperty -Path "` + allowedKey + `\..\SAM" -Name ProductName`},
		{name: "sensitive registry property", input: `Get-ItemProperty -Path "` + allowedKey + `" -Name Secret`},
		{name: "network probe not exposed", input: "Test-NetConnection -ComputerName example.com"},
		{name: "pipeline starts with a projection", input: "Select-Object -Property Name"},
		{name: "query cmdlet cannot be chained as a filter", input: "Get-Service | Get-Process"},
		{name: "duplicate parameter", input: "Get-Service -Name Spooler -Name W32Time"},
		{name: "missing parameter value", input: "Get-Service -Name"},
		{name: "empty pipeline stage", input: "Get-Service || Select-Object -Property Name"},
		{name: "unprojected output", input: "Get-Service -Name Spooler"},
		{name: "missing service name", input: "Get-Service | Select-Object -Property Name"},
		{name: "unprojected event messages", input: "Get-WinEvent -LogName System -MaxEvents 25"},
		{name: "missing registry key", input: `Get-ItemProperty -Name ProductName | Select-Object -Property ProductName`},
		{name: "missing interface alias", input: "Get-NetIPConfiguration | Select-Object -Property InterfaceAlias"},
		{name: "command too long", input: "Get-Service -Name " + strings.Repeat("x", maxCommandBytes)},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if _, err := Parse(tt.input); err == nil {
				t.Fatalf("Parse(%q) unexpectedly succeeded", tt.input)
			}
		})
	}
}
