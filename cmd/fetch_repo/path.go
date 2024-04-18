/* Copyright 2019 The Bazel Authors. All rights reserved.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

   http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

package main

import (
	"bytes"
	"fmt"
	"os/exec"
	"strings"
)

func moduleFromPath(from string, dest string) error {
	err := copyTree(dest, from)
	if err != nil {
		return err
	}

	cmd := exec.Command(findGoPath(), "mod", "download", "-json")
	cmd.Dir = dest
	cmd.Args = append(cmd.Args, "-modcacherw")

	buf := &bytes.Buffer{}
	bufErr := &bytes.Buffer{}
	cmd.Stdout = buf
	cmd.Stderr = bufErr
	fmt.Printf("Running: %s %s\n", cmd.Path, strings.Join(cmd.Args, " "))
	// TODO: handle errors
	cmd.Run()

	// if _, ok := dlErr.(*exec.ExitError); !ok {
	// 	return fmt.Errorf("error running 'go mod download': %v", dlErr)
	// }
	return nil
}
