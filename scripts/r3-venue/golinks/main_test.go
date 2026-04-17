package main

import (
	"context"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"testing/synctest"
	"time"
)

const testRootRedirect = "https://example.test/root/"

func TestLoadCSVNormalizesKeysAndTargets(t *testing.T) {
	t.Parallel()

	path := filepath.Join(t.TempDir(), "golinks.csv")

	content := "# comment\n /grafana/ , 192.168.30.3:3000 \nfoo,https://example.com\nignored-only-one-column\n"

	if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
		t.Fatalf("write csv: %v", err)
	}

	got, err := loadCSV(path)
	if err != nil {
		t.Fatalf("load csv: %v", err)
	}

	if got["grafana"] != "http://192.168.30.3:3000" {
		t.Fatalf("grafana redirect = %q", got["grafana"])
	}

	if got["foo"] != "https://example.com" {
		t.Fatalf("foo redirect = %q", got["foo"])
	}

	if _, ok := got["ignored-only-one-column"]; ok {
		t.Fatal("unexpected entry from invalid row")
	}
}

func TestLoadCSVRejectsDangerousSchemes(t *testing.T) {
	t.Parallel()

	path := filepath.Join(t.TempDir(), "golinks.csv")

	content := "js,javascript:alert(1)\ndata,data:text/html,hi\nfile,file:///etc/passwd\nftp,ftp://example.com\nok,https://example.com\n"

	if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
		t.Fatalf("write csv: %v", err)
	}

	got, err := loadCSV(path)
	if err != nil {
		t.Fatalf("load csv: %v", err)
	}

	for _, key := range []string{"js", "data", "file", "ftp"} {
		if target, ok := got[key]; ok {
			t.Errorf("dangerous scheme kept: %s -> %s", key, target)
		}
	}

	if got["ok"] != "https://example.com" {
		t.Fatalf("ok redirect = %q", got["ok"])
	}
}

func TestLoadCSVSkipsEmptyKeyOrTarget(t *testing.T) {
	t.Parallel()

	path := filepath.Join(t.TempDir(), "golinks.csv")

	content := ",https://missing-key.example\nnotarget,\n ,  \nok,https://example.com\n"

	if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
		t.Fatalf("write csv: %v", err)
	}

	got, err := loadCSV(path)
	if err != nil {
		t.Fatalf("load csv: %v", err)
	}

	if len(got) != 1 {
		t.Fatalf("expected 1 entry, got %d: %v", len(got), got)
	}

	if got["ok"] != "https://example.com" {
		t.Fatalf("ok redirect = %q", got["ok"])
	}
}

func TestLoadCSVEmptyFile(t *testing.T) {
	t.Parallel()

	path := filepath.Join(t.TempDir(), "empty.csv")

	if err := os.WriteFile(path, []byte(""), 0o600); err != nil {
		t.Fatalf("write csv: %v", err)
	}

	got, err := loadCSV(path)
	if err != nil {
		t.Fatalf("load csv: %v", err)
	}

	if len(got) != 0 {
		t.Fatalf("expected empty, got %d entries", len(got))
	}
}

func TestLoadCSVMissingFile(t *testing.T) {
	t.Parallel()

	missing := filepath.Join(t.TempDir(), "does-not-exist.csv")

	_, err := loadCSV(missing)
	if err == nil {
		t.Fatal("expected error for missing file")
	}

	if !strings.Contains(err.Error(), missing) {
		t.Fatalf("error should reference path: %v", err)
	}
}

func TestLoadCSVReturnsParseErrors(t *testing.T) {
	t.Parallel()

	path := filepath.Join(t.TempDir(), "broken.csv")

	if err := os.WriteFile(path, []byte("\"broken,target\n"), 0o600); err != nil {
		t.Fatalf("write csv: %v", err)
	}

	if _, err := loadCSV(path); err == nil {
		t.Fatal("expected parse error")
	}
}

