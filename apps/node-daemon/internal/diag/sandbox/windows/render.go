package windows

import "strings"

func renderPipeline(pipeline Pipeline) string {
	var script strings.Builder
	for i, command := range pipeline {
		if i > 0 {
			script.WriteString(" | ")
		}
		script.WriteString(command.Name)
		for _, parameter := range command.Parameters {
			script.WriteString(" -")
			script.WriteString(parameter.Name)
			script.WriteByte(' ')
			if parameter.Name == "Property" {
				for j, property := range strings.Split(parameter.Value, ",") {
					if j > 0 {
						script.WriteByte(',')
					}
					script.WriteString(property)
				}
			} else {
				script.WriteByte('\'')
				script.WriteString(strings.ReplaceAll(parameter.Value, "'", "''"))
				script.WriteByte('\'')
			}
		}
	}
	return script.String()
}
