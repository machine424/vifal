//go:build e2e

package main

import (
	"context"
	"fmt"
	"io"
	"log"
	"os"
	"os/exec"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
	"go.uber.org/goleak"
)

const (
	testPodName       = "test"
	testContainerName = "c"
	testNS            = "vifal-exec-session-test"
)

var testSession *execSession

func TestMain(m *testing.M) {
	os.Exit(testMain(m))
}

func testMain(m *testing.M) int {
	logger = log.New(os.Stdout, "test ", log.LstdFlags)
	initKubeFlags()
	defer kubectl("delete", "namespace", testNS, "--ignore-not-found")

	kubectl("delete", "namespace", testNS, "--ignore-not-found", "--wait=true", "--timeout=120s")
	if err := kubectl(
		"create", "namespace", testNS,
	); err != nil {
		fmt.Fprintf(os.Stderr, "create namespace: %v\n", err)
		return 1
	}
	if err := kubectl(
		"apply", "-f", "testdata/pod.yaml", "-n", testNS,
	); err != nil {
		fmt.Fprintf(os.Stderr, "apply pod: %v\n", err)
		return 1
	}
	if err := kubectl(
		"wait", "--for=condition=Ready", "pod/"+testPodName, "-n", testNS, "--timeout=90s",
	); err != nil {
		fmt.Fprintf(os.Stderr, "wait for pod: %v\n", err)
		return 1
	}

	var err error
	testSession, err = newExecSession(context.Background(), testContainerName, testPodName, testNS)
	if err != nil {
		fmt.Fprintf(os.Stderr, "newExecSession: %v\n", err)
		return 1
	}
	go testSession.forwardOutput()

	code := m.Run()
	testSession.close()

	if err := goleak.Find(
		goleak.IgnoreTopFunction("k8s.io/klog/v2.(*loggingT).flushDaemon"),
		goleak.IgnoreTopFunction("k8s.io/klog/v2.(*loggingT).monitorFlush"),
		goleak.IgnoreTopFunction("k8s.io/client-go/tools/remotecommand.(*heartbeat).start"),
	); err != nil {
		fmt.Fprintf(os.Stderr, "goroutine leak detected after tests:\n%v\n", err)
		if code == 0 {
			code = 1
		}
	}
	return code
}

func kubectl(args ...string) error {
	out, err := exec.Command("kubectl", args...).CombinedOutput()
	if err != nil {
		return fmt.Errorf("kubectl %s: %s: %w", args[0], out, err)
	}
	return nil
}

func newTestSession(t *testing.T) *execSession {
	t.Helper()
	s, err := newExecSession(context.Background(), testContainerName, testPodName, testNS)
	require.NoError(t, err)
	go s.forwardOutput()
	t.Cleanup(func() { s.close() })
	return s
}

func execCmdOn(t *testing.T, s *execSession, cmd string) string {
	t.Helper()
	out, err := s.exec([]byte(cmd))
	require.NoError(t, err)
	var buf []byte
	for line := range out.commandStdout {
		buf = append(buf, line...)
	}
	<-out.commandErr
	return string(buf)
}

func execCmd(t *testing.T, cmd string) string {
	t.Helper()
	return execCmdOn(t, testSession, cmd)
}

func execCmdFull(t *testing.T, cmd string) (stdout, stderr string) {
	t.Helper()
	out, err := testSession.exec([]byte(cmd))
	require.NoError(t, err)
	var buf []byte
	for line := range out.commandStdout {
		buf = append(buf, line...)
	}
	res := <-out.commandErr
	return string(buf), string(res.stderr)
}

// TestExecBasic verifies echo, printf, and file reads return correct output.
func TestExecBasic(t *testing.T) {
	for i := range 5 {
		require.Equal(t, fmt.Sprintf("%d\n", i), execCmd(t, fmt.Sprintf("echo %d", i)))
	}
	require.Empty(t, execCmd(t, "true"))
	require.Equal(t, "a\nb\nc\n", execCmd(t, "printf 'a\\nb\\nc\\n'"))

	require.Equal(t, "test\n", execCmd(t, "cat /etc/hostname"))
	require.Equal(t, "3\n", execCmd(t, "echo $((1+2))"))
}

