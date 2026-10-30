package main

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
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

func TestFlow(t *testing.T) {
	dir := t.TempDir()
	api := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost || r.URL.Path != "/app-manifests/CODE123/conversions" {
			http.Error(w, `{"message":"Not Found"}`, http.StatusNotFound)
			return
		}
		w.WriteHeader(http.StatusCreated)
		_, _ = io.WriteString(w, `{"id":4242,"slug":"arsenikki-arc-runners","pem":"-----BEGIN TEST KEY-----\nabc\n-----END TEST KEY-----\n","html_url":"https://github.com/apps/arsenikki-arc-runners"}`)
	}))
	defer api.Close()

	c := config{name: "arsenikki-arc-runners", vault: "homelab", item: "arc-github-app", repos: "jeeves,flock", api: api.URL, web: "https://github.example", op: fakeOp(t, dir)}
	f := newFlow(c, "http://localhost:8971")
	srv := httptest.NewServer(f.mux())
	defer srv.Close()
	noFollow := &http.Client{CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}

	// 1. Start page: an auto-submitting form POSTing the manifest to GitHub.
	resp, _ := noFollow.Get(srv.URL + "/")
	body, _ := io.ReadAll(resp.Body)
	page := string(body)
	if !strings.Contains(page, `action="https://github.example/settings/apps/new?state=`+f.state+`"`) || !strings.Contains(page, `name="manifest"`) {
		t.Fatalf("start page:\n%s", page)
	}
	if !strings.Contains(page, "&#34;administration&#34;:&#34;write&#34;") || !strings.Contains(page, "&#34;public&#34;:false") {
		t.Fatalf("manifest not embedded (escaped) in the form:\n%s", page)
	}

	// 2. Wrong state is rejected.
	resp, _ = noFollow.Get(srv.URL + "/created?code=CODE123&state=nope")
	if resp.StatusCode != http.StatusBadRequest {
		t.Fatalf("bad state: %d", resp.StatusCode)
	}

	// 3. Right state: convert, store, redirect to the install page.
	resp, _ = noFollow.Get(srv.URL + "/created?code=CODE123&state=" + f.state)
	if resp.StatusCode != http.StatusFound || resp.Header.Get("Location") != "https://github.example/apps/arsenikki-arc-runners/installations/new" {
		b, _ := io.ReadAll(resp.Body)
		t.Fatalf("created: %d %q %s", resp.StatusCode, resp.Header.Get("Location"), b)
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
	if tpl.Title != "arc-github-app" || got["github_app_id"] != "4242" || !strings.Contains(got["github_app_private_key"], "BEGIN TEST KEY") {
		t.Fatalf("template = %s", raw)
	}

	// 4. Install callback records the installation id and finishes.
	resp, _ = noFollow.Get(srv.URL + "/installed?installation_id=987&setup_action=install")
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("installed: %d", resp.StatusCode)
	}
	if err := <-f.done; err != nil {
		t.Fatalf("flow error: %v", err)
	}
	calls, _ := os.ReadFile(filepath.Join(dir, "calls"))
	if !strings.Contains(string(calls), "item create --vault homelab --template") ||
		!strings.Contains(string(calls), "item edit arc-github-app --vault homelab github_app_installation_id[text]=987") {
		t.Fatalf("op calls:\n%s", calls)
	}
	// The temp template (with the key) must be gone.
	if strings.Contains(string(calls), "template ") {
		for _, line := range strings.Split(string(calls), "\n") {
			if i := strings.Index(line, "--template "); i >= 0 {
				if _, err := os.Stat(strings.TrimSpace(line[i+len("--template "):])); err == nil {
					t.Error("template file with the private key was left behind")
				}
			}
		}
	}
	// Bad installation ids are rejected.
	resp, _ = noFollow.Get(srv.URL + "/installed?installation_id=1;rm")
	if resp.StatusCode != http.StatusBadRequest {
		t.Errorf("bad installation id accepted: %d", resp.StatusCode)
	}
}
