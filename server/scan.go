package main

import (
	"context"
	"net/url"
	"sync"
	"time"
)

// scanDebouncer asks for one library scan after uploads have gone quiet, because a scan
// per file would keep the server's CPU busy for the whole of a bulk upload.
type scanDebouncer struct {
	mu    sync.Mutex
	wait  time.Duration
	scan  func(context.Context, url.Values)
	timer *time.Timer
	query url.Values
}

func newScanDebouncer(wait time.Duration, scan func(context.Context, url.Values)) *scanDebouncer {
	return &scanDebouncer{wait: wait, scan: scan}
}

// Touch records an upload, restarting the wait. query carries the latest uploader's
// credentials: startScan is admin-only, so a friend's call fails harmlessly and
// Navidrome's own scheduled scan picks the files up instead.
func (d *scanDebouncer) Touch(query url.Values) {
	if d.scan == nil {
		return
	}
	d.mu.Lock()
	defer d.mu.Unlock()
	d.query = query
	if d.timer != nil {
		d.timer.Stop()
	}
	d.timer = time.AfterFunc(d.wait, d.fire)
}

func (d *scanDebouncer) fire() {
	d.mu.Lock()
	query := d.query
	d.query = nil
	d.mu.Unlock()
	if query == nil {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), scanTimeout)
	defer cancel()
	d.scan(ctx, query)
}
