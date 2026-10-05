package main

import (
	"flag"
	"fmt"
	"os"

	"github.com/i-got-this-faa/shepherd/internal/version"
)

func main() {
	showVersion := flag.Bool("version", false, "display version and build metadata")
	flag.BoolVar(showVersion, "v", false, "display version and build metadata")
	flag.Parse()

	if *showVersion {
		fmt.Println(version.Get("shepherd-builder"))
		return
	}

	fmt.Printf("%s: build-worker daemon (use -version for build metadata)\n", os.Args[0])
}
