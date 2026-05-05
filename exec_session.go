package main

import (
	"bufio"
	"bytes"
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"sync"
	"sync/atomic"
	"time"

	corev1 "k8s.io/api/core/v1"
	"k8s.io/client-go/kubernetes/scheme"
	"k8s.io/client-go/rest"
	kexec "k8s.io/kubectl/pkg/cmd/exec"
)

const (
	execSessionQueueSize = 64
	// Buffered so processStdout can push chunks without blocking on a slow consumer.
	stdoutChanSize  = 1024
	stderrLimit     = 1024
	exitCodeSuccess = "0"
)

var errSessionClosed = errors.New("session closed")

// commandErr carries the result of a remote command's stderr side.
type commandErr struct {
	stderr []byte
	err    error
}

// commandOutput holds the result of a single remote command.
type commandOutput struct {
	// Streamed lines, closed when the stdout marker is found or the pipe dies.
	commandStdout chan []byte
	// Unique per-command delimiter to separate output on the shared pipe.
	marker []byte
	// Buffered (size 1), sent after the stderr marker is found.
	commandErr chan commandErr
}

// execSession wraps a persistent "kubectl exec sh" connection to a container.
type execSession struct {
	stdinWriter            *io.PipeWriter
	stdoutPipe, stderrPipe *io.PipeReader
	sendMtx                sync.Mutex
	outputs                chan *commandOutput
	stdoutOutputs          chan *commandOutput
	stderrOutputs          chan *commandOutput
	cancel                 context.CancelFunc
	done                   chan struct{}
	execErr                error
	dead                   atomic.Bool
	lastUsed               atomic.Int64
	heapIdx                int
}

func newExecSession(ctx context.Context, containerName, podName, namespaceName string) (*execSession, error) {
	config, _, err := getKubeConfig()
	if err != nil {
		return nil, err
	}
	restClient, err := rest.RESTClientFor(config)
	if err != nil {
		return nil, err
	}

	req := restClient.Post().
		Resource("pods").
		Name(podName).
		Namespace(namespaceName).
		SubResource("exec")
	req.VersionedParams(&corev1.PodExecOptions{
		Container: containerName,
		Command:   []string{"sh"},
		Stdin:     true,
		Stdout:    true,
		Stderr:    true,
	}, scheme.ParameterCodec)

	ctx, cancel := context.WithCancel(ctx)
	done := make(chan struct{})
	stdinReader, stdinWriter := io.Pipe()
	stdoutReader, stdoutWriter := io.Pipe()
	stderrReader, stderrWriter := io.Pipe()
	s := &execSession{
		stdinWriter:   stdinWriter,
		stdoutPipe:    stdoutReader,
		stderrPipe:    stderrReader,
		outputs:       make(chan *commandOutput, execSessionQueueSize),
		stdoutOutputs: make(chan *commandOutput, execSessionQueueSize),
		stderrOutputs: make(chan *commandOutput, execSessionQueueSize),
		cancel:        cancel,
		done:          done,
		heapIdx:       -1,
	}
	go func() {
		defer close(done)
		defer func() { _ = stdinReader.Close() }()
		defer func() { _ = stderrWriter.Close() }()
		defer func() { _ = stdoutWriter.Close() }()
		executor := &kexec.DefaultRemoteExecutor{}
		s.execErr = executor.ExecuteWithContext(ctx, req.URL(), config, stdinReader, stdoutWriter, stderrWriter, false, nil)
	}()

	s.touch()
	return s, nil
}

// close tears down the session: removes it from the pool, closes pipes,
// cancels the context, and waits for the executor goroutine to exit.
func (e *execSession) close() {
	sessions.remove(e)
	_ = e.stdinWriter.Close()
	// Unblock the executor if it is stuck writing to the pipes.
	_ = e.stdoutPipe.Close()
	_ = e.stderrPipe.Close()
	e.cancel()
	<-e.done
}

