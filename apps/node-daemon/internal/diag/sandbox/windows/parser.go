package windows

import (
	"fmt"
	"regexp"
	"strconv"
	"strings"
)

const maxCommandBytes = 4096
const maxPipelineCommands = 4

type Parameter struct {
	Name  string
	Value string
}

type Command struct {
	Name       string
	Parameters []Parameter
}

type Pipeline []Command

var serviceNamePattern = regexp.MustCompile(`^[A-Za-z0-9_.-]{1,128}$`)
var interfaceNamePattern = regexp.MustCompile(`^[A-Za-z0-9 _.-]{1,128}$`)
var safePropertyPattern = regexp.MustCompile(`^[A-Za-z][A-Za-z0-9]{0,63}$`)
var currentVersionKey = `HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion`

var selectableProperties = map[string]struct{}{
	"CurrentBuild": {}, "CurrentBuildNumber": {}, "DisplayVersion": {}, "EditionID": {},
	"IPv4Address": {}, "IPv6Address": {}, "Id": {}, "InterfaceAlias": {},
	"LevelDisplayName": {}, "LogName": {}, "Name": {}, "NetProfile": {},
	"ProcessName": {}, "ProductName": {}, "StartType": {}, "Status": {},
	"TimeCreated": {}, "UBR": {},
}
var commandParameters = map[string][]string{
	"Get-Service":            {"Name"},
	"Get-Process":            {"Name", "Id"},
	"Get-WinEvent":           {"LogName", "MaxEvents"},
	"Get-NetIPConfiguration": {"InterfaceAlias"},
	"Get-ItemProperty":       {"Path", "Name"},
	"Select-Object":          {"Property"},
	"Sort-Object":            {"Property"},
}

// Parse accepts a small command-only language, not PowerShell source code.
func Parse(input string) (Pipeline, error) {
	if len(input) == 0 || len(input) > maxCommandBytes {
		return nil, fmt.Errorf("command length must be between 1 and %d bytes", maxCommandBytes)
	}
	tokens, err := tokenize(input)
	if err != nil {
		return nil, err
	}
	if len(tokens) == 0 {
		return nil, fmt.Errorf("command is empty")
	}

	var pipeline Pipeline
	var segment []string
	for _, token := range tokens {
		if token == "|" {
			command, err := parseCommand(segment)
			if err != nil {
				return nil, err
			}
			pipeline = append(pipeline, command)
			segment = segment[:0]
			continue
		}
		segment = append(segment, token)
	}
	command, err := parseCommand(segment)
	if err != nil {
		return nil, err
	}
	pipeline = append(pipeline, command)
	if len(pipeline) > maxPipelineCommands {
		return nil, fmt.Errorf("pipeline may contain at most %d commands", maxPipelineCommands)
	}
	if err := validatePipeline(pipeline); err != nil {
		return nil, err
	}
	return pipeline, nil
}

func tokenize(input string) ([]string, error) {
	var tokens []string
	var value strings.Builder
	var quote byte
	inToken := false
	for i := 0; i < len(input); i++ {
		ch := input[i]
		if quote != 0 {
			if ch == quote {
				quote = 0
				continue
			}
			if ch == '\n' || ch == '\r' || ch == '`' || ch == '$' {
				return nil, fmt.Errorf("unsupported character in quoted argument")
			}
			value.WriteByte(ch)
			continue
		}
		switch {
		case ch == '\'' || ch == '"':
			if inToken {
				return nil, fmt.Errorf("quotes must enclose a complete argument")
			}
			quote = ch
			inToken = true
		case ch == '|':
			if inToken {
				tokens = append(tokens, value.String())
				value.Reset()
				inToken = false
			}
			tokens = append(tokens, "|")
		case ch == ' ' || ch == '\t':
			if inToken {
				tokens = append(tokens, value.String())
				value.Reset()
				inToken = false
			}
		case ch == ';' || ch == '&' || ch == '<' || ch == '>' || ch == '{' || ch == '}' || ch == '[' || ch == ']' || ch == '(' || ch == ')' || ch == '`' || ch == '$' || ch == '\n' || ch == '\r':
			return nil, fmt.Errorf("unsupported PowerShell syntax")
		default:
			inToken = true
			value.WriteByte(ch)
		}
	}
	if quote != 0 {
		return nil, fmt.Errorf("unterminated quoted argument")
	}
	if inToken {
		tokens = append(tokens, value.String())
	}
	return tokens, nil
}

