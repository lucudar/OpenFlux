//go:build ios

package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"context"
	"crypto/tls"
	"encoding/binary"
	"io"
	"net"
	"runtime/debug"
	"strconv"
	"sync"
	"time"
	"unsafe"

	"openflux/network"
	"openflux/transport"
	"openflux/transport/mailru"
	"openflux/transport/oneme"
	"openflux/transport/yandex"
	"openflux/utils"
)

// Packet-tunnel (NEPacketTunnelProvider) mode — pure L3 forwarding.
//
// The device is given tunnel address 10.10.10.2, which is exactly what the exit
// node expects (it hardcodes returns to 10.10.10.2). So we forward the device's
// raw IP packets straight over the transport — no gvisor stack on the client,
// which keeps the extension well under its memory cap and preserves full TCP
// throughput end-to-end. Only TCP is forwarded (the exit node is TCP-only);
// DNS (UDP 53) is answered locally over DNS-over-TLS.
//
// Uses startOK / start* codes and dotServers from export_ios.go.

const tunClientIP = "10.10.10.2"

var (
	ptMu        sync.Mutex
	ptOn        bool
	ptTrans     transport.Transport
	ptOutQ      chan []byte
	ptCtx       context.Context
	ptCancel    context.CancelFunc
	ptTunnelUDP bool // forward non-DNS UDP (QUIC) over the transport (needs a UDP-capable exit)
	// ptBatched selects the app-layer codec for the next start: false = legacy
	// per-packet LZ4 (our hand-run exits, --codec=legacy), true = batched zstd
	// (WEB PANEL PROXY exits, --codec=batched). Must match the exit.
	ptBatched bool
)

// OpenFluxSetCodec picks the codec for the next OpenFluxStartPacketTunnel:
// 0 = legacy, 1 = batched. Kept as a separate setter so the start ABI (and the
// Swift call site) stays unchanged.
//
//export OpenFluxSetCodec
func OpenFluxSetCodec(batched C.int) {
	ptMu.Lock()
	ptBatched = batched != 0
	ptMu.Unlock()
}

// wrapCodec applies the selected app-layer codec (see ptBatched). ptMu held.
func wrapCodec(inner transport.Transport) transport.Transport {
	if ptBatched {
		return transport.NewBatchedTransport(inner)
	}
	return transport.NewCompressedTransport(inner)
}

//export OpenFluxStartPacketTunnel
func OpenFluxStartPacketTunnel(transportType, url, maxToken, maxUid *C.char, tunnelUDP C.int) (rc C.int) {
	tt := C.GoString(transportType)
	docURL := C.GoString(url)
	mToken := C.GoString(maxToken)
	mUid := C.GoString(maxUid)

	defer func() {
		if r := recover(); r != nil {
			utils.Debugf("[PKT] Recovered from panic in start: %v", r)
			rc = C.int(startPanic)
		}
	}()

	ptMu.Lock()
	defer ptMu.Unlock()
	if ptOn {
		return C.int(startAlreadyRunning)
	}

	// Keep the extension well under iOS's ~50 MB NE memory cap. Under heavy
	// load (many flows + transport buffers) the extension was being killed by
	// the OS and relaunched ("restarts under load"), so target a tighter heap
	// and GC harder — trading a little CPU for staying alive.
	debug.SetMemoryLimit(32 << 20)
	debug.SetGCPercent(10)

	ptTunnelUDP = tunnelUDP != 0

	config := transport.DefaultConfig()
	var t transport.Transport
	switch tt {
	case "yandex", "":
		// docURL may hold several comma-separated Yandex documents; fan them
		// out into one channel (MultiTransport) for throughput + resilience.
		// Must match the exit node's document set exactly.
		urls := splitDocURLs(docURL)
		subs := make([]transport.Transport, len(urls))
		for i, u := range urls {
			subs[i] = yandex.NewYandexDocsTransport(u, config)
		}
		// Legacy per-packet LZ4 by default: on the 32 MB-capped Network
		// Extension zstd's larger footprint costs more GC pauses than LZ4.
		// Batched only when the profile targets a panel (--codec=batched) exit.
		t = wrapCodec(transport.NewMultiTransport(subs))
	case "oneme":
		uidint, _ := strconv.ParseInt(mUid, 10, 64)
		t = wrapCodec(oneme.NewOneMeTransport(false, mToken, uidint, config))
	case "mailru":
		// Mail.ru Docs (cloud.mail.ru/public/...). The exit must run
		// --transport=mailru with the same documents in the same order and the
		// matching --codec. Several documents: codec per channel, MultiTransport
		// outside (it pins flows by IP header), as in main.go.
		urls := splitDocURLs(docURL)
		if len(urls) == 0 {
			return C.int(startBadTransport)
		}
		if len(urls) == 1 {
			t = wrapCodec(mailru.NewMailruDocsTransport(urls[0], config))
		} else {
			subs := make([]transport.Transport, len(urls))
			for i, u := range urls {
				subs[i] = wrapCodec(mailru.NewMailruDocsTransport(u, config))
			}
			t = transport.NewMultiTransport(subs)
		}
	default:
		return C.int(startBadTransport)
	}

	outQ := make(chan []byte, 1024)
	// Packets coming back from the exit node -> queue for the device.
	t.Receive(func(data []byte) {
		select {
		case outQ <- append([]byte(nil), data...):
		default: // queue full: drop, TCP will retransmit
		}
	})

	if err := t.Start(); err != nil {
		utils.Debugf("[PKT] transport start failed: %v", err)
		return C.int(startTransportError)
	}

	ptTrans = t
	ptOutQ = outQ
	ptCtx, ptCancel = context.WithCancel(context.Background())
	ptOn = true
	utils.Debugf("[PKT] L3 packet tunnel started (transport %s, batched=%v)", tt, ptBatched)
	return C.int(startOK)
}

