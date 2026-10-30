package main

import (
	"crypto"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

// fakeOp writes a shell script standing in for the op CLI: it logs argv and, for
// `item create --template F`, copies the template so the test can inspect it.
func fakeOp(t *testing.T, dir string) string {
	p := filepath.Join(dir, "op")
	script := "#!/bin/sh\necho \"$@\" >> " + filepath.Join(dir, "calls") + "\n" +
		"if [ \"$1 $2\" = \"item create\" ]; then for a; do last=$a; done; cp \"$last\" " + filepath.Join(dir, "template.json") + "; fi\n"
	if err := os.WriteFile(p, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	return p
}

// fakeGitHub serves the manifest conversion and the installation endpoints, and
// verifies that App calls carry a JWT signed by the App's key.
type fakeGitHub struct {
	key       *rsa.PrivateKey
	mu        sync.Mutex
	selection string
	repos     []string
}

func (g *fakeGitHub) set(selection string, repos ...string) {
	g.mu.Lock()
	defer g.mu.Unlock()
	g.selection, g.repos = selection, repos
}

func (g *fakeGitHub) jwtOK(r *http.Request) bool {
	tok := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
	parts := strings.Split(tok, ".")
	if len(parts) != 3 {
		return false
	}
	sig, err := base64.RawURLEncoding.DecodeString(parts[2])
	if err != nil {
		return false
	}
	sum := sha256.Sum256([]byte(parts[0] + "." + parts[1]))
	if rsa.VerifyPKCS1v15(&g.key.PublicKey, crypto.SHA256, sum[:], sig) != nil {
		return false
	}
	claims, _ := base64.RawURLEncoding.DecodeString(parts[1])
	var c struct{ Iss string }
	_ = json.Unmarshal(claims, &c)
	return c.Iss == "4242"
}

func (g *fakeGitHub) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	g.mu.Lock()
	defer g.mu.Unlock()
	switch {
	case r.Method == http.MethodPost && r.URL.Path == "/app-manifests/CODE123/conversions":
		pemKey := string(pem.EncodeToMemory(&pem.Block{Type: "RSA " + "PRIVATE KEY", Bytes: x509.MarshalPKCS1PrivateKey(g.key)}))
		w.WriteHeader(http.StatusCreated)
		_ = json.NewEncoder(w).Encode(map[string]any{"id": 4242, "slug": "arsenikki-arc-runners", "pem": pemKey, "html_url": "https://github.com/apps/arsenikki-arc-runners"})
	case r.Method == http.MethodGet && r.URL.Path == "/app/installations":
		if !g.jwtOK(r) {
			http.Error(w, "bad jwt", http.StatusUnauthorized)
			return
		}
		_ = json.NewEncoder(w).Encode([]map[string]any{{"id": 987, "repository_selection": g.selection, "account": map[string]string{"login": "Arsenikki"}}})
	case r.Method == http.MethodPost && r.URL.Path == "/app/installations/987/access_tokens":
		if !g.jwtOK(r) {
			http.Error(w, "bad jwt", http.StatusUnauthorized)
			return
		}
		w.WriteHeader(http.StatusCreated)
		_, _ = io.WriteString(w, `{"token":"ghs_test"}`)
	case r.Method == http.MethodGet && r.URL.Path == "/installation/repositories":
		if r.Header.Get("Authorization") != "token ghs_test" {
			http.Error(w, "bad token", http.StatusUnauthorized)
			return
		}
		var list []map[string]string
		for _, n := range g.repos {
			list = append(list, map[string]string{"name": n})
		}
		_ = json.NewEncoder(w).Encode(map[string]any{"repositories": list})
	default:
		http.Error(w, `{"message":"Not Found"}`, http.StatusNotFound)
	}
}

func TestFlow(t *testing.T) {
	dir := t.TempDir()
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	gh := &fakeGitHub{key: key}
	api := httptest.NewServer(gh)
	defer api.Close()

	// The helper's server, with base == its real address (the Host check uses it).
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	base := "http://" + ln.Addr().String()
	c := config{name: "arsenikki-arc-runners", vault: "homelab", item: "arc-github-app", repos: "jeeves,flock", api: api.URL, web: "https://github.example", op: fakeOp(t, dir)}
	f := newFlow(c, base)
	srv := &httptest.Server{Listener: ln, Config: &http.Server{Handler: f.mux()}}
	srv.Start()
	defer srv.Close()
	noFollow := &http.Client{CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	get := func(path string) (*http.Response, string) {
		t.Helper()
		resp, err := noFollow.Get(base + path)
		if err != nil {
			t.Fatal(err)
		}
		b, _ := io.ReadAll(resp.Body)
		resp.Body.Close()
		return resp, string(b)
	}

	// 0. A request for another Host (DNS rebinding) is refused.
	req, _ := http.NewRequest(http.MethodGet, base+"/", nil)
	req.Host = "evil.example:8971"
	if resp, _ := noFollow.Do(req); resp.StatusCode != http.StatusMisdirectedRequest {
		t.Fatalf("foreign Host: %d", resp.StatusCode)
	}

	// 1. Start page: an auto-submitting form POSTing the manifest to GitHub.
	_, page := get("/")
	if !strings.Contains(page, `action="https://github.example/settings/apps/new?state=`+f.state+`"`) || !strings.Contains(page, `name="manifest"`) {
		t.Fatalf("start page:\n%s", page)
	}
	if !strings.Contains(page, "&#34;administration&#34;:&#34;write&#34;") || !strings.Contains(page, "&#34;public&#34;:false") {
		t.Fatalf("manifest not embedded (escaped) in the form:\n%s", page)
	}

	// 2. /installed before the App exists is refused and doesn't end the flow.
	if resp, _ := get("/installed?installation_id=1"); resp.StatusCode != http.StatusConflict {
		t.Fatalf("early /installed: %d", resp.StatusCode)
	}

	// 3. Wrong state is rejected.
	if resp, _ := get("/created?code=CODE123&state=nope"); resp.StatusCode != http.StatusBadRequest {
		t.Fatalf("bad state: %d", resp.StatusCode)
	}

	// 4. Right state: convert, store, redirect to the install page.
	resp, body := get("/created?code=CODE123&state=" + f.state)
	if resp.StatusCode != http.StatusFound || resp.Header.Get("Location") != "https://github.example/apps/arsenikki-arc-runners/installations/new" {
		t.Fatalf("created: %d %q %s", resp.StatusCode, resp.Header.Get("Location"), body)
	}
	raw, err := os.ReadFile(filepath.Join(dir, "template.json"))
	if err != nil {
		t.Fatal("op item create was not called with a template:", err)
	}
	var tpl struct {
		Title  string
		Fields []map[string]string
	}
	_ = json.Unmarshal(raw, &tpl)
	got := map[string]string{}
	for _, fl := range tpl.Fields {
		got[fl["label"]] = fl["value"]
	}
	if tpl.Title != "arc-github-app" || got["github_app_id"] != "4242" || !strings.Contains(got["github_app_private_key"], "PRIVATE KEY") {
		t.Fatalf("template = %s", raw)
	}

	// 5. An "All repositories" install, or the wrong repo set, is refused; the
	//    flow stays open so a reload after fixing it on GitHub succeeds.
	gh.set("all", "jeeves", "flock", "kuberseni-gitops")
	if resp, body := get("/installed?installation_id=987"); resp.StatusCode != http.StatusConflict || !strings.Contains(body, "Only select repositories") {
		t.Fatalf("all-repos install: %d %s", resp.StatusCode, body)
	}
	gh.set("selected", "jeeves", "kuberseni-gitops")
	if resp, body := get("/installed?installation_id=987"); resp.StatusCode != http.StatusConflict || !strings.Contains(body, "missing [flock]") || !strings.Contains(body, "unexpected [kuberseni-gitops]") {
		t.Fatalf("wrong repos: %d %s", resp.StatusCode, body)
	}
	select {
	case err := <-f.done:
		t.Fatalf("flow ended early: %v", err)
	default:
	}

	// 6. Correct install: the id comes from GitHub (not the query) and is stored.
	gh.set("selected", "flock", "jeeves")
	if resp, body := get("/installed?installation_id=1"); resp.StatusCode != http.StatusOK {
		t.Fatalf("installed: %d %s", resp.StatusCode, body)
	}
	select {
	case err := <-f.done:
		if err != nil {
			t.Fatalf("flow error: %v", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("flow did not finish")
	}
	calls, _ := os.ReadFile(filepath.Join(dir, "calls"))
	if !strings.Contains(string(calls), "item create --vault homelab --template") ||
		!strings.Contains(string(calls), "item edit arc-github-app --vault homelab github_app_installation_id[text]=987") {
		t.Fatalf("op calls:\n%s", calls)
	}
	// The temp template (with the key) must be gone.
	for _, line := range strings.Split(string(calls), "\n") {
		if i := strings.Index(line, "--template "); i >= 0 {
			if _, err := os.Stat(strings.TrimSpace(line[i+len("--template "):])); err == nil {
				t.Error("template file with the private key was left behind")
			}
		}
	}
}

func TestAppJWT(t *testing.T) {
	key, _ := rsa.GenerateKey(rand.Reader, 2048)
	pemKey := string(pem.EncodeToMemory(&pem.Block{Type: "RSA " + "PRIVATE KEY", Bytes: x509.MarshalPKCS1PrivateKey(key)}))
	now := time.Unix(1_800_000_000, 0)
	tok, err := appJWT(4242, pemKey, now)
	if err != nil {
		t.Fatal(err)
	}
	parts := strings.Split(tok, ".")
	claims, _ := base64.RawURLEncoding.DecodeString(parts[1])
	if want := fmt.Sprintf(`{"exp":%d,"iat":%d,"iss":"4242"}`, now.Unix()+540, now.Unix()-60); string(claims) != want {
		t.Errorf("claims = %s, want %s", claims, want)
	}
	if _, err := appJWT(1, "not a pem", now); err == nil {
		t.Error("garbage key must fail")
	}
}
