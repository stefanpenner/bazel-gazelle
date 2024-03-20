package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"go/build"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
)

type GoModDownloadResult struct {
	Dir   string
	Sum   string
	Error string
}

func isModeCacherwSupported() bool {
	// Check whether -modcacherw is supported.
	// Assume that fetch_repo was built with the same version of Go we're running.
	modcacherw := false
	for _, tag := range build.Default.ReleaseTags {
		if tag == "go1.14" {
			modcacherw = true
			break
		}
	}

	return modcacherw
}
func findGoPath() string {
	// Locate the go binary. If GOROOT is set, we'll use that one; otherwise,
	// we'll use PATH.
	goPath := "go"
	if runtime.GOOS == "windows" {
		goPath += ".exe"
	}
	if goroot, ok := os.LookupEnv("GOROOT"); ok {
		goPath = filepath.Join(goroot, "bin", goPath)
	}
	return goPath
}

func runGoModDownload(dl *GoModDownloadResult, dest string, importpath string, version string) error {
	buf := &bytes.Buffer{}
	bufErr := &bytes.Buffer{}
	cmd := exec.Command(findGoPath(), "mod", "download", "-json")
	cmd.Dir = dest
	if isModeCacherwSupported() {
		cmd.Args = append(cmd.Args, "-modcacherw")
	}

	if version != "" && importpath != "" {
		cmd.Args = append(cmd.Args, importpath+"@"+version)
	}

	cmd.Stdout = buf
	cmd.Stderr = bufErr
	fmt.Printf("Running: %s %s\n", cmd.Path, strings.Join(cmd.Args, " "))
	dlErr := cmd.Run()
	if dlErr != nil {
		if _, ok := dlErr.(*exec.ExitError); !ok {
			if bufErr.Len() > 0 {
				return fmt.Errorf("%s %s: %s", cmd.Path, strings.Join(cmd.Args, " "), bufErr.Bytes())
			} else {
				return fmt.Errorf("%s %s: %v", cmd.Path, strings.Join(cmd.Args, " "), dlErr)
			}
		}
	}

	// Parse the JSON output.
	if err := json.Unmarshal(buf.Bytes(), &dl); err != nil {
		if bufErr.Len() > 0 {
			return fmt.Errorf("%s %s: %s", cmd.Path, strings.Join(cmd.Args, " "), bufErr.Bytes())
		} else {
			return fmt.Errorf("%s %s: %v", cmd.Path, strings.Join(cmd.Args, " "), err)
		}
	}
	if dl.Error != "" {
		return errors.New(dl.Error)
	}
	if dlErr != nil {
		return dlErr
	}

	fmt.Printf("Downloaded: %s\n", dl.Dir)

	return nil
}