// OpenFluxTunWritePacket forwards one device IPv4 packet: TCP goes over the
// transport, DNS (UDP 53) is answered locally, other UDP is dropped.
//
//export OpenFluxTunWritePacket
func OpenFluxTunWritePacket(buf *C.char, length C.int) {
	defer func() { _ = recover() }() // never let a bad packet crash the extension
	if buf == nil || length < 20 {
		return
	}
	ptMu.Lock()
	t := ptTrans
	outQ := ptOutQ
	udpOn := ptTunnelUDP
	ptMu.Unlock()
	if t == nil {
		return
	}
	pkt := C.GoBytes(unsafe.Pointer(buf), length)
	if pkt[0]>>4 != 4 { // IPv4 only
		return
	}
	switch pkt[9] { // protocol
	case 6: // TCP
		t.Send(pkt)
	case 17: // UDP
		ihl := int(pkt[0]&0x0f) * 4
		if len(pkt) < ihl+8 {
			return
		}
		dstPort := binary.BigEndian.Uint16(pkt[ihl+2 : ihl+4])
		if dstPort == 53 {
			// DNS is always answered locally over DNS-over-TLS (fast, reliable),
			// regardless of the UDP-tunnel setting. Bound concurrent resolutions
			// so a burst can't spawn an unbounded pile of goroutines + TLS
			// handshakes (memory).
			select {
			case dnsSem <- struct{}{}:
				go func() { defer func() { <-dnsSem }(); handleDNSPacket(pkt, outQ) }()
			default: // too many in flight: drop, the client retries
			}
			return
		}
		if udpOn {
			// Tunnel UDP (e.g. QUIC/UDP:443) as a raw IP packet over the
			// transport. Requires a UDP-capable exit node; the return packets
			// come back through the normal receive path like any IP packet.
			t.Send(pkt)
		} else {
			// UDP tunneling disabled: reply ICMP port-unreachable so apps that
			// try QUIC fall back to TCP immediately instead of stalling. This
			// keeps things working against a TCP-only exit.
			sendICMPPortUnreachable(pkt, outQ)
		}
	}
}

// sendICMPPortUnreachable enqueues an ICMP "destination/port unreachable" for a
// UDP datagram we won't forward, so the sender falls back to TCP fast.
func sendICMPPortUnreachable(orig []byte, outQ chan []byte) {
	ihl := int(orig[0]&0x0f) * 4
	if len(orig) < ihl+8 {
		return
	}
	quote := orig[:ihl+8] // original IP header + 8 bytes (per RFC 792)
	icmp := make([]byte, 8+len(quote))
	icmp[0] = 3 // Destination Unreachable
	icmp[1] = 3 // Port Unreachable
	copy(icmp[8:], quote)
	ck := network.IPChecksum(icmp)
	icmp[2] = byte(ck >> 8)
	icmp[3] = byte(ck & 0xFF)

	total := 20 + len(icmp)
	ip := make([]byte, total)
	ip[0] = 0x45
	binary.BigEndian.PutUint16(ip[2:4], uint16(total))
	ip[8] = 64 // TTL
	ip[9] = 1  // ICMP
	copy(ip[12:16], orig[16:20]) // src = original destination
	copy(ip[16:20], orig[12:16]) // dst = original source (the device)
	ck2 := network.IPChecksum(ip[:20])
	ip[10] = byte(ck2 >> 8)
	ip[11] = byte(ck2 & 0xFF)
	copy(ip[20:], icmp)

	select {
	case outQ <- ip:
	default:
	}
}

// dnsSem caps concurrent DNS-over-TLS resolutions.
var dnsSem = make(chan struct{}, 16)

// OpenFluxTunReadPacket blocks for the next packet destined to the device.
//
//export OpenFluxTunReadPacket
func OpenFluxTunReadPacket(buf *C.char, max C.int) C.int {
	ptMu.Lock()
	outQ := ptOutQ
	ctx := ptCtx
	ptMu.Unlock()
	if outQ == nil || ctx == nil {
		return 0
	}
	select {
	case data := <-outQ:
		n := len(data)
		if n > int(max) {
			n = int(max)
		}
		dst := unsafe.Slice((*byte)(unsafe.Pointer(buf)), int(max))
		copy(dst[:n], data[:n])
		return C.int(n)
	case <-ctx.Done():
		return 0
	}
}

