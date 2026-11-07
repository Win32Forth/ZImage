package httpapi

import (
	"sync"
	"time"
)

// limiter allows 30 failed authentications per minute per IP, then five minutes of silence.
type limiter struct {
	mu   sync.Mutex
	byIP map[string]*ipWindow
}

type ipWindow struct {
	fails []time.Time
	quiet time.Time
}

func (l *limiter) silenced(ip string, now time.Time) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	w := l.byIP[ip]
	if w == nil {
		return false
	}
	return now.Before(w.quiet)
}

func (l *limiter) fail(ip string, now time.Time) {
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.byIP == nil {
		l.byIP = map[string]*ipWindow{}
	}
	w := l.byIP[ip]
	if w == nil {
		w = &ipWindow{}
		l.byIP[ip] = w
	}
	cutoff := now.Add(-time.Minute)
	kept := w.fails[:0]
	for _, ts := range w.fails {
		if ts.After(cutoff) {
			kept = append(kept, ts)
		}
	}
	w.fails = append(kept, now)
	if len(w.fails) >= 30 {
		w.quiet = now.Add(5 * time.Minute)
	}
}
