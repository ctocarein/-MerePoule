package deadman

import (
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"
)

func TestPing(t *testing.T) {
	var mu sync.Mutex
	var paths, bodies []string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		b, _ := io.ReadAll(r.Body)
		mu.Lock()
		paths = append(paths, r.URL.Path)
		bodies = append(bodies, string(b))
		mu.Unlock()
	}))
	defer srv.Close()

	ok, detail := true, "43204264 RUN"
	p := New(srv.URL+"/abc/", func() (bool, string) { return ok, detail })
	if err := p.Ping(context.Background()); err != nil {
		t.Fatal(err)
	}
	ok, detail = false, "43204264 : Watchdog muet"
	if err := p.Ping(context.Background()); err != nil {
		t.Fatal(err)
	}
	if paths[0] != "/abc" || paths[1] != "/abc/fail" || bodies[1] != detail {
		t.Fatalf("signaux inattendus : %v %v", paths, bodies)
	}
}