// exec sends a command to the container shell and returns a commandOutput
// for consuming the result.
func (e *execSession) exec(command []byte) (*commandOutput, error) {
	e.sendMtx.Lock()
	defer e.sendMtx.Unlock()
	sessions.touch(e)

	var rnd [8]byte
	_, _ = rand.Read(rnd[:])
	marker := hex.EncodeToString(rnd[:])

	output := &commandOutput{
		commandStdout: make(chan []byte, stdoutChanSize),
		marker:        []byte(marker + "\n"),
		commandErr:    make(chan commandErr, 1),
	}
	select {
	case e.outputs <- output:
	case <-e.done:
		return nil, fmt.Errorf("%w: %w", errSessionClosed, e.execErr)
	}

	// _e=$? captures exit code before echo (which resets $?).
	// "echo >&2" ensures a newline on stderr before the exit code marker,
	// so the marker is always on its own line even if the command wrote to
	// stderr without a trailing newline.
	command = fmt.Appendf(command, ";_e=$?;echo >&2;echo ${_e}%s >&2;echo %s\n", marker, marker)
	if _, err := e.stdinWriter.Write(command); err != nil {
		e.dead.Store(true)
		e.close()
		return nil, fmt.Errorf("%w: %w", errSessionClosed, err)
	}
	return output, nil
}

// touch updates the last-used timestamp for pool eviction ordering.
func (e *execSession) touch() {
	e.lastUsed.Store(time.Now().UnixNano())
}

// alive reports whether the session is still usable.
func (e *execSession) alive() bool {
	if e.dead.Load() {
		return false
	}
	select {
	case <-e.done:
		return false
	default:
		return true
	}
}

// forwardOutput is the session's main loop. It dispatches each queued
// commandOutput to dedicated stdout and stderr processing goroutines.
// Returns (and marks the session dead) when the executor exits.
func (e *execSession) forwardOutput() {
	defer func() {
		e.dead.Store(true)
		close(e.stdoutOutputs)
		close(e.stderrOutputs)
		e.close()
		drainPendingOutputs(e.outputs)
	}()

	stdoutReader := bufio.NewReader(e.stdoutPipe)
	stderrReader := bufio.NewReader(e.stderrPipe)

	go func() {
		for output := range e.stdoutOutputs {
			processStdout(stdoutReader, output)
		}
	}()
	go func() {
		for output := range e.stderrOutputs {
			processStderr(stderrReader, output)
		}
	}()

	for {
		select {
		case output := <-e.outputs:
			e.stdoutOutputs <- output
			e.stderrOutputs <- output
		case <-e.done:
			return
		}
	}
}

// processStdout reads lines from the shared stdout pipe until the
// command's marker is found, forwarding each line to output.commandStdout.
func processStdout(reader *bufio.Reader, output *commandOutput) {
	defer close(output.commandStdout)
	for {
		raw, err := reader.ReadBytes('\n')
		if len(raw) > 0 {
			if line, end := trimMarker(raw, output.marker); end {
				if len(line) > 0 {
					output.commandStdout <- line
				}
				return
			}
			output.commandStdout <- raw
		}
		if err != nil {
			return
		}
	}
}

// processStderr reads lines from the shared stderr pipe until the
// command's marker is found. The marker line carries the exit code.
// Collected stderr is capped at stderrLimit bytes.
func processStderr(reader *bufio.Reader, output *commandOutput) {
	var stderr []byte
	var cmdErr error
	for {
		raw, err := reader.ReadBytes('\n')
		if len(raw) > 0 {
			if code, end := trimMarker(raw, output.marker); end {
				if string(code) != exitCodeSuccess {
					cmdErr = fmt.Errorf("remote command failed (exit %s)", code)
				}
				break
			}
			// may overshoot stderrLimit by one line.
			if len(stderr) < stderrLimit {
				stderr = append(stderr, raw...)
			}
		}
		if err != nil {
			cmdErr = errSessionClosed
			break
		}
	}
	output.commandErr <- commandErr{stderr: bytes.TrimSuffix(stderr, []byte("\n")), err: cmdErr}
}

// trimMarker strips a trailing marker from raw, reporting whether it was found.
func trimMarker(raw, marker []byte) ([]byte, bool) {
	if bytes.HasSuffix(raw, marker) {
		return raw[:len(raw)-len(marker)], true
	}
	return raw, false
}

// drainPendingOutputs fails any commands that were queued but never processed.
func drainPendingOutputs(outputs chan *commandOutput) {
	for {
		select {
		case pending := <-outputs:
			close(pending.commandStdout)
			pending.commandErr <- commandErr{err: errSessionClosed}
		default:
			return
		}
	}
}
