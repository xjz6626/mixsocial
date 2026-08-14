//go:build windows

package sidecar

import "os/exec"

func configureProcess(*exec.Cmd) {}

func stopProcess(command *exec.Cmd, _ bool) error {
	return command.Process.Kill()
}
