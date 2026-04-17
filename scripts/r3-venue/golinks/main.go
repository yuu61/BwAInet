// Package main serves CSV-backed short links for the venue network.
package main

import (
	"context"
	"encoding/csv"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"os"
	"os/signal"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
)

// Defaults and operational knobs for the redirect server.
const (
	defaultRootRedirect = "https://gdgkwansai.connpass.com/event/381901/"
	defaultCSVPath      = "/etc/golinks/golinks.csv"
	defaultAddr         = ":80"
	reloadInterval      = 2 * time.Second
	minRecordColumns    = 2
	readHeaderTimeout   = 5 * time.Second
	readTimeout         = 10 * time.Second
	writeTimeout        = 10 * time.Second
	idleTimeout         = 60 * time.Second
	shutdownTimeout     = 10 * time.Second
	maxKeyLength        = 128
)

// redirectTable maps normalized short-link keys to absolute http(s) targets.
type redirectTable map[string]string

// redirectStore holds an atomically swappable redirectTable for lock-free lookups.
type redirectStore struct {
	current atomic.Pointer[redirectTable]
}

// server is the http.Handler that resolves short-link keys against a redirectStore.
type server struct {
	rootRedirect string
	store        *redirectStore
}

// loadCSV reads and validates a CSV file, returning only entries with absolute http/https targets.
// Rows with unsupported schemes or malformed values are skipped and logged.
func loadCSV(path string) (redirectTable, error) {
	//nolint:gosec // The CSV path is an operator-controlled flag or watched file path.
	file, err := os.Open(path)
	if err != nil {
		return nil, fmt.Errorf("open csv %q: %w", path, err)
	}

	defer func() {
		if closeErr := file.Close(); closeErr != nil {
			log.Printf("close csv %q: %v", path, closeErr)
		}
	}()

	reader := csv.NewReader(file)
	reader.FieldsPerRecord = -1
	reader.Comment = '#'
	reader.TrimLeadingSpace = true

	entries := redirectTable{}

	for {
		rec, err := reader.Read()
		if errors.Is(err, io.EOF) {
			return entries, nil
		}

		if err != nil {
			return nil, fmt.Errorf("read csv %q: %w", path, err)
		}

		if len(rec) < minRecordColumns {
			continue
		}

		key := normalizeCSVKey(rec[0])
		target, ok := normalizeTarget(rec[1])
		if key == "" {
			continue
		}

		if !ok {
			if strings.TrimSpace(rec[1]) != "" {
				log.Printf("skip %q: invalid or disallowed target %q", key, rec[1])
			}

			continue
		}

		entries[key] = target
	}
}

// normalizeCSVKey trims whitespace and surrounding slashes from a CSV key column.
func normalizeCSVKey(raw string) string {
	return strings.Trim(strings.TrimSpace(raw), "/")
}

// normalizeRequestKey strips surrounding slashes from a request URL path.
// HTTP paths from net/http are already whitespace-free.
func normalizeRequestKey(raw string) string {
	return strings.Trim(raw, "/")
}

// normalizeTarget validates a CSV target and returns an absolute http or https URL.
// Scheme-less values like "host:port" are prepended with http://. Values that look
// like a scheme-prefixed URL (e.g. "javascript:...", "data:...") but are not http/https
// are rejected to prevent open-redirect abuse.
func normalizeTarget(raw string) (string, bool) {
	target := strings.TrimSpace(raw)
	if target == "" {
		return "", false
	}

	if !strings.Contains(target, "://") {
		if colon := strings.IndexByte(target, ':'); colon > 0 && isSchemePrefix(target[:colon]) {
			return "", false
		}

		target = "http://" + target
	}

	parsed, err := url.Parse(target)
	if err != nil || !parsed.IsAbs() || parsed.Host == "" {
		return "", false
	}

	if parsed.Scheme != "http" && parsed.Scheme != "https" {
		return "", false
	}

	return target, true
}

// isSchemePrefix reports whether s consists only of ASCII letters, i.e. looks like
// the scheme portion of a URI per RFC 3986 (simplified: scheme must start with a letter,
// and for our detection purposes an all-letter prefix before a colon is sufficient).
func isSchemePrefix(s string) bool {
	if s == "" {
		return false
	}

	for _, c := range s {
		if (c < 'a' || c > 'z') && (c < 'A' || c > 'Z') {
			return false
		}
	}

	return true
}