// TestExecLargeOutput verifies large multi-line output is received without truncation.
func TestExecLargeOutput(t *testing.T) {
	got := execCmd(t, "seq 1 1000")
	var want strings.Builder
	for i := 1; i <= 1000; i++ {
		fmt.Fprintf(&want, "%d\n", i)
	}
	require.Equal(t, want.String(), got)
}

// TestExecStderr verifies stdout and stderr are separated correctly.
func TestExecStderr(t *testing.T) {
	stdout, stderr := execCmdFull(t, "echo out; echo err >&2")
	require.Equal(t, "out\n", stdout)
	require.Equal(t, "err\n", stderr)

	stdout, stderr = execCmdFull(t, "echo line1 >&2; echo line2 >&2; echo line3 >&2")
	require.Empty(t, stdout)
	require.Equal(t, "line1\nline2\nline3\n", stderr)

	// Locale-dependent: assumes English error message from the container.
	stdout, stderr = execCmdFull(t, "ls /nonexistent-path-xxx")
	require.Empty(t, stdout)
	require.Contains(t, stderr, "No such file or directory")
}

// TestExecStderrTruncation sends more than stderrLimit to stderr and verifies
// the session does not hang and stderr is capped.
func TestExecStderrTruncation(t *testing.T) {
	size := stderrLimit * 4
	_, stderr := execCmdFull(t, fmt.Sprintf("head -c %d /dev/urandom | base64 >&2; echo ok", size))
	require.Less(t, len(stderr), size)
	require.Equal(t, "ok\n", execCmd(t, "echo ok"))
}

// TestExecEdgeCases covers whitespace, null bytes, large args, blank lines,
// and outputs without trailing newlines.
func TestExecEdgeCases(t *testing.T) {
	require.Equal(t, "   \n   \n", execCmd(t, "printf '   \\n   \\n'"))
	require.Equal(t, "a\tb\tc\n", execCmd(t, "printf 'a\\tb\\tc\\n'"))

	// 8KB: longer than typical read buffers.
	got := execCmd(t, "head -c 8192 /dev/zero | tr '\\0' 'a'")
	require.Equal(t, strings.Repeat("a", 8192), got)

	require.Equal(t, "no-newline", execCmd(t, "printf 'no-newline'"))
	require.Equal(t, "\n\n\n", execCmd(t, "printf '\\n\\n\\n'"))
	require.Equal(t, "\x00\x00\x00", execCmd(t, "dd if=/dev/zero bs=1 count=3 2> /dev/null"))
	require.Equal(t, "a\\nb\\n\n", execCmd(t, `printf '%s\n' 'a\nb\n'`))

	arg := strings.Repeat("x", 4096)
	require.Equal(t, arg+"\n", execCmd(t, fmt.Sprintf("echo %s", arg)))

	// Blank lines preserved in file content.
	execCmd(t, "printf 'first\\n\\n\\nfourth\\n' > /tmp/blanklines")
	require.Equal(t, "first\n\n\nfourth\n", execCmd(t, "cat /tmp/blanklines"))
	execCmd(t, "printf 'a\\n\\nb\\n\\nc\\n' > /tmp/blankmix")
	require.Equal(t, "a\n\nb\n\nc\n", execCmd(t, "cat /tmp/blankmix"))
	execCmd(t, "rm /tmp/blanklines /tmp/blankmix")
}

// TestExecConcurrent runs multiple goroutines on a shared session with unique
// labels and verifies every command's output is received without mixing or loss.
func TestExecConcurrent(t *testing.T) {
	const goroutines = 10
	const opsPerGoroutine = 4

	ch := make(chan string, goroutines*opsPerGoroutine)
	var wg sync.WaitGroup

	for g := range goroutines {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for j := range opsPerGoroutine {
				want := fmt.Sprintf("g%dj%d", g, j)
				out, err := testSession.exec([]byte(fmt.Sprintf("echo %s", want)))
				if err != nil {
					t.Errorf("goroutine %d op %d: %v", g, j, err)
					return
				}
				var stdout []byte
				for line := range out.commandStdout {
					stdout = append(stdout, line...)
				}
				res := <-out.commandErr
				if res.err != nil {
					t.Errorf("goroutine %d op %d: command: %v", g, j, res.err)
					return
				}
				ch <- string(stdout)
			}
		}()
	}
	wg.Wait()
	close(ch)

	got := make(map[string]bool)
	for s := range ch {
		got[s] = true
	}
	require.Len(t, got, goroutines*opsPerGoroutine)
	require.Equal(t, "ok\n", execCmd(t, "echo ok"))
}

