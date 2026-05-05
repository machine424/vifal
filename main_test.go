//go:build !e2e

package main

import (
	"fmt"
	"strings"
	"testing"

	"github.com/stretchr/testify/require"
	"go.uber.org/goleak"
	"golang.org/x/sys/unix"
)

func TestMain(m *testing.M) {
	goleak.VerifyTestMain(m,
		goleak.IgnoreTopFunction("k8s.io/klog/v2.(*loggingT).flushDaemon"),
		goleak.IgnoreTopFunction("k8s.io/klog/v2.(*loggingT).monitorFlush"),
	)
}

// TestDdParams verifies dd block size, skip, and count are computed correctly
// for various buffer size and offset combinations.
func TestDdParams(t *testing.T) {
	tests := []struct {
		bufferSize, offset          int
		wantBs, wantSkip, wantCount int
	}{
		{4096, 0, 4096, 0, 1},
		{1, 0, 1, 0, 1},
		{4096, 4096, 4096, 1, 1},
		{4096, 8192, 4096, 2, 1},
		{4096, 1024, 1024, 1, 4},
		// co-prime => bs=1
		{4096, 37, 1, 37, 4096},
		{7, 11, 1, 11, 7},
		{600, 300, 300, 1, 2},
		{100, 200, 100, 2, 1},
		{1, 1, 1, 1, 1},
		{1, 999, 1, 999, 1},
		// typical FUSE read: 128KB at page boundary
		{131072, 4096, 4096, 1, 32},
	}
	for _, tt := range tests {
		t.Run(fmt.Sprintf("buf=%d_off=%d", tt.bufferSize, tt.offset), func(t *testing.T) {
			bs, skip, count := ddParams(tt.bufferSize, tt.offset)
			require.Equal(t, tt.wantBs, bs)
			require.Equal(t, tt.wantSkip, skip)
			require.Equal(t, tt.wantCount, count)
			require.Equal(t, tt.offset, bs*skip)
			require.Equal(t, tt.bufferSize, bs*count)
		})
	}
}

// statRecord builds a stat record string with \x1d-separated fields.
func statRecord(path, mode, major, minor, blksize, quotedName string) string {
	return strings.Join([]string{
		path, "123", "42", "8", "1000", "2000", "3000",
		mode, "1", "0", "0", major, minor, blksize, quotedName,
	}, delimiter)
}

// TestParseStatRecord verifies stat record parsing for regular files, symlinks,
// and malformed input.
func TestParseStatRecord(t *testing.T) {
	tests := []struct {
		name     string
		record   string
		wantPath string
		wantLink string
		wantRdev uint32
		wantErr  string
	}{
		{
			name:     "regular file",
			record:   statRecord("/etc/hosts", "81a4", "0", "0", "4096", "'/etc/hosts'"),
			wantPath: "/etc/hosts",
		},
		{
			name:     "symlink",
			record:   statRecord("/var/log/syslog", "a1ff", "0", "0", "4096", "'/var/log/syslog' -> '/dev/log'"),
			wantPath: "/var/log/syslog",
			wantLink: "/dev/log",
		},
		{
			name:     "symlink target containing arrow",
			record:   statRecord("/tmp/link", "a1ff", "0", "0", "4096", "'/tmp/link' -> '/tmp/a -> b'"),
			wantPath: "/tmp/link",
			wantLink: "/tmp/a -> b",
		},
		{
			name:     "char device /dev/null (1,3)",
			record:   statRecord("/dev/null", "2066", "1", "3", "4096", "'/dev/null'"),
			wantPath: "/dev/null",
			wantRdev: uint32(unix.Mkdev(1, 3)),
		},
		{
			name:     "char device /dev/zero (1,5)",
			record:   statRecord("/dev/zero", "2066", "1", "5", "4096", "'/dev/zero'"),
			wantPath: "/dev/zero",
			wantRdev: uint32(unix.Mkdev(1, 5)),
		},
		{
			name:    "too few fields",
			record:  "not\x1denough\x1dfields",
			wantErr: "got 3 fields",
		},
		{
			name:    "bad numeric field",
			record:  statRecord("/etc/hosts", "ZZZZ", "0", "0", "4096", "'/etc/hosts'"),
			wantErr: "field",
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			path, ea, err := parseStatRecord(tt.record)
			if tt.wantErr != "" {
				require.ErrorContains(t, err, tt.wantErr)
				return
			}
			require.NoError(t, err)
			require.Equal(t, tt.wantPath, path)
			if tt.wantLink != "" {
				require.Equal(t, []byte(tt.wantLink), ea.symlinkTarget)
			} else {
				require.Nil(t, ea.symlinkTarget)
			}
			if tt.wantRdev != 0 {
				require.Equal(t, tt.wantRdev, ea.Rdev)
			}
		})
	}
}
