// Package bridge embeds a Tailscale node in the app, so friends can reach the server with
// only an invite code. It needs no VPN permission: the app talks to loopback ports that
// this package forwards across the tailnet.
package bridge

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"strings"
	"sync"
	"time"

	"tailscale.com/ipn"
	"tailscale.com/tsnet"
)

const (
	upTimeout   = 45 * time.Second
	dialTimeout = 15 * time.Second

	logsDirEnv   = "TS_LOGS_DIR"
	stateDirMode = 0o700
)

var (
	mu       sync.Mutex
	node     *tsnet.Server
	forwards []net.Listener
)

// Start joins the tailnet using state in stateDir. authKey is only needed the first
// time: afterwards the saved node key is used, so an expired invite changes nothing.
func Start(stateDir, authKey, hostname string) error {
	mu.Lock()
	defer mu.Unlock()
	if node != nil {
		return nil
	}
	if err := useLogsDir(stateDir); err != nil {
		return fmt.Errorf("could not prepare %s: %w", stateDir, err)
	}
	server := &tsnet.Server{
		Dir:      stateDir,
		AuthKey:  authKey,
		Hostname: hostname,
		Logf:     func(string, ...any) {},
		UserLogf: log.Printf,
	}
	ctx, stop := context.WithTimeout(context.Background(), upTimeout)
	defer stop()
	if _, err := server.Up(ctx); err != nil {
		closeErr := server.Close()
		return errors.Join(fmt.Errorf("could not join: %w", err), closeErr)
	}
	node = server
	return nil
}

// useLogsDir gives Tailscale a folder for its logs. Without one it looks in places an
// Android app doesn't have, then panics, which no caller can catch and closes the app.
func useLogsDir(stateDir string) error {
	if err := os.MkdirAll(stateDir, stateDirMode); err != nil {
		return err
	}
	return os.Setenv(logsDirEnv, stateDir)
}

// Forward opens a loopback port that reaches remote ("host:port") over the tailnet and
// returns the port. Only this device can connect to it.
func Forward(remote string) (int, error) {
	mu.Lock()
	defer mu.Unlock()
	if node == nil {
		return 0, errors.New("not connected")
	}
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return 0, err
	}
	forwards = append(forwards, listener)
	server := node
	go serve(listener, func(ctx context.Context) (net.Conn, error) {
		return server.Dial(ctx, "tcp", remote)
	})
	return listener.Addr().(*net.TCPAddr).Port, nil
}

type dialFunc func(context.Context) (net.Conn, error)

func serve(listener net.Listener, dial dialFunc) {
	for {
		local, err := listener.Accept()
		if err != nil {
			return // Closed by Stop.
		}
		go relay(local, dial)
	}
}

func relay(local net.Conn, dial dialFunc) {
	defer local.Close()
	ctx, stop := context.WithTimeout(context.Background(), dialTimeout)
	defer stop()
	upstream, err := dial(ctx)
	if err != nil {
		log.Printf("tunnel: dial: %v", err)
		return
	}
	defer upstream.Close()
	done := make(chan struct{}, 2)
	copyHalf := func(to, from net.Conn) {
		_, err := io.Copy(to, from)
		closer, canHalfClose := to.(interface{ CloseWrite() error })
		if err == nil && canHalfClose && closer.CloseWrite() == nil {
			// One side finished sending; the reply may still be on its way back.
			done <- struct{}{}
			return
		}
		if err != nil && !errors.Is(err, net.ErrClosed) {
			log.Printf("tunnel: %v", err)
		}
		// A failure on either side ends the connection, so a seek doesn't leave a stream open.
		to.Close()
		from.Close()
		done <- struct{}{}
	}
	go copyHalf(upstream, local)
	go copyHalf(local, upstream)
	<-done
	<-done
}

// NetworkChanged wakes the monitor after a host network change or app resume.
// Android otherwise polls interfaces only once every ten minutes.
func NetworkChanged() {
	mu.Lock()
	defer mu.Unlock()
	if node != nil {
		node.Sys().NetMon.Get().Poll()
	}
}

// State reports the node's Tailscale state, such as "Running" or "NeedsLogin".
func State() string {
	mu.Lock()
	server := node
	mu.Unlock()
	if server == nil {
		return ipn.NoState.String()
	}
	client, err := server.LocalClient()
	if err != nil {
		return ipn.NoState.String()
	}
	ctx, stop := context.WithTimeout(context.Background(), 5*time.Second)
	defer stop()
	status, err := client.StatusWithoutPeers(ctx)
	if err != nil {
		return ipn.NoState.String()
	}
	return status.BackendState
}

// Stop closes the tunnel. Saved state is kept, so Start works again without an invite.
func Stop() error {
	mu.Lock()
	defer mu.Unlock()
	for _, listener := range forwards {
		listener.Close()
	}
	forwards = nil
	if node == nil {
		return nil
	}
	err := node.Close()
	node = nil
	return err
}

// IsInviteCode does a shape check only, to catch paste mistakes before going online.
func IsInviteCode(code string) bool {
	return strings.HasPrefix(strings.TrimSpace(code), "tskey-auth-")
}