func parseCommand(tokens []string) (Command, error) {
	if len(tokens) == 0 {
		return Command{}, fmt.Errorf("pipeline contains an empty command")
	}
	name, ok := canonicalCommand(tokens[0])
	if !ok {
		return Command{}, fmt.Errorf("cmdlet %q is not allowed", tokens[0])
	}
	command := Command{Name: name}
	seen := make(map[string]struct{}, (len(tokens)-1)/2)
	for i := 1; i < len(tokens); i += 2 {
		if i+1 >= len(tokens) || len(tokens[i]) < 2 || tokens[i][0] != '-' {
			return Command{}, fmt.Errorf("cmdlet %s accepts only named parameters with values", name)
		}
		parameter := canonicalParameter(name, tokens[i][1:])
		if parameter == "" {
			return Command{}, fmt.Errorf("parameter %q is not allowed for %s", tokens[i], name)
		}
		if _, exists := seen[parameter]; exists {
			return Command{}, fmt.Errorf("parameter %q was specified more than once", parameter)
		}
		seen[parameter] = struct{}{}
		if err := validateArgument(name, parameter, tokens[i+1]); err != nil {
			return Command{}, err
		}
		command.Parameters = append(command.Parameters, Parameter{Name: parameter, Value: tokens[i+1]})
	}
	if err := validateRequiredParameters(command, seen); err != nil {
		return Command{}, err
	}
	return command, nil
}

func canonicalCommand(name string) (string, bool) {
	for _, allowed := range [...]string{"Get-Service", "Get-Process", "Get-WinEvent", "Get-NetIPConfiguration", "Get-ItemProperty", "Select-Object", "Sort-Object"} {
		if strings.EqualFold(name, allowed) {
			return allowed, true
		}
	}
	return "", false
}

func canonicalParameter(command, parameter string) string {
	for _, name := range commandParameters[command] {
		if strings.EqualFold(parameter, name) {
			return name
		}
	}
	return ""
}

func validateRequiredParameters(command Command, seen map[string]struct{}) error {
	required := []string(nil)
	switch command.Name {
	case "Get-Service":
		required = []string{"Name"}
	case "Get-WinEvent":
		required = []string{"LogName", "MaxEvents"}
	case "Get-ItemProperty":
		required = []string{"Path", "Name"}
	case "Get-NetIPConfiguration":
		required = []string{"InterfaceAlias"}
	case "Select-Object", "Sort-Object":
		required = []string{"Property"}
	case "Get-Process":
		if _, byName := seen["Name"]; !byName {
			if _, byID := seen["Id"]; !byID {
				return fmt.Errorf("Get-Process requires Name or Id")
			}
		}
	}
	for _, parameter := range required {
		if _, ok := seen[parameter]; !ok {
			return fmt.Errorf("%s requires %s", command.Name, parameter)
		}
	}
	return nil
}

func validateArgument(command, parameter, value string) error {
	invalid := func() error { return fmt.Errorf("value for %s -%s is outside the allowlist", command, parameter) }
	switch command {
	case "Get-Service", "Get-Process":
		switch parameter {
		case "Name":
			if !serviceNamePattern.MatchString(value) {
				return invalid()
			}
		case "Id":
			id, err := strconv.Atoi(value)
			if err != nil || id < 1 || id > 2147483647 {
				return invalid()
			}
		}
	case "Get-WinEvent":
		switch parameter {
		case "LogName":
			if value != "Application" && value != "System" && value != "Setup" {
				return invalid()
			}
		case "MaxEvents":
			count, err := strconv.Atoi(value)
			if err != nil || count < 1 || count > 1000 {
				return invalid()
			}
		}
	case "Get-NetIPConfiguration":
		if !interfaceNamePattern.MatchString(value) {
			return invalid()
		}
	case "Get-ItemProperty":
		switch parameter {
		case "Path":
			if value != currentVersionKey {
				return invalid()
			}
		case "Name":
			if !isAllowedRegistryValue(value) {
				return invalid()
			}
		}
	case "Select-Object", "Sort-Object":
		if parameter != "Property" || !isAllowedProperties(value) {
			return invalid()
		}
	}
	return nil
}

func isAllowedRegistryValue(value string) bool {
	switch value {
	case "ProductName", "DisplayVersion", "CurrentBuild", "CurrentBuildNumber", "UBR", "EditionID":
		return true
	default:
		return false
	}
}

func isAllowedProperties(value string) bool {
	if value == "" {
		return false
	}
	for _, property := range strings.Split(value, ",") {
		if !safePropertyPattern.MatchString(property) {
			return false
		}
		if _, ok := selectableProperties[property]; !ok {
			return false
		}
	}
	return true
}

func validatePipeline(pipeline Pipeline) error {
	if len(pipeline) < 2 || strings.HasPrefix(pipeline[0].Name, "Select-") || strings.HasPrefix(pipeline[0].Name, "Sort-") {
		return fmt.Errorf("pipeline must start with an allowlisted read cmdlet and end with a property projection")
	}
	if pipeline[len(pipeline)-1].Name != "Select-Object" {
		return fmt.Errorf("pipeline must end with Select-Object")
	}
	for _, command := range pipeline[1 : len(pipeline)-1] {
		if command.Name != "Sort-Object" {
			return fmt.Errorf("only Sort-Object may precede the final Select-Object")
		}
	}
	return nil
}