// OpenFluxPacketTunnelConnected reports whether the packet-tunnel transport
// currently has a live connection. Returns 1 when running and the underlying
// transport reports connected, 0 otherwise (stopped, or mid-reconnect).
//
// The NEPacketTunnelProvider extension uses this to (a) confirm a real
// connection before reporting startTunnel success, and (b) detect a dead
// transport so it can tear the tunnel down and let on-demand relaunch it,
// instead of sitting in a "connected but no traffic" zombie state.
//
//export OpenFluxPacketTunnelConnected
func OpenFluxPacketTunnelConnected() C.int {
	ptMu.Lock()
	on := ptOn
	t := ptTrans
	ptMu.Unlock()
	if on && t != nil && t.IsConnected() {
		return C.int(1)
	}
	return C.int(0)
}

//export OpenFluxStopPacketTunnel
func OpenFluxStopPacketTunnel() {
	ptMu.Lock()
	defer ptMu.Unlock()
	if !ptOn {
		return
	}
	if ptCancel != nil {
		ptCancel()
	}
	if ptTrans != nil {
		ptTrans.Stop()
	}
	ptTrans = nil
	ptOutQ = nil
	ptOn = false
	utils.Debugf("[PKT] L3 packet tunnel stopped")
}

// handleDNSPacket answers a device DNS query over DNS-over-TLS and enqueues a
// UDP response packet back to the device.
func handleDNSPacket(req []byte, outQ chan []byte) {
	defer func() { _ = recover() }()
	ihl := int(req[0]&0x0f) * 4
	if len(req) < ihl+8 {
		return
	}
	srcIP := req[12:16]
	dstIP := req[16:20]
	srcPort := req[ihl : ihl+2]
	dstPort := req[ihl+2 : ihl+4]
	query := req[ihl+8:]
	if len(query) == 0 {
		return
	}

	answer, err := dnsOverTLS(query)
	if err != nil || len(answer) == 0 {
		utils.Debugf("[DNS] resolve failed: %v", err)
		return
	}

	// Build the response: swap addresses/ports (dst<->src), UDP checksum 0.
	udpLen := 8 + len(answer)
	total := ihl + udpLen
	resp := make([]byte, total)
	// IP header: copy version/IHL/TOS, set total length, TTL/proto, addresses.
	resp[0] = req[0]
	resp[1] = req[1]
	binary.BigEndian.PutUint16(resp[2:4], uint16(total))
	resp[8] = 64 // TTL
	resp[9] = 17 // UDP
	copy(resp[12:16], dstIP)  // src = original destination (the resolver)
	copy(resp[16:20], srcIP)  // dst = the device
	resp[10], resp[11] = 0, 0 // checksum field
	ipck := network.IPChecksum(resp[:20])
	resp[10] = byte(ipck >> 8)
	resp[11] = byte(ipck & 0xFF)
	// UDP header
	copy(resp[ihl:ihl+2], dstPort)   // src port = 53
	copy(resp[ihl+2:ihl+4], srcPort) // dst port = device's
	binary.BigEndian.PutUint16(resp[ihl+4:ihl+6], uint16(udpLen))
	// checksum 0 (allowed for IPv4 UDP)
	copy(resp[ihl+8:], answer)

	select {
	case outQ <- resp:
	default:
	}
}

// dnsOverTLS sends a DNS query to a DoT resolver (RFC 7858, length-prefixed)
// and returns the raw DNS answer, trying each server in turn.
func dnsOverTLS(query []byte) ([]byte, error) {
	var lastErr error
	for _, s := range dotServers {
		ans, err := dotQueryOne(s, query)
		if err == nil {
			return ans, nil
		}
		lastErr = err
	}
	return nil, lastErr
}

func dotQueryOne(s dotServer, query []byte) ([]byte, error) {
	d := tls.Dialer{
		NetDialer: &net.Dialer{Timeout: 6 * time.Second},
		Config:    &tls.Config{ServerName: s.sni, MinVersion: tls.VersionTLS12},
	}
	conn, err := d.DialContext(context.Background(), "tcp", s.addr)
	if err != nil {
		return nil, err
	}
	defer conn.Close()
	conn.SetDeadline(time.Now().Add(6 * time.Second))

	var lp [2]byte
	binary.BigEndian.PutUint16(lp[:], uint16(len(query)))
	if _, err := conn.Write(append(lp[:], query...)); err != nil {
		return nil, err
	}
	hdr := make([]byte, 2)
	if _, err := io.ReadFull(conn, hdr); err != nil {
		return nil, err
	}
	ans := make([]byte, binary.BigEndian.Uint16(hdr))
	if _, err := io.ReadFull(conn, ans); err != nil {
		return nil, err
	}
	return ans, nil
}
