//go:build windows

package windows

import (
	"context"
	"embed"
	"encoding/base64"
	"encoding/binary"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"time"
	"unicode/utf16"
)

const maxTimeoutSeconds = 60

//go:embed assets/ShepherdDiag.psrc assets/ShepherdDiag.pssc assets/ShepherdDiag.psd1 assets/ShepherdDiag.psm1
var jeaAssets embed.FS

// Install writes the constrained JEA role and registers its session endpoint.
func Install(parent context.Context) error {
	if parent == nil {
		return fmt.Errorf("context is required")
	}
	role, err := jeaAssets.ReadFile("assets/ShepherdDiag.psrc")
	if err != nil {
		return fmt.Errorf("read JEA role capability: %w", err)
	}
	configuration, err := jeaAssets.ReadFile("assets/ShepherdDiag.pssc")
	if err != nil {
		return fmt.Errorf("read JEA session configuration: %w", err)
	}
	manifest, err := jeaAssets.ReadFile("assets/ShepherdDiag.psd1")
	if err != nil {
		return fmt.Errorf("read JEA module manifest: %w", err)
	}
	module, err := jeaAssets.ReadFile("assets/ShepherdDiag.psm1")
	if err != nil {
		return fmt.Errorf("read JEA module script: %w", err)
	}
	roleEncoded := base64.StdEncoding.EncodeToString(role)
	configurationEncoded := base64.StdEncoding.EncodeToString(configuration)
	manifestEncoded := base64.StdEncoding.EncodeToString(manifest)
	moduleEncoded := base64.StdEncoding.EncodeToString(module)
	script := installScript(roleEncoded, configurationEncoded, manifestEncoded, moduleEncoded)
	ctx, cancel := context.WithTimeout(parent, maxTimeoutSeconds*time.Second)
	defer cancel()
	_, err = runPowerShell(ctx, script)
	if err != nil {
		return fmt.Errorf("install ShepherdDiag JEA endpoint: %w", err)
	}
	return nil
}

// RunReadOnlyShell runs a parsed allowlisted pipeline in the ShepherdDiag JEA endpoint.
func RunReadOnlyShell(parent context.Context, command string, timeoutSec uint32) (Result, error) {
	if parent == nil {
		return Result{}, fmt.Errorf("context is required")
	}
	if timeoutSec == 0 || timeoutSec > maxTimeoutSeconds {
		return Result{}, fmt.Errorf("timeout must be between 1 and %d seconds", maxTimeoutSeconds)
	}
	pipeline, err := Parse(command)
	if err != nil {
		return Result{}, err
	}
	script := `$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$session = $null
try {
    $session = New-PSSession -ComputerName 'localhost' -ConfigurationName 'ShepherdDiag' -ErrorAction Stop
    Invoke-Command -Session $session -ScriptBlock { ` + renderPipeline(pipeline) + ` } -ErrorAction Stop | ConvertTo-Json -Depth 5 -Compress
    exit 0
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
finally {
    if ($null -ne $session) { Remove-PSSession -Session $session -ErrorAction SilentlyContinue }
}`
	ctx, cancel := context.WithTimeout(parent, time.Duration(timeoutSec)*time.Second)
	defer cancel()
	return runPowerShell(ctx, script)
}

func runPowerShell(ctx context.Context, script string) (Result, error) {
	systemRoot := os.Getenv("SystemRoot")
	if systemRoot == "" || !filepath.IsAbs(systemRoot) {
		return Result{}, fmt.Errorf("SystemRoot is unavailable")
	}
	executable := filepath.Join(systemRoot, "System32", "WindowsPowerShell", "v1.0", "powershell.exe")
	info, err := os.Stat(executable)
	if err != nil || !info.Mode().IsRegular() {
		return Result{}, fmt.Errorf("Windows PowerShell 5.1 is unavailable")
	}
	processCtx, cancel := context.WithCancel(ctx)
	defer cancel()
	capture := newOutputCapture(cancel)
	command := exec.CommandContext(processCtx, executable, "-NoLogo", "-NoProfile", "-NonInteractive", "-EncodedCommand", encodePowerShell(script))
	command.Stdout = capture.writer(true)
	command.Stderr = capture.writer(false)
	runErr := command.Run()
	stdout, stderr, overflow := capture.result()
	result := Result{Stdout: stdout, Stderr: stderr}
	if overflow {
		return result, ErrOutputLimit
	}
	if ctx.Err() != nil {
		return result, ctx.Err()
	}
	if runErr != nil {
		var exitErr *exec.ExitError
		if errors.As(runErr, &exitErr) {
			result.ExitCode = exitErr.ExitCode()
			return result, fmt.Errorf("PowerShell exited with code %d", result.ExitCode)
		}
		return result, fmt.Errorf("run PowerShell: %w", runErr)
	}
	return result, nil
}
func encodePowerShell(script string) string {
	encoded := utf16.Encode([]rune(script))
	buffer := make([]byte, len(encoded)*2)
	for i, unit := range encoded {
		binary.LittleEndian.PutUint16(buffer[i*2:], unit)
	}
	return base64.StdEncoding.EncodeToString(buffer)
}