func TestNormalizeCSVKey(t *testing.T) {
	t.Parallel()

	cases := []struct {
		in   string
		want string
	}{
		{"", ""},
		{"/", ""},
		{"///", ""},
		{"foo", "foo"},
		{"/foo", "foo"},
		{"foo/", "foo"},
		{"/foo/", "foo"},
		{"  /foo/  ", "foo"},
		{"foo/bar", "foo/bar"},
	}

	for _, c := range cases {
		if got := normalizeCSVKey(c.in); got != c.want {
			t.Errorf("normalizeCSVKey(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}

func TestNormalizeRequestKey(t *testing.T) {
	t.Parallel()

	cases := []struct {
		in   string
		want string
	}{
		{"/", ""},
		{"/foo", "foo"},
		{"/foo/", "foo"},
		{"/foo/bar", "foo/bar"},
		{"", ""},
	}

	for _, c := range cases {
		if got := normalizeRequestKey(c.in); got != c.want {
			t.Errorf("normalizeRequestKey(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}

func TestNormalizeTarget(t *testing.T) {
	t.Parallel()

	cases := []struct {
		in        string
		wantValue string
		wantOK    bool
	}{
		{"", "", false},
		{"   ", "", false},
		{"example.com", "http://example.com", true},
		{"192.168.1.1", "http://192.168.1.1", true},
		{"192.168.1.1:8080", "http://192.168.1.1:8080", true},
		{"http://example.com", "http://example.com", true},
		{"https://example.com/path", "https://example.com/path", true},
		{"  https://example.com  ", "https://example.com", true},
		{"javascript:alert(1)", "", false},
		{"data:text/html,x", "", false},
		{"file:///etc/passwd", "", false},
		{"ftp://example.com", "", false},
		{"mailto:x@example.com", "", false},
		{"https://", "", false},
	}

	for _, c := range cases {
		got, ok := normalizeTarget(c.in)
		if ok != c.wantOK || got != c.wantValue {
			t.Errorf("normalizeTarget(%q) = (%q, %v), want (%q, %v)", c.in, got, ok, c.wantValue, c.wantOK)
		}
	}
}

func TestRedirectStoreLookupBeforeLoad(t *testing.T) {
	t.Parallel()

	store := &redirectStore{}
	if got, ok := store.lookup("anything"); ok || got != "" {
		t.Fatalf("lookup on empty store = (%q, %v), want (\"\", false)", got, ok)
	}
}

func TestRedirectStoreReloadReplacesEntries(t *testing.T) {
	t.Parallel()

	path := filepath.Join(t.TempDir(), "golinks.csv")

	if err := os.WriteFile(path, []byte("a,https://a.example\n"), 0o600); err != nil {
		t.Fatalf("write: %v", err)
	}

	store := &redirectStore{}
	if err := store.reload(path); err != nil {
		t.Fatalf("reload 1: %v", err)
	}

	if got, ok := store.lookup("a"); !ok || got != "https://a.example" {
		t.Fatalf("first reload lookup = (%q, %v)", got, ok)
	}

	if err := os.WriteFile(path, []byte("b,https://b.example\n"), 0o600); err != nil {
		t.Fatalf("write2: %v", err)
	}

	if err := store.reload(path); err != nil {
		t.Fatalf("reload 2: %v", err)
	}

	if _, ok := store.lookup("a"); ok {
		t.Fatal("expected a to be removed after second reload")
	}

	if got, ok := store.lookup("b"); !ok || got != "https://b.example" {
		t.Fatalf("second reload lookup = (%q, %v)", got, ok)
	}
}

func TestRedirectStoreWatchReloadsOnChange(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		path := filepath.Join(t.TempDir(), "golinks.csv")

		if err := os.WriteFile(path, []byte("a,https://a.example\n"), 0o600); err != nil {
			t.Fatalf("write: %v", err)
		}

		store := &redirectStore{}
		if err := store.reload(path); err != nil {
			t.Fatalf("initial reload: %v", err)
		}

		fileInfo, err := os.Stat(path)
		if err != nil {
			t.Fatalf("stat: %v", err)
		}

		ctx, cancel := context.WithCancel(context.Background())
		done := make(chan struct{})

		go func() {
			defer close(done)

			store.watch(ctx, path, 20*time.Millisecond, fileInfo.ModTime())
		}()

		if err := os.WriteFile(path, []byte("a,https://updated.example\n"), 0o600); err != nil {
			t.Fatalf("rewrite: %v", err)
		}

		newTime := fileInfo.ModTime().Add(2 * time.Second)
		if err := os.Chtimes(path, newTime, newTime); err != nil {
			t.Fatalf("chtimes: %v", err)
		}

		time.Sleep(25 * time.Millisecond)
		synctest.Wait()

		if got, ok := store.lookup("a"); !ok || got != "https://updated.example" {
			t.Fatalf("watch did not pick up change; lookup = %q", got)
		}

		cancel()
		<-done
	})
}

func TestRedirectStoreWatchLogsStatError(t *testing.T) {
	t.Parallel()

	missing := filepath.Join(t.TempDir(), "never-created.csv")

	store := &redirectStore{}

	ctx, cancel := context.WithTimeout(context.Background(), 100*time.Millisecond)
	defer cancel()

	done := make(chan struct{})

	go func() {
		defer close(done)

		store.watch(ctx, missing, 20*time.Millisecond, time.Time{})
	}()

	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("watch did not exit on context timeout")
	}

	if _, ok := store.lookup("x"); ok {
		t.Fatal("store should remain empty when file missing")
	}
}

func newTestServer() *server {
	store := &redirectStore{}
	table := redirectTable{
		"grafana": "http://192.168.30.3:3000",
	}
	store.current.Store(&table)

	return &server{
		rootRedirect: testRootRedirect,
		store:        store,
	}
}

func TestServerRedirectsAndNotFound(t *testing.T) {
	t.Parallel()

	srv := newTestServer()

	t.Run("root", func(t *testing.T) {
		t.Parallel()

		req := httptest.NewRequest(http.MethodGet, "/", nil)
		rec := httptest.NewRecorder()

		srv.ServeHTTP(rec, req)

		if rec.Code != http.StatusFound {
			t.Fatalf("status = %d", rec.Code)
		}

		if got := rec.Header().Get("Location"); got != testRootRedirect {
			t.Fatalf("location = %q", got)
		}
	})

	t.Run("known key", func(t *testing.T) {
		t.Parallel()

		req := httptest.NewRequest(http.MethodGet, "/grafana", nil)
		rec := httptest.NewRecorder()

		srv.ServeHTTP(rec, req)

		if rec.Code != http.StatusFound {
			t.Fatalf("status = %d", rec.Code)
		}

		if got := rec.Header().Get("Location"); got != "http://192.168.30.3:3000" {
			t.Fatalf("location = %q", got)
		}
	})

	t.Run("unknown key", func(t *testing.T) {
		t.Parallel()

		req := httptest.NewRequest(http.MethodGet, "/missing", nil)
		rec := httptest.NewRecorder()

		srv.ServeHTTP(rec, req)

		if rec.Code != http.StatusNotFound {
			t.Fatalf("status = %d", rec.Code)
		}
	})

	t.Run("oversized key", func(t *testing.T) {
		t.Parallel()

		long := "/" + strings.Repeat("x", maxKeyLength+1)
		req := httptest.NewRequest(http.MethodGet, long, nil)
		rec := httptest.NewRecorder()

		srv.ServeHTTP(rec, req)

		if rec.Code != http.StatusNotFound {
			t.Fatalf("status = %d", rec.Code)
		}
	})

	t.Run("any method redirects", func(t *testing.T) {
		t.Parallel()

		for _, method := range []string{http.MethodGet, http.MethodHead, http.MethodPost} {
			req := httptest.NewRequest(method, "/grafana", nil)
			rec := httptest.NewRecorder()

			srv.ServeHTTP(rec, req)

			if rec.Code != http.StatusFound {
				t.Fatalf("method %s status = %d", method, rec.Code)
			}
		}
	})
}
