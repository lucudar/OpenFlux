package network

import (
	"encoding/binary"
	"sync"
	"time"
)

// DNSCache caches raw DNS answers keyed by the query (minus its ID), for the
// answer's own TTL. On the phone every uncached lookup is a fresh DNS-over-TLS
// exchange that wakes the radio, so repeat lookups served from memory save
// battery as well as latency.
type DNSCache struct {
	mu  sync.Mutex
	m   map[string]dnsEntry
	max int
}

type dnsEntry struct {
	ans []byte
	exp time.Time
}

const (
	dnsMinTTL      = 10 * time.Second
	dnsMaxTTL      = 10 * time.Minute
	dnsNegativeTTL = 30 * time.Second
)

func NewDNSCache(max int) *DNSCache {
	return &DNSCache{m: make(map[string]dnsEntry), max: max}
}

func dnsKey(query []byte) (string, bool) {
	if len(query) < 12 {
		return "", false
	}
	return string(query[2:]), true
}

// Get returns a cached answer rewritten with the query's ID, or nil.
func (c *DNSCache) Get(query []byte) []byte {
	k, ok := dnsKey(query)
	if !ok {
		return nil
	}
	c.mu.Lock()
	e, ok := c.m[k]
	if ok && time.Now().After(e.exp) {
		delete(c.m, k)
		ok = false
	}
	c.mu.Unlock()
	if !ok {
		return nil
	}
	out := append([]byte(nil), e.ans...)
	copy(out[0:2], query[0:2])
	return out
}

// Put stores ans for query if it is cacheable (see dnsTTL).
func (c *DNSCache) Put(query, ans []byte) {
	k, ok := dnsKey(query)
	if !ok {
		return
	}
	ttl, ok := dnsTTL(ans)
	if !ok {
		return
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if len(c.m) >= c.max {
		now := time.Now()
		for kk, e := range c.m {
			if now.After(e.exp) {
				delete(c.m, kk)
			}
		}
		for kk := range c.m {
			if len(c.m) < c.max {
				break
			}
			delete(c.m, kk)
		}
	}
	c.m[k] = dnsEntry{ans: append([]byte(nil), ans...), exp: time.Now().Add(ttl)}
}

// dnsTTL decides how long an answer may be cached: the smallest TTL of its
// answer records (clamped), a short fixed time for NXDOMAIN / empty answers,
// and not at all for truncated or server-failure responses.
func dnsTTL(ans []byte) (time.Duration, bool) {
	if len(ans) < 12 {
		return 0, false
	}
	flags := binary.BigEndian.Uint16(ans[2:4])
	if flags&0x8000 == 0 || flags&0x0200 != 0 { // not a response, or truncated
		return 0, false
	}
	switch flags & 0x000f {
	case 0: // NOERROR
	case 3: // NXDOMAIN
		return dnsNegativeTTL, true
	default:
		return 0, false
	}
	qd := int(binary.BigEndian.Uint16(ans[4:6]))
	an := int(binary.BigEndian.Uint16(ans[6:8]))
	if an == 0 {
		return dnsNegativeTTL, true
	}
	off := 12
	for i := 0; i < qd; i++ {
		var ok bool
		if off, ok = skipName(ans, off); !ok || off+4 > len(ans) {
			return 0, false
		}
		off += 4
	}
	min := uint32(0xffffffff)
	for i := 0; i < an; i++ {
		var ok bool
		if off, ok = skipName(ans, off); !ok || off+10 > len(ans) {
			return 0, false
		}
		if ttl := binary.BigEndian.Uint32(ans[off+4 : off+8]); ttl < min {
			min = ttl
		}
		off += 10 + int(binary.BigEndian.Uint16(ans[off+8:off+10]))
		if off > len(ans) {
			return 0, false
		}
	}
	d := time.Duration(min) * time.Second
	if d < dnsMinTTL {
		d = dnsMinTTL
	}
	if d > dnsMaxTTL {
		d = dnsMaxTTL
	}
	return d, true
}

// skipName steps over a (possibly compressed) domain name at off.
func skipName(b []byte, off int) (int, bool) {
	for off < len(b) {
		l := int(b[off])
		switch {
		case l == 0:
			return off + 1, true
		case l&0xc0 == 0xc0:
			return off + 2, off+2 <= len(b)
		default:
			off += 1 + l
		}
	}
	return 0, false
}
