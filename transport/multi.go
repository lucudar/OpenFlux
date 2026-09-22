package transport

import (
	"encoding/binary"
	"fmt"
	"hash/fnv"
	"sync"
	"sync/atomic"
	"time"
)

// MultiTransport fans one logical tunnel out over several underlying
// transports (e.g. several Yandex documents). It spreads outgoing packets
// across the healthy sub-transports and merges all inbound packets into one
// stream, which raises throughput (more parallel channels) and resilience (one
// channel storming or reconnecting no longer stalls the tunnel).
//
// Both peers MUST be configured with the SAME ordered set of channels: a packet
// sent on channel i is received by the peer on that same channel. Per-flow
// pinning (see pick) keeps every TCP/UDP flow on one channel so a single flow's
// packets don't get reordered across channels of differing latency; different
// flows spread across channels for aggregate bandwidth.
type MultiTransport struct {
	subs []Transport
	rr   atomic.Uint32

	mu sync.RWMutex
	cb func([]byte)
}

// NewMultiTransport builds a MultiTransport over subs. With a single sub it
// behaves exactly like that sub, so callers can always route through it.
func NewMultiTransport(subs []Transport) *MultiTransport {
	return &MultiTransport{subs: subs}
}

func (m *MultiTransport) Start() error {
	var firstErr error
	for _, s := range m.subs {
		if err := s.Start(); err != nil && firstErr == nil {
			firstErr = err
		}
	}
	return firstErr
}

func (m *MultiTransport) Stop() error {
	for _, s := range m.subs {
		_ = s.Stop()
	}
	return nil
}

// Receive registers cb and wires every sub-transport to deliver into it, so the
// caller sees one merged inbound stream.
func (m *MultiTransport) Receive(cb func([]byte)) {
	m.mu.Lock()
	m.cb = cb
	m.mu.Unlock()
	for _, s := range m.subs {
		s.Receive(func(data []byte) {
			m.mu.RLock()
			c := m.cb
			m.mu.RUnlock()
			if c != nil {
				c(data)
			}
		})
	}
}

func (m *MultiTransport) Send(data []byte) error {
	idx := m.pick(data)
	if idx < 0 {
		return fmt.Errorf("no connected transport (%d channels)", len(m.subs))
	}
	return m.subs[idx].Send(data)
}

// pick selects a channel for this packet: the flow-hashed channel when it is
// connected (keeps a flow pinned), else round-robin over any connected channel,
// else -1 when everything is down.
func (m *MultiTransport) pick(pkt []byte) int {
	n := len(m.subs)
	if n == 0 {
		return -1
	}
	if h, ok := flowHash(pkt); ok {
		idx := int(h % uint32(n))
		if m.subs[idx].IsConnected() {
			return idx
		}
	}
	for i := 0; i < n; i++ {
		idx := int(m.rr.Add(1)) % n
		if m.subs[idx].IsConnected() {
			return idx
		}
	}
	return -1
}

// flowHash derives a direction-independent key from an IPv4 packet's addresses
// and (for TCP/UDP) ports, so both directions of a flow map to the same
// channel. Returns false if the packet is too short or not IPv4.
func flowHash(pkt []byte) (uint32, bool) {
	if len(pkt) < 20 || pkt[0]>>4 != 4 {
		return 0, false
	}
	ihl := int(pkt[0]&0x0f) * 4
	if ihl < 20 || len(pkt) < ihl {
		return 0, false
	}
	src := pkt[12:16]
	dst := pkt[16:20]
	var sp, dp uint16
	proto := pkt[9]
	if (proto == 6 || proto == 17) && len(pkt) >= ihl+4 {
		sp = binary.BigEndian.Uint16(pkt[ihl : ihl+2])
		dp = binary.BigEndian.Uint16(pkt[ihl+2 : ihl+4])
	}
	// Normalise endpoint order so (A->B) and (B->A) hash the same.
	a := uint64(binary.BigEndian.Uint32(src))<<16 | uint64(sp)
	b := uint64(binary.BigEndian.Uint32(dst))<<16 | uint64(dp)
	if a > b {
		a, b = b, a
	}
	h := fnv.New32a()
	var buf [16]byte
	binary.BigEndian.PutUint64(buf[0:8], a)
	binary.BigEndian.PutUint64(buf[8:16], b)
	_, _ = h.Write(buf[:])
	return h.Sum32(), true
}

func (m *MultiTransport) IsConnected() bool {
	for _, s := range m.subs {
		if s.IsConnected() {
			return true
		}
	}
	return false
}

// Stats aggregates byte/packet counters and reports the max uptime across
// channels; Connected is true if any channel is up.
func (m *MultiTransport) Stats() TransportStats {
	var agg TransportStats
	for _, s := range m.subs {
		st := s.Stats()
		agg.BytesSent += st.BytesSent
		agg.BytesReceived += st.BytesReceived
		agg.PacketsSent += st.PacketsSent
		agg.PacketsRecv += st.PacketsRecv
		agg.Reconnects += st.Reconnects
		if st.Connected {
			agg.Connected = true
		}
		if st.Uptime > agg.Uptime {
			agg.Uptime = st.Uptime
		}
	}
	return agg
}

// ConnectedCount reports how many channels are currently up (for diagnostics).
func (m *MultiTransport) ConnectedCount() int {
	n := 0
	for _, s := range m.subs {
		if s.IsConnected() {
			n++
		}
	}
	return n
}

// interface assertion + keep time import used for any future deadline helpers.
var _ Transport = (*MultiTransport)(nil)
var _ = time.Second
