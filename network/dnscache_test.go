package network

import (
	"encoding/binary"
	"testing"
	"time"
)

// query for example.com A with the given ID.
func testQuery(id uint16) []byte {
	q := []byte{0, 0, 0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 0}
	binary.BigEndian.PutUint16(q[0:2], id)
	q = append(q, 7, 'e', 'x', 'a', 'm', 'p', 'l', 'e', 3, 'c', 'o', 'm', 0, 0, 1, 0, 1)
	return q
}

// answer to testQuery with two A records of the given TTLs.
func testAnswer(id uint16, ttls ...uint32) []byte {
	a := testQuery(id)
	a[2], a[3] = 0x81, 0x80
	binary.BigEndian.PutUint16(a[6:8], uint16(len(ttls)))
	for _, ttl := range ttls {
		rr := []byte{0xc0, 12, 0, 1, 0, 1, 0, 0, 0, 0, 0, 4, 93, 184, 216, 34}
		binary.BigEndian.PutUint32(rr[6:10], ttl)
		a = append(a, rr...)
	}
	return a
}

func TestDNSCacheHitRewritesID(t *testing.T) {
	c := NewDNSCache(8)
	c.Put(testQuery(1), testAnswer(1, 300, 120))
	got := c.Get(testQuery(0xbeef))
	if got == nil {
		t.Fatal("expected a hit")
	}
	if id := binary.BigEndian.Uint16(got[0:2]); id != 0xbeef {
		t.Fatalf("id = %x", id)
	}
	if c.Get(testQuery(1)) == nil {
		t.Fatal("cached entry was consumed")
	}
}

func TestDNSTTL(t *testing.T) {
	if d, ok := dnsTTL(testAnswer(1, 300, 120)); !ok || d != 120*time.Second {
		t.Fatalf("min ttl: %v %v", d, ok)
	}
	if d, _ := dnsTTL(testAnswer(1, 1)); d != dnsMinTTL {
		t.Fatalf("clamp low: %v", d)
	}
	if d, _ := dnsTTL(testAnswer(1, 999999)); d != dnsMaxTTL {
		t.Fatalf("clamp high: %v", d)
	}
	if d, ok := dnsTTL(testAnswer(1)); !ok || d != dnsNegativeTTL {
		t.Fatalf("empty: %v %v", d, ok)
	}
	sf := testAnswer(1, 300)
	sf[3] = 0x82 // SERVFAIL
	if _, ok := dnsTTL(sf); ok {
		t.Fatal("SERVFAIL must not be cached")
	}
	tc := testAnswer(1, 300)
	tc[2] |= 0x02 // truncated
	if _, ok := dnsTTL(tc); ok {
		t.Fatal("truncated must not be cached")
	}
	if _, ok := dnsTTL(testAnswer(1, 300)[:30]); ok {
		t.Fatal("short packet must not be cached")
	}
}

func TestDNSCacheBounded(t *testing.T) {
	c := NewDNSCache(4)
	for i := 0; i < 20; i++ {
		q := testQuery(1)
		q[len(q)-6] = byte(i) // distinct question
		a := testAnswer(1, 300)
		a[len(testQuery(1))-6] = byte(i)
		c.Put(q, a)
	}
	if len(c.m) > 4 {
		t.Fatalf("cache grew to %d", len(c.m))
	}
}
