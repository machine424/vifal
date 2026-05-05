package main

import (
	"io"
	"sync"
	"testing"
	"testing/synctest"
	"time"

	"github.com/stretchr/testify/require"
)

func dummySession() *execSession {
	done := make(chan struct{})
	_, stdinW := io.Pipe()
	stdoutR, _ := io.Pipe()
	stderrR, _ := io.Pipe()
	s := &execSession{
		stdinWriter: stdinW,
		stdoutPipe:  stdoutR,
		stderrPipe:  stderrR,
		done:        done,
		cancel:      func() { close(done) },
		heapIdx:     -1,
	}
	s.touch()
	return s
}

// TestPoolAddRemove verifies a session can be added and removed from the pool.
func TestPoolAddRemove(t *testing.T) {
	p := newExecSessionPool(4)

	s := dummySession()
	p.add(s)
	require.Equal(t, 1, p.heap.Len())
	require.Equal(t, 0, s.heapIdx)

	p.remove(s)
	require.Equal(t, 0, p.heap.Len())
	require.Equal(t, -1, s.heapIdx)
}

// TestPoolTouchReorders verifies that touching a session moves it out of
// the LRU eviction position.
func TestPoolTouchReorders(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		p := newExecSessionPool(4)

		s1 := dummySession()
		s2 := dummySession()
		s3 := dummySession()

		// Sleeps advance the fake clock so each session gets a distinct lastUsed.
		p.add(s1)
		time.Sleep(time.Millisecond)
		p.add(s2)
		time.Sleep(time.Millisecond)
		p.add(s3)

		// heap[0] is the LRU session (eviction candidate).
		require.Equal(t, s1, p.heap[0])

		// Touching s1 updates its lastUsed, so s2 becomes LRU.
		p.touch(s1)
		require.Equal(t, s2, p.heap[0])
	})
}

// TestPoolNoOpOnAbsentSession verifies Remove and Touch are safe on sessions
// that were never added, already removed, or removed twice.
func TestPoolNoOpOnAbsentSession(t *testing.T) {
	p := newExecSessionPool(4)
	s := dummySession()

	// Never added.
	p.remove(s)
	p.touch(s)
	require.Equal(t, 0, p.heap.Len())

	// Add then remove.
	p.add(s)
	p.remove(s)
	require.Equal(t, 0, p.heap.Len())

	// Double remove.
	p.remove(s)
	require.Equal(t, 0, p.heap.Len())

	// Touch after remove.
	p.touch(s)
	require.Equal(t, 0, p.heap.Len())
}

// TestPoolAddEvictsLRU verifies that adding beyond capacity evicts the
// oldest session and closes it.
func TestPoolAddEvictsLRU(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		p := newExecSessionPool(2)

		// Sleep advances the fake clock so s1 is older than s2.
		s1 := dummySession()
		p.add(s1)
		time.Sleep(time.Millisecond)

		s2 := dummySession()
		p.add(s2)

		require.True(t, s1.alive())

		// Pool is full (limit=2). Adding s3 evicts s1 (oldest) via
		// go victim.close() inside add. Wait for that goroutine to finish.
		s3 := dummySession()
		p.add(s3)
		synctest.Wait()

		require.Equal(t, 2, p.heap.Len())
		require.Equal(t, -1, s1.heapIdx)
		require.True(t, s2.heapIdx >= 0)
		require.True(t, s3.heapIdx >= 0)
		require.False(t, s1.alive())
	})
}

// TestPoolEvictsLRUAfterTouch verifies eviction targets the oldest untouched
// session, not the most recently touched one.
func TestPoolEvictsLRUAfterTouch(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		p := newExecSessionPool(3)

		s1 := dummySession()
		s2 := dummySession()
		s3 := dummySession()

		// Sleeps advance the fake clock so each session gets a distinct lastUsed.
		p.add(s1)
		time.Sleep(time.Millisecond)
		p.add(s2)
		time.Sleep(time.Millisecond)
		p.add(s3)

		p.touch(s1)

		// Pool is full (limit=3). Adding s4 evicts the LRU session.
		// s1 was just touched, so s2 (oldest untouched) gets evicted.
		s4 := dummySession()
		p.add(s4)

		require.Equal(t, -1, s2.heapIdx)
		require.True(t, s1.heapIdx >= 0)
		require.True(t, s3.heapIdx >= 0)
		require.Equal(t, 3, p.heap.Len())
	})
}

// TestPoolConcurrent exercises concurrent Add, Touch, and Remove with
// eviction under contention.
func TestPoolConcurrent(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		p := newExecSessionPool(4)

		var wg sync.WaitGroup
		for range maxExecSessions + 1 {
			wg.Add(1)
			go func() {
				defer wg.Done()
				s := dummySession()
				p.add(s)
				p.touch(s)
				time.Sleep(time.Millisecond)
				p.remove(s)
			}()
		}
		wg.Wait()

		require.Equal(t, 0, p.heap.Len())
	})
}
