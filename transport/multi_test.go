package transport

import (
	"encoding/binary"
	"sync/atomic"
	"testing"
	"time"
)

// fakeSub is a controllable Transport for exercising MultiTransport routing.
type fakeSub struct {
	connected atomic.Bool
	sent      atomic.Int64
	cb        func([]byte)
}

func newFakeSub() *fakeSub {
	f := &fakeSub{}
	f.connected.Store(true)
	return f
}

func (f *fakeSub) Start() error              { return nil }
func (f *fakeSub) Stop() error               { return nil }
func (f *fakeSub) Receive(cb func([]byte))   { f.cb = cb }
func (f *fakeSub) Send(b []byte) error        { f.sent.Add(1); return nil }
func (f *fakeSub) IsConnected() bool          { return f.connected.Load() }
func (f *fakeSub) Stats() TransportStats      { return TransportStats{Connected: f.connected.Load()} }
func (f *fakeSub) deliver(b []byte)           { if f.cb != nil { f.cb(b) } }

// tcpPacket builds a minimal IPv4/TCP packet for a fixed flow so flowHash is
// stable across sends within a test.
func tcpPacket() []byte {
	p := make([]byte, 40)
	p[0] = 0x45 // IPv4, IHL=5
	p[9] = 6    // TCP
	binary.BigEndian.PutUint32(p[12:16], 0x0a0a0a02) // src 10.10.10.2
	binary.BigEndian.PutUint32(p[16:20], 0x01020304) // dst 1.2.3.4
	binary.BigEndian.PutUint16(p[20:22], 12345)      // src port
	binary.BigEndian.PutUint16(p[22:24], 443)        // dst port
	return p
}

func pinnedIndex(n int) int {
	h, _ := flowHash(tcpPacket())
	return int(h % uint32(n))
}

// TestMultiBlackholeReroute verifies a flow moves off its pinned channel once
// that channel is black-holed (sending, nothing coming back), and that a single
// send never trips detection (cold-start grace).
func TestMultiBlackholeReroute(t *testing.T) {
	orig := healthWindow
	healthWindow = 40 * time.Millisecond
	defer func() { healthWindow = orig }()

	a, b := newFakeSub(), newFakeSub()
	m := NewMultiTransport([]Transport{a, b})
	m.Receive(func([]byte) {})

	subs := []*fakeSub{a, b}
	pin := pinnedIndex(2)
	other := 1 - pin
	pkt := tcpPacket()

	// First send goes to the pinned channel and must NOT immediately reroute.
	if err := m.Send(pkt); err != nil {
		t.Fatalf("send: %v", err)
	}
	if subs[pin].sent.Load() != 1 {
		t.Fatalf("first packet not pinned: pin=%d sent=%d", pin, subs[pin].sent.Load())
	}

	// Keep sending with no inbound past the window: channel should black-hole
	// and the flow should reroute to the other channel.
	deadline := time.Now().Add(500 * time.Millisecond)
	for time.Now().Before(deadline) {
		_ = m.Send(pkt)
		if subs[other].sent.Load() > 0 {
			break
		}
		time.Sleep(5 * time.Millisecond)
	}
	if subs[other].sent.Load() == 0 {
		t.Fatalf("flow never rerouted off black-holed channel %d", pin)
	}

	// Inbound on the pinned channel clears the streak; the flow returns to it.
	subs[pin].deliver([]byte{1})
	before := subs[pin].sent.Load()
	_ = m.Send(pkt)
	if subs[pin].sent.Load() != before+1 {
		t.Fatalf("flow did not return to recovered channel %d", pin)
	}
}

// TestMultiSingleSubUnaffected confirms the single-channel path ignores health
// and behaves like the bare sub (prod single-doc behaviour).
func TestMultiSingleSubUnaffected(t *testing.T) {
	orig := healthWindow
	healthWindow = 10 * time.Millisecond
	defer func() { healthWindow = orig }()

	a := newFakeSub()
	m := NewMultiTransport([]Transport{a})
	m.Receive(func([]byte) {})
	pkt := tcpPacket()
	for i := 0; i < 10; i++ {
		if err := m.Send(pkt); err != nil {
			t.Fatalf("send %d: %v", i, err)
		}
		time.Sleep(5 * time.Millisecond)
	}
	if a.sent.Load() != 10 {
		t.Fatalf("single sub should get all 10 sends, got %d", a.sent.Load())
	}
	a.connected.Store(false)
	if err := m.Send(pkt); err == nil {
		t.Fatalf("expected error when only channel is down")
	}
}
