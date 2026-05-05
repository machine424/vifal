package main

import (
	"container/heap"
	"sync"
)

const maxExecSessions = 64

// execSessionPool caps the number of concurrent exec sessions and evicts
// the least recently used one when the limit is reached.
type execSessionPool struct {
	mu    sync.Mutex
	heap  sessionHeap
	limit int
}

var sessions = newExecSessionPool(maxExecSessions)

func newExecSessionPool(limit int) *execSessionPool {
	return &execSessionPool{limit: limit}
}

// Add registers a session in the pool. If the pool is full, the least
// recently used session is evicted to make room.
func (p *execSessionPool) add(s *execSession) {
	p.mu.Lock()
	if len(p.heap) >= p.limit {
		victim := heap.Pop(&p.heap).(*execSession)
		go victim.close()
	}
	heap.Push(&p.heap, s)
	p.mu.Unlock()
}

// Remove unregisters a session from the pool.
// Safe to call on sessions already evicted or not in the pool.
func (p *execSessionPool) remove(s *execSession) {
	p.mu.Lock()
	if p.inHeap(s) {
		heap.Remove(&p.heap, s.heapIdx)
	}
	p.mu.Unlock()
}

// Touch updates the session's last-used time and reorders the heap.
func (p *execSessionPool) touch(s *execSession) {
	s.touch()
	p.mu.Lock()
	if p.inHeap(s) {
		heap.Fix(&p.heap, s.heapIdx)
	}
	p.mu.Unlock()
}

// inHeap reports whether s is currently tracked in the heap.
// The session may have been concurrently evicted or removed by another
// goroutine, so we verify the index is valid and still points to this session.
// Must be called with p.mu held.
func (p *execSessionPool) inHeap(s *execSession) bool {
	return s.heapIdx >= 0 && s.heapIdx < len(p.heap) && p.heap[s.heapIdx] == s
}

// sessionHeap is a min-heap of sessions ordered by lastUsed.
// The root is the least recently used session (eviction candidate).
// Implements heap.Interface.
type sessionHeap []*execSession

func (h sessionHeap) Len() int           { return len(h) }
func (h sessionHeap) Less(i, j int) bool { return h[i].lastUsed.Load() < h[j].lastUsed.Load() }

func (h sessionHeap) Swap(i, j int) {
	h[i], h[j] = h[j], h[i]
	h[i].heapIdx = i
	h[j].heapIdx = j
}

func (h *sessionHeap) Push(x any) {
	s := x.(*execSession)
	s.heapIdx = len(*h)
	*h = append(*h, s)
}

func (h *sessionHeap) Pop() any {
	old := *h
	s := old[len(old)-1]
	old[len(old)-1] = nil
	*h = old[:len(old)-1]
	s.heapIdx = -1
	return s
}
