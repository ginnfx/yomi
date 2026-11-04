package bridge

import (
	"bytes"
	"context"
	"crypto/rand"
	"errors"
	"io"
	"net"
	"testing"
	"time"
)

func startEchoServer(t *testing.T) net.Listener {
	t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { listener.Close() })
	go func() {
		for {
			conn, err := listener.Accept()
			if err != nil {
				return
			}
			go func() {
				defer conn.Close()
				io.Copy(conn, conn)
			}()
		}
	}()
	return listener
}

func startForward(t *testing.T, dial dialFunc) string {
	t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { listener.Close() })
	go serve(listener, dial)
	return listener.Addr().String()
}

func TestForwardCarriesLargeTransfersBothWays(t *testing.T) {
	upstream := startEchoServer(t)
	address := startForward(t, func(ctx context.Context) (net.Conn, error) {
		var dialer net.Dialer
		return dialer.DialContext(ctx, "tcp", upstream.Addr().String())
	})
	conn, err := net.Dial("tcp", address)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	payload := make([]byte, 8<<20)
	rand.Read(payload)
	go func() {
		conn.Write(payload)
		conn.(*net.TCPConn).CloseWrite()
	}()
	conn.SetDeadline(time.Now().Add(20 * time.Second))
	received, err := io.ReadAll(conn)
	if err != nil && !errors.Is(err, net.ErrClosed) {
		t.Fatal(err)
	}
	if !bytes.Equal(received, payload) {
		t.Fatalf("received %d of %d bytes intact", len(received), len(payload))
	}
}

func TestForwardHandlesManyConnectionsAtOnce(t *testing.T) {
	upstream := startEchoServer(t)
	address := startForward(t, func(ctx context.Context) (net.Conn, error) {
		var dialer net.Dialer
		return dialer.DialContext(ctx, "tcp", upstream.Addr().String())
	})
	results := make(chan error, 8)
	for range 8 {
		go func() {
			conn, err := net.Dial("tcp", address)
			if err != nil {
				results <- err
				return
			}
			defer conn.Close()
			conn.SetDeadline(time.Now().Add(10 * time.Second))
			conn.Write([]byte("seek"))
			reply := make([]byte, 4)
			_, err = io.ReadFull(conn, reply)
			results <- err
		}()
	}
	for range 8 {
		if err := <-results; err != nil {
			t.Fatal(err)
		}
	}
}

func TestDeadUpstreamClosesTheLocalConnection(t *testing.T) {
	address := startForward(t, func(context.Context) (net.Conn, error) {
		return nil, errors.New("server is off")
	})
	conn, err := net.Dial("tcp", address)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	conn.SetDeadline(time.Now().Add(5 * time.Second))
	if _, err := conn.Read(make([]byte, 1)); err == nil {
		t.Fatal("expected the connection to close")
	}
}

func TestForwardBeforeStartFails(t *testing.T) {
	if _, err := Forward("100.1.2.3:4533"); err == nil {
		t.Fatal("expected an error while not connected")
	}
}

func TestParseInterfaces(t *testing.T) {
	report := "wlan0,3,1500,um,192.168.1.5/24;fe80::1/64\nlo,1,65536,ul,127.0.0.1/8\nbroken line\nbad,x,1,u,1.2.3.4/32"
	parsed := parseInterfaces(report)
	if len(parsed) != 2 {
		t.Fatalf("parsed %d interfaces", len(parsed))
	}
	wlan := parsed[0]
	if wlan.Name != "wlan0" || wlan.Index != 3 || wlan.MTU != 1500 || len(wlan.AltAddrs) != 2 {
		t.Fatalf("wlan = %+v", wlan)
	}
	if wlan.Flags&net.FlagUp == 0 || wlan.Flags&net.FlagMulticast == 0 || wlan.Flags&net.FlagLoopback != 0 {
		t.Fatalf("flags = %v", wlan.Flags)
	}
}

func TestInviteCodeShape(t *testing.T) {
	if !IsInviteCode(" tskey-auth-abc ") || IsInviteCode("hello") {
		t.Fatal("wrong result")
	}
}