func installScript(roleCapability, sessionConfiguration, moduleManifest, moduleScript string) string {
	return `$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$moduleRoot = Join-Path $env:ProgramFiles 'WindowsPowerShell\Modules\ShepherdDiag'
$roleRoot = Join-Path $moduleRoot 'RoleCapabilities'
$configRoot = Join-Path $env:ProgramData 'Shepherd\JEA'
$null = New-Item -ItemType Directory -Path $roleRoot, $configRoot -Force
$system = [System.Security.Principal.SecurityIdentifier]::new('S-1-5-18')
$admins = [System.Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
function Set-ShepherdDirectoryAcl([string]$Path) {
    $acl = [System.Security.AccessControl.DirectorySecurity]::new()
    $acl.SetAccessRuleProtection($true, $false)
    $acl.SetOwner($system)
    $inheritance = [System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [System.Security.AccessControl.InheritanceFlags]::ObjectInherit
    foreach ($sid in @($system, $admins)) {
        $rule = [System.Security.AccessControl.FileSystemAccessRule]::new($sid, [System.Security.AccessControl.FileSystemRights]::FullControl, $inheritance, [System.Security.AccessControl.PropagationFlags]::None, [System.Security.AccessControl.AccessControlType]::Allow)
        $acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $Path -AclObject $acl
}
function Set-ShepherdFileAcl([string]$Path) {
    $acl = [System.Security.AccessControl.FileSecurity]::new()
    $acl.SetAccessRuleProtection($true, $false)
    $acl.SetOwner($system)
    foreach ($sid in @($system, $admins)) {
        $rule = [System.Security.AccessControl.FileSystemAccessRule]::new($sid, [System.Security.AccessControl.FileSystemRights]::FullControl, [System.Security.AccessControl.AccessControlType]::Allow)
        $acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $Path -AclObject $acl
}
Set-ShepherdDirectoryAcl $moduleRoot
Set-ShepherdDirectoryAcl $roleRoot
Set-ShepherdDirectoryAcl $configRoot
$roleBytes = [Convert]::FromBase64String('` + roleCapability + `')
$configBytes = [Convert]::FromBase64String('` + sessionConfiguration + `')
$manifestBytes = [Convert]::FromBase64String('` + moduleManifest + `')
$moduleBytes = [Convert]::FromBase64String('` + moduleScript + `')
$manifestPath = Join-Path $moduleRoot 'ShepherdDiag.psd1'
$modulePath = Join-Path $moduleRoot 'ShepherdDiag.psm1'
$rolePath = Join-Path $roleRoot 'ShepherdDiag.psrc'
$configPath = Join-Path $configRoot 'ShepherdDiag.pssc'
[System.IO.File]::WriteAllBytes($manifestPath, $manifestBytes)
[System.IO.File]::WriteAllBytes($modulePath, $moduleBytes)
[System.IO.File]::WriteAllBytes($rolePath, $roleBytes)
[System.IO.File]::WriteAllBytes($configPath, $configBytes)
Set-ShepherdFileAcl $manifestPath
Set-ShepherdFileAcl $modulePath
Set-ShepherdFileAcl $rolePath
Set-ShepherdFileAcl $configPath
Register-PSSessionConfiguration -Name 'ShepherdDiag' -Path $configPath -Force -SecurityDescriptorSddl 'O:SYG:SYD:P(A;;GA;;;SY)' | Out-Null
`
}
