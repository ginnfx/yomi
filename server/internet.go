package main

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"errors"
	"net"
	"net/http"
	"time"

	"golang.org/x/crypto/x509roots/fallback/bundle"
)

const (
	dnsTimeout      = 5 * time.Second
	internetTimeout = 30 * time.Second
)

// The server phone has no /etc/resolv.conf, so Go can't find a DNS server by itself.
var publicDNSServers = []string{"1.1.1.1:53", "8.8.8.8:53"}

// newInternetClient returns a client that works on the server phone: its own DNS, and a
// current root store, because Android 4.4's certificates date from 2017. Go only uses
// fallback roots when the system has none, so these are set explicitly.
func newInternetClient() (*http.Client, error) {
	roots, err := embeddedRoots()
	if err != nil {
		return nil, err
	}
	dialer := &net.Dialer{Timeout: dnsTimeout, Resolver: publicResolver()}
	transport := &http.Transport{
		DialContext:         dialer.DialContext,
		TLSClientConfig:     &tls.Config{RootCAs: roots, MinVersion: tls.VersionTLS12},
		TLSHandshakeTimeout: 15 * time.Second,
		IdleConnTimeout:     30 * time.Second,
		MaxIdleConns:        2,
	}
	return &http.Client{Transport: transport, Timeout: internetTimeout}, nil
}

func embeddedRoots() (*x509.CertPool, error) {
	pool := x509.NewCertPool()
	count := 0
	for root := range bundle.Roots() {
		if root.Constraint != nil {
			continue // Roots limited by date or name need checks a plain pool can't apply.
		}
		cert, err := x509.ParseCertificate(root.Certificate)
		if err != nil {
			return nil, err
		}
		pool.AddCert(cert)
		count++
	}
	if count == 0 {
		return nil, errors.New("embedded root store is empty")
	}
	return pool, nil
}

func publicResolver() *net.Resolver {
	return &net.Resolver{
		PreferGo: true,
		Dial: func(ctx context.Context, network, _ string) (net.Conn, error) {
			dialer := net.Dialer{Timeout: dnsTimeout}
			var lastErr error
			for _, server := range publicDNSServers {
				conn, err := dialer.DialContext(ctx, network, server)
				if err == nil {
					return conn, nil
				}
				lastErr = err
			}
			return nil, lastErr
		},
	}
}
