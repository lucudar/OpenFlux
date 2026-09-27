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

	// Per-channel end-to-end liveness (Unix-nanos). A channel whose local
	// WebSocket is "connected" (IsConnected) can still silently drop everything
	// (server stops relaying, "ghost participant" churn) — pinning a flow to it
	// then black-holes that flow while gVisor retransmits forever. We detect that
	// passively, with no wire protocol: lastSent[i] is when we last handed a
	// packet to channel i; unackedSince[i] is when the current run of sends with
	// no intervening inbound began (0 once inbound proves the channel alive). A
	// channel that has been sending for longer than healthWindow with nothing
	// coming back is treated as black-holed. Because both peers run this logic,
	// they independently abandon a dead channel. See blackholed / pick.
	lastSent     []atomic.Int64
	unackedSince []atomic.Int64

	// Flow -> channel learned from inbound (slot = flowHash % len, value =
	// channel+1, 0 = unknown). Replies follow the channel the peer chose for a
	// flow, so the two ends agree even when their channel sets differ (e.g. a
	// single-document client talking to a multi-document exit). Collisions only
	// cost a sub-optimal channel choice, never correctness.
	affinity [affinitySlots]atomic.Uint32

	mu sync.RWMutex
	cb func([]byte)
}

// healthWindow is how long we tolerate "actively sending on a channel but
// hearing nothing back" before treating that channel as black-holed. It also
// sets the cold-start grace (a brand-new channel gets a full window for its
// first reply to arrive) and the recovery probe (once we stop sending on a
// flagged channel its lastSent ages past this window, so it becomes eligible
// again and is retried). A var, not a const, so tests can shrink it.
var healthWindow = 6 * time.Second

const affinitySlots = 4096

// NewMultiTransport builds a MultiTransport over subs. With a single sub it
// behaves exactly like that sub, so callers can always route through it.
func NewMultiTransport(subs []Transport) *MultiTransport {
	return &MultiTransport{
		subs:         subs,
		lastSent:     make([]atomic.Int64, len(subs)),
		unackedSince: make([]atomic.Int64, len(subs)),
	}
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
	for i, s := range m.subs {
		idx := i
		s.Receive(func(data []byte) {
			// Inbound proves this channel is alive end-to-end; clear the streak.
			m.unackedSince[idx].Store(0)
			if len(m.subs) > 1 {
				if h, ok := flowHash(data); ok {
					m.affinity[h%affinitySlots].Store(uint32(idx) + 1)
				}
			}
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
	now := time.Now().UnixNano()
	m.lastSent[idx].Store(now)
	// Begin a new "unacked" streak only if one isn't already running; a live
	// channel clears it on every inbound (see Receive).
	m.unackedSince[idx].CompareAndSwap(0, now)
	return m.subs[idx].Send(data)
}

// blackholed reports whether channel idx looks dead end-to-end: it has been
// sending with no inbound for longer than healthWindow and is still actively
// sending. The cold-start grace (unackedSince starts at first send) gives a new
// channel a full window for its first reply; a channel that goes idle ages out
// via lastSent and is retried; a healthy channel carrying a flow clears the
// streak on its inbound ACKs and never trips.
func (m *MultiTransport) blackholed(idx int) bool {
	us := m.unackedSince[idx].Load()
	if us == 0 {
		return false
	}
	now := time.Now().UnixNano()
	return now-us > int64(healthWindow) && now-m.lastSent[idx].Load() < int64(healthWindow)
}

// healthy is IsConnected plus the end-to-end black-hole check.
func (m *MultiTransport) healthy(idx int) bool {
	return m.subs[idx].IsConnected() && !m.blackholed(idx)
}

// pick selects a channel for this packet. With one channel it degrades to plain
// IsConnected (unchanged single-doc behaviour). With several it prefers the
// channel the peer last used for this flow, then the flow-hashed channel when
// healthy (keeps a flow pinned), else round-robins over
// any healthy channel, else falls back to any merely-connected channel rather
// than dropping the packet, else -1 when everything is down.
func (m *MultiTransport) pick(pkt []byte) int {
	n := len(m.subs)
	if n == 0 {
		return -1
	}
	if n == 1 {
		if m.subs[0].IsConnected() {
			return 0
		}
		return -1
	}
	if h, ok := flowHash(pkt); ok {
		if a := m.affinity[h%affinitySlots].Load(); a != 0 {
			if idx := int(a - 1); idx < n && m.healthy(idx) {
				return idx
			}
		}
		idx := int(h % uint32(n))
		if m.healthy(idx) {
			return idx
		}
	}
	for i := 0; i < n; i++ {
		idx := int(m.rr.Add(1)) % n
		if m.healthy(idx) {
			return idx
		}
	}
	// Nothing looks healthy (e.g. a transient global stall): try anything still
	// connected instead of dropping — better a possibly-slow send than none.
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

// interface assertion.
var _ Transport = (*MultiTransport)(nil)