// TestExecClose verifies exec after close returns an error, cancel during
// inflight command doesn't hang, and double close doesn't panic.
func TestExecClose(t *testing.T) {
	// Exec after close.
	s := newTestSession(t)
	s.close()
	require.False(t, s.alive())
	_, err := s.exec([]byte("echo hello"))
	require.Error(t, err)

	// Cancel during inflight command doesn't hang.
	ctx, cancel := context.WithCancel(context.Background())
	s2, err := newExecSession(ctx, testContainerName, testPodName, testNS)
	require.NoError(t, err)
	go s2.forwardOutput()
	t.Cleanup(func() { s2.close() })

	out, err := s2.exec([]byte("sleep 60; echo done"))
	require.NoError(t, err)
	cancel()
	for range out.commandStdout {
	}
	res := <-out.commandErr
	require.ErrorIs(t, res.err, errSessionClosed)

	// Double close doesn't panic.
	s3, err := newExecSession(context.Background(), testContainerName, testPodName, testNS)
	require.NoError(t, err)
	go s3.forwardOutput()
	s3.close()
	s3.close()
}

// TestExecSessionDeath verifies a broken stdin pipe invalidates the session,
// and context cancellation kills it.
func TestExecSessionDeath(t *testing.T) {
	// Stdin write failure.
	_, stdinWriter := io.Pipe()
	stdinWriter.Close()

	done := make(chan struct{})
	ctx, cancel := context.WithCancel(context.Background())
	stdoutPipe, _ := io.Pipe()
	stderrPipe, _ := io.Pipe()
	s := &execSession{
		stdinWriter:   stdinWriter,
		stdoutPipe:    stdoutPipe,
		stderrPipe:    stderrPipe,
		outputs:       make(chan *commandOutput, execSessionQueueSize),
		stdoutOutputs: make(chan *commandOutput, execSessionQueueSize),
		stderrOutputs: make(chan *commandOutput, execSessionQueueSize),
		done:          done,
		cancel:        cancel,
		heapIdx:       -1,
	}
	go func() {
		<-ctx.Done()
		close(done)
	}()

	_, err := s.exec([]byte("echo should-fail"))
	require.ErrorIs(t, err, errSessionClosed)
	require.False(t, s.alive())

	// Context cancel kills session; execErr propagates the cause.
	ctx2, cancel2 := context.WithCancel(context.Background())
	s2, err := newExecSession(ctx2, testContainerName, testPodName, testNS)
	require.NoError(t, err)
	go s2.forwardOutput()

	require.Equal(t, "alive\n", execCmdOn(t, s2, "echo alive"))
	cancel2()
	require.Eventually(t, func() bool { return !s2.alive() }, 5*time.Second, 10*time.Millisecond)

	_, err = s2.exec([]byte("echo should-fail"))
	require.ErrorIs(t, err, errSessionClosed)
	require.NotEqual(t, "session closed", err.Error())
}

// TestExecExitCode verifies non-zero exit codes are reported as errors
// and exit 0 succeeds.
func TestExecExitCode(t *testing.T) {
	codes := []int{0, 1, 2, 42, 127, 128, 255}
	for _, code := range codes {
		t.Run(fmt.Sprintf("exit_%d", code), func(t *testing.T) {
			out, err := testSession.exec([]byte(fmt.Sprintf("(exit %d)", code)))
			require.NoError(t, err)
			for range out.commandStdout {
			}
			res := <-out.commandErr
			if code == 0 {
				require.NoError(t, res.err)
			} else {
				require.ErrorContains(t, res.err, fmt.Sprintf("exit %d", code))
			}
		})
	}
	require.Equal(t, "ok\n", execCmd(t, "echo ok"))
}

// TestExecExitCodeNotBlockedByStdout verifies exit code propagation when
// stdout has a large volume of output.
func TestExecExitCodeNotBlockedByStdout(t *testing.T) {
	out, err := testSession.exec([]byte("seq 1 10000; (exit 1)"))
	require.NoError(t, err)

	for range out.commandStdout {
	}
	res := <-out.commandErr
	require.ErrorContains(t, res.err, "exit 1")
	require.Equal(t, "ok\n", execCmd(t, "echo ok"))
}