// reload replaces the current redirect table with a fresh read of path.
func (s *redirectStore) reload(path string) error {
	entries, err := loadCSV(path)
	if err != nil {
		return err
	}

	s.current.Store(&entries)

	log.Printf("loaded %d entries from %s", len(entries), path)

	return nil
}

// lookup returns the target for key, or ok=false if not found or the store is empty.
func (s *redirectStore) lookup(key string) (string, bool) {
	entries := s.current.Load()
	if entries == nil {
		return "", false
	}

	target, ok := (*entries)[key]

	return target, ok
}

// watch polls path on interval and reloads when the modification time changes.
// It returns when ctx is cancelled. initialModTime seeds the last-seen mtime
// to avoid redundant reloads right after main's initial load.
func (s *redirectStore) watch(ctx context.Context, path string, interval time.Duration, initialModTime time.Time) {
	defer func() {
		if r := recover(); r != nil {
			log.Printf("watch panic recovered: %v", r)
		}
	}()

	ticker := time.NewTicker(interval)
	defer ticker.Stop()

	last := initialModTime

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}

		fileInfo, err := os.Stat(path)
		if err != nil {
			log.Printf("stat csv %q: %v", path, err)

			continue
		}

		if fileInfo.ModTime().Equal(last) {
			continue
		}

		last = fileInfo.ModTime()

		if reloadErr := s.reload(path); reloadErr != nil {
			log.Printf("reload failed: %v", reloadErr)
		}
	}
}

func (srv *server) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	key := normalizeRequestKey(r.URL.Path)
	if key == "" {
		http.Redirect(w, r, srv.rootRedirect, http.StatusFound)

		return
	}

	if len(key) > maxKeyLength {
		http.NotFound(w, r)

		return
	}

	target, ok := srv.store.lookup(key)
	if ok {
		http.Redirect(w, r, target, http.StatusFound)

		return
	}

	http.NotFound(w, r)
}

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	if err := run(ctx, os.Args[1:]); err != nil {
		log.Fatal(err)
	}
}

func run(ctx context.Context, args []string) error {
	fs := flag.NewFlagSet("golinks", flag.ContinueOnError)
	csvPath := fs.String("csv", defaultCSVPath, "path to CSV file containing short-link mappings")
	addr := fs.String("addr", defaultAddr, "HTTP listen address (host:port)")
	rootURL := fs.String("root", defaultRootRedirect, "redirect destination for requests to /")

	if err := fs.Parse(args); err != nil {
		return err
	}

	rootTarget, ok := normalizeTarget(*rootURL)
	if !ok {
		return fmt.Errorf("invalid -root URL: %q", *rootURL)
	}

	store := &redirectStore{}
	if err := store.reload(*csvPath); err != nil {
		return fmt.Errorf("initial reload: %w", err)
	}

	var initialModTime time.Time
	if fileInfo, err := os.Stat(*csvPath); err == nil {
		initialModTime = fileInfo.ModTime()
	}

	watchCtx, watchCancel := context.WithCancel(ctx)
	defer watchCancel()

	var wg sync.WaitGroup

	wg.Go(func() {
		store.watch(watchCtx, *csvPath, reloadInterval, initialModTime)
	})

	httpServer := &http.Server{
		Addr:              *addr,
		Handler:           &server{rootRedirect: rootTarget, store: store},
		ReadHeaderTimeout: readHeaderTimeout,
		ReadTimeout:       readTimeout,
		WriteTimeout:      writeTimeout,
		IdleTimeout:       idleTimeout,
	}

	serverErr := make(chan error, 1)

	go func() {
		log.Printf("listening on %s, csv=%s", *addr, *csvPath)

		serverErr <- httpServer.ListenAndServe()
	}()

	var runErr error

	select {
	case err := <-serverErr:
		if !errors.Is(err, http.ErrServerClosed) {
			runErr = fmt.Errorf("listen: %w", err)
		}
	case <-ctx.Done():
		log.Printf("shutdown signal received")

		shutdownCtx, cancel := context.WithTimeout(context.Background(), shutdownTimeout)
		defer cancel()

		if err := httpServer.Shutdown(shutdownCtx); err != nil {
			log.Printf("shutdown: %v", err)
		}

		<-serverErr
	}

	watchCancel()
	wg.Wait()

	return runErr
}
