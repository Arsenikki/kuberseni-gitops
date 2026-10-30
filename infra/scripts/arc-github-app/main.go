// Command arc-github-app creates the GitHub App that Actions Runner Controller
// (ARC) authenticates with, installs it, and stores its credentials in 1Password —
// with the private key never leaving this machine.
//
// GitHub has no API for creating an App outright; the closest is the App Manifest
// flow, which still needs one click in the browser. This helper drives that flow:
//
//  1. It serves a local page that POSTs a pre-filled manifest to GitHub
//     (private App, webhook off, Administration read/write + Metadata read: the
//     permissions ARC needs to register repository-level runners).
//  2. You review it and click "Create GitHub App". GitHub redirects back here with
//     a one-time code, which is exchanged for the App's id and private key; both go
//     straight into a 1Password item (op CLI).
//  3. You're sent to the App's install page: pick the repositories that should get
//     self-hosted runners. GitHub redirects back with the installation id, which is
//     added to the same item.
//
// The 1Password item then has the three fields ARC's secret needs —
// github_app_id, github_app_installation_id, github_app_private_key — and the
// ExternalSecret in cluster/apps/arc/runners picks them up.
//
// Run it (needs the op CLI signed in to the account with the homelab vault, and a
// browser on the same machine):
//
//	cd infra/scripts/arc-github-app && mise exec go@1.26.4 -- go run .
package main

import (
	"bytes"
	"context"
	"crypto"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"errors"
	"flag"
	"fmt"
	"html/template"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

type config struct {
	name  string
	vault string
	item  string
	port  int
	repos string
	dry   bool
	api   string // GitHub API base, overridable for tests
	web   string // GitHub web base, overridable for tests
	op    string // op CLI binary
}

func main() {
	var c config
	flag.StringVar(&c.name, "name", "arsenikki-arc-runners", "GitHub App name (globally unique; editable on GitHub's page too)")
	flag.StringVar(&c.vault, "vault", "homelab", "1Password vault")
	flag.StringVar(&c.item, "item", "arc-github-app", "1Password item to create")
	flag.IntVar(&c.port, "port", 8971, "local port for GitHub's redirects")
	flag.StringVar(&c.repos, "repos", "jeeves,paseo-homelab,resepti,flock,coachi,captain-core", "repositories to select on the install page (shown as a reminder)")
	flag.BoolVar(&c.dry, "dry-run", false, "print the manifest and exit")
	flag.StringVar(&c.op, "op", "op", "1Password CLI binary")
	flag.Parse()
	c.api, c.web = "https://api.github.com", "https://github.com"

	if c.dry {
		b, _ := json.MarshalIndent(manifest(c, fmt.Sprintf("http://127.0.0.1:%d", c.port)), "", "  ")
		fmt.Println(string(b))
		return
	}
	if err := run(context.Background(), c); err != nil {
		fmt.Fprintln(os.Stderr, "error:", err)
		os.Exit(1)
	}
}

// manifest is the GitHub App manifest: private, no webhook, and only the
// permissions ARC needs for repository-level runner scale sets.
func manifest(c config, base string) map[string]any {
	return map[string]any{
		"name":            c.name,
		"url":             "https://github.com/Arsenikki/kuberseni-gitops",
		"description":     "Actions Runner Controller in the homelab cluster: registers ephemeral self-hosted runners.",
		"public":          false,
		"redirect_url":    base + "/created",
		"setup_url":       base + "/installed",
		"setup_on_update": false,
		"hook_attributes": map[string]any{"url": "https://example.invalid/unused", "active": false},
		"default_permissions": map[string]string{
			"administration": "write", // register/remove self-hosted runners on a repository
			"metadata":       "read",
		},
		"default_events": []string{},
	}
}

func run(ctx context.Context, c config) error {
	if out, err := exec.CommandContext(ctx, c.op, "whoami").CombinedOutput(); err != nil {
		return fmt.Errorf("1Password CLI not signed in (op whoami: %s) — run `op signin` first", strings.TrimSpace(string(out)))
	}
	if err := exec.CommandContext(ctx, c.op, "item", "get", c.item, "--vault", c.vault).Run(); err == nil {
		return fmt.Errorf("1Password item %q already exists in vault %q — delete or rename it (-item) first", c.item, c.vault)
	}

	ln, err := net.Listen("tcp", fmt.Sprintf("127.0.0.1:%d", c.port))
	if err != nil {
		return fmt.Errorf("listen on port %d: %w", c.port, err)
	}
	// 127.0.0.1, not localhost: the listener is IPv4-only and some browsers try ::1 first.
	base := fmt.Sprintf("http://127.0.0.1:%d", c.port)
	f := newFlow(c, base)
	srv := &http.Server{Handler: f.mux(), ReadHeaderTimeout: 10 * time.Second}
	go func() { _ = srv.Serve(ln) }()
	defer srv.Close()

	fmt.Printf("Opening %s — review the pre-filled App on GitHub and click \"Create GitHub App\".\n", base)
	fmt.Println("(If no browser opens, visit that URL yourself.)")
	openBrowser(base)

	select {
	case err := <-f.done:
		if err == nil {
			fmt.Printf("\nDone. 1Password item %q (vault %q) has github_app_id, github_app_installation_id and github_app_private_key.\n", c.item, c.vault)
		}
		return err
	case <-time.After(60 * time.Minute): // the manifest code is only valid for an hour anyway
		return errors.New("timed out after 60 minutes")
	}
}

type flow struct {
	c     config
	base  string
	state string
	done  chan error
	hc    *http.Client
	page  *template.Template

	mu  sync.Mutex
	app conversion // set once /created stored the App; its key stays in memory only
}

func newFlow(c config, base string) *flow {
	b := make([]byte, 16)
	_, _ = rand.Read(b)
	return &flow{
		c: c, base: base, state: hex.EncodeToString(b), done: make(chan error, 1),
		hc:   &http.Client{Timeout: 30 * time.Second},
		page: template.Must(template.New("p").Parse(pageHTML)),
	}
}

func (f *flow) mux() http.Handler {
	m := http.NewServeMux()
	m.HandleFunc("/", f.start)
	m.HandleFunc("/created", f.created)
	m.HandleFunc("/installed", f.installed)
	host := strings.TrimPrefix(f.base, "http://")
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// Only our own origin: blocks DNS-rebinding pages from reading / (and the state).
		if r.Host != host {
			http.Error(w, "unexpected Host", http.StatusMisdirectedRequest)
			return
		}
		m.ServeHTTP(w, r)
	})
}

func (f *flow) finish(err error) {
	select {
	case f.done <- err:
	default:
	}
}

// start serves a page that POSTs the manifest to GitHub (the flow requires a form POST).
func (f *flow) start(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path != "/" {
		http.NotFound(w, r)
		return
	}
	mj, _ := json.Marshal(manifest(f.c, f.base))
	_ = f.page.Execute(w, map[string]any{
		"Action":   fmt.Sprintf("%s/settings/apps/new?state=%s", f.c.web, f.state),
		"Manifest": string(mj),
	})
}

type conversion struct {
	ID      int64  `json:"id"`
	Slug    string `json:"slug"`
	PEM     string `json:"pem"`
	HTMLURL string `json:"html_url"`
}

// created exchanges the one-time code for the App's credentials and stores them.
func (f *flow) created(w http.ResponseWriter, r *http.Request) {
	if r.URL.Query().Get("state") != f.state {
		http.Error(w, "state mismatch — start again from "+f.base, http.StatusBadRequest)
		return
	}
	code := r.URL.Query().Get("code")
	if code == "" {
		http.Error(w, "missing code", http.StatusBadRequest)
		return
	}
	conv, err := f.convert(r.Context(), code)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadGateway)
		f.finish(err)
		return
	}
	if err := f.store(r.Context(), conv); err != nil {
		// The code is single-use: don't lose the key. Park it in a 0600 file.
		path, werr := savePEM(conv)
		msg := fmt.Sprintf("storing in 1Password failed: %v", err)
		if werr == nil {
			msg += fmt.Sprintf(" — the private key was saved to %s (App id %d); add it to 1Password by hand and delete the file", path, conv.ID)
		}
		http.Error(w, msg, http.StatusInternalServerError)
		f.finish(errors.New(msg))
		return
	}
	f.mu.Lock()
	f.app = conv
	f.mu.Unlock()
	fmt.Printf("Created App %q (id %d) and stored its key in 1Password.\n", conv.Slug, conv.ID)
	fmt.Printf("Now install it — select ONLY these repositories: %s\n", f.c.repos)
	http.Redirect(w, r, fmt.Sprintf("%s/apps/%s/installations/new", f.c.web, conv.Slug), http.StatusFound)
}

func (f *flow) convert(ctx context.Context, code string) (conversion, error) {
	req, _ := http.NewRequestWithContext(ctx, http.MethodPost, f.c.api+"/app-manifests/"+code+"/conversions", nil)
	req.Header.Set("Accept", "application/vnd.github+json")
	resp, err := f.hc.Do(req)
	if err != nil {
		return conversion{}, fmt.Errorf("manifest conversion: %w", err)
	}
	defer resp.Body.Close()
	var conv conversion
	if resp.StatusCode != http.StatusCreated {
		var e struct{ Message string }
		_ = json.NewDecoder(resp.Body).Decode(&e)
		return conv, fmt.Errorf("manifest conversion: HTTP %d %s", resp.StatusCode, e.Message)
	}
	if err := json.NewDecoder(resp.Body).Decode(&conv); err != nil {
		return conv, fmt.Errorf("decode conversion: %w", err)
	}
	if conv.ID == 0 || conv.PEM == "" || conv.Slug == "" {
		return conv, errors.New("conversion response lacks id/slug/pem")
	}
	return conv, nil
}

// store creates the 1Password item. The template goes through a 0600 temp file
// that is removed right after (op reads templates from a file).
func (f *flow) store(ctx context.Context, conv conversion) error {
	tpl := map[string]any{
		"title":    f.c.item,
		"category": "SECURE_NOTE",
		"fields": []map[string]string{
			{"id": "github_app_id", "label": "github_app_id", "type": "STRING", "value": fmt.Sprint(conv.ID)},
			{"id": "github_app_slug", "label": "github_app_slug", "type": "STRING", "value": conv.Slug},
			{"id": "github_app_private_key", "label": "github_app_private_key", "type": "CONCEALED", "value": conv.PEM},
			{"id": "notesPlain", "label": "notesPlain", "type": "STRING", "purpose": "NOTES",
				"value": "GitHub App for Actions Runner Controller (kuberseni-gitops cluster/apps/arc-runners). Created by infra/scripts/arc-github-app. " + conv.HTMLURL},
		},
	}
	dir, err := os.MkdirTemp("", "arc-app-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(dir)
	path := filepath.Join(dir, "item.json")
	b, _ := json.Marshal(tpl)
	if err := os.WriteFile(path, b, 0o600); err != nil {
		return err
	}
	out, err := exec.CommandContext(ctx, f.c.op, "item", "create", "--vault", f.c.vault, "--template", path).CombinedOutput()
	if err != nil {
		return fmt.Errorf("op item create: %v: %s", err, bytes.TrimSpace(out))
	}
	return nil
}

func savePEM(conv conversion) (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	path := filepath.Join(home, fmt.Sprintf("%s.%d.private-key.pem", conv.Slug, conv.ID))
	return path, os.WriteFile(path, []byte(conv.PEM), 0o600)
}

// installed runs when GitHub redirects to the setup URL after the install. It
// doesn't trust the query string (any page in the browser could hit this local
// URL): it requires that /created succeeded in this run, then asks GitHub — as the
// App, with a JWT signed by the key it just received — for the installation, and
// refuses unless it is limited to exactly the expected repositories. The key is
// repo-admin on whatever the installation covers; an "All repositories" install
// would include the public GitOps repo that ArgoCD applies with cluster-admin.
func (f *flow) installed(w http.ResponseWriter, r *http.Request) {
	f.mu.Lock()
	app := f.app
	f.mu.Unlock()
	if app.ID == 0 {
		http.Error(w, "the App hasn't been created in this run yet — start from "+f.base, http.StatusConflict)
		return
	}
	inst, err := f.checkInstallation(r.Context(), app)
	if err != nil {
		w.WriteHeader(http.StatusConflict)
		fmt.Fprintf(w, "<p>%s</p><p>Fix it on GitHub (Settings → Applications → %s → Configure), then <b>reload this page</b>.</p>",
			template.HTMLEscapeString(err.Error()), template.HTMLEscapeString(app.Slug))
		fmt.Println("Installation not accepted yet:", err)
		return
	}
	id := strconv.FormatInt(inst, 10)
	out, err := exec.CommandContext(r.Context(), f.c.op, "item", "edit", f.c.item, "--vault", f.c.vault,
		"github_app_installation_id[text]="+id).CombinedOutput()
	if err != nil {
		msg := fmt.Sprintf("installed (installation id %s), but updating 1Password failed: %v: %s — add field github_app_installation_id=%s by hand", id, err, bytes.TrimSpace(out), id)
		http.Error(w, msg, http.StatusInternalServerError)
		f.finish(errors.New(msg))
		return
	}
	fmt.Printf("Installed on %s (installation id %s) and stored it in 1Password.\n", f.c.repos, id)
	fmt.Fprintf(w, "<p>All set: the App is installed on exactly the expected repositories and 1Password item <b>%s</b> is complete. You can close this tab.</p>", template.HTMLEscapeString(f.c.item))
	f.finish(nil)
}

// checkInstallation returns the App's single installation id after verifying it is
// limited to exactly f.c.repos.
func (f *flow) checkInstallation(ctx context.Context, app conversion) (int64, error) {
	jwt, err := appJWT(app.ID, app.PEM, time.Now())
	if err != nil {
		return 0, err
	}
	var insts []struct {
		ID                  int64  `json:"id"`
		RepositorySelection string `json:"repository_selection"`
		Account             struct {
			Login string `json:"login"`
		} `json:"account"`
	}
	if err := f.api(ctx, http.MethodGet, "/app/installations", "Bearer "+jwt, &insts); err != nil {
		return 0, err
	}
	if len(insts) != 1 {
		return 0, fmt.Errorf("expected exactly one installation of the App, found %d", len(insts))
	}
	inst := insts[0]
	if inst.RepositorySelection != "selected" {
		return 0, fmt.Errorf("the installation covers %q repositories — choose \"Only select repositories\" and pick %s", inst.RepositorySelection, f.c.repos)
	}
	var tok struct {
		Token string `json:"token"`
	}
	if err := f.api(ctx, http.MethodPost, fmt.Sprintf("/app/installations/%d/access_tokens", inst.ID), "Bearer "+jwt, &tok); err != nil {
		return 0, err
	}
	var list struct {
		Repositories []struct {
			Name string `json:"name"`
		} `json:"repositories"`
	}
	if err := f.api(ctx, http.MethodGet, "/installation/repositories?per_page=100", "token "+tok.Token, &list); err != nil {
		return 0, err
	}
	got := map[string]bool{}
	for _, r := range list.Repositories {
		got[r.Name] = true
	}
	want := map[string]bool{}
	var missing, extra []string
	for _, r := range strings.Split(f.c.repos, ",") {
		if r = strings.TrimSpace(r); r != "" {
			want[r] = true
			if !got[r] {
				missing = append(missing, r)
			}
		}
	}
	for r := range got {
		if !want[r] {
			extra = append(extra, r)
		}
	}
	if len(missing)+len(extra) > 0 {
		sort.Strings(extra)
		return 0, fmt.Errorf("the installation's repositories don't match: missing %v, unexpected %v (want exactly %s)", missing, extra, f.c.repos)
	}
	return inst.ID, nil
}

// api calls the GitHub REST API and decodes a 2xx JSON response into out.
func (f *flow) api(ctx context.Context, method, path, auth string, out any) error {
	req, _ := http.NewRequestWithContext(ctx, method, f.c.api+path, nil)
	req.Header.Set("Accept", "application/vnd.github+json")
	req.Header.Set("Authorization", auth)
	resp, err := f.hc.Do(req)
	if err != nil {
		return fmt.Errorf("%s %s: %w", method, path, err)
	}
	defer resp.Body.Close()
	if resp.StatusCode/100 != 2 {
		return fmt.Errorf("%s %s: HTTP %d", method, path, resp.StatusCode)
	}
	return json.NewDecoder(resp.Body).Decode(out)
}

// appJWT signs a GitHub App JWT (RS256, valid ~9 minutes, backdated 60s for clock
// skew) with the App's private key.
func appJWT(appID int64, keyPEM string, now time.Time) (string, error) {
	block, _ := pem.Decode([]byte(keyPEM))
	if block == nil {
		return "", errors.New("App private key is not PEM")
	}
	var key *rsa.PrivateKey
	if k, err := x509.ParsePKCS1PrivateKey(block.Bytes); err == nil {
		key = k
	} else if k8, err8 := x509.ParsePKCS8PrivateKey(block.Bytes); err8 == nil {
		rk, ok := k8.(*rsa.PrivateKey)
		if !ok {
			return "", errors.New("App private key is not RSA")
		}
		key = rk
	} else {
		return "", fmt.Errorf("parse App private key: %w", err)
	}
	enc := base64.RawURLEncoding
	header := enc.EncodeToString([]byte(`{"alg":"RS256","typ":"JWT"}`))
	claims, _ := json.Marshal(map[string]any{"iat": now.Add(-60 * time.Second).Unix(), "exp": now.Add(9 * time.Minute).Unix(), "iss": strconv.FormatInt(appID, 10)})
	signing := header + "." + enc.EncodeToString(claims)
	sum := sha256.Sum256([]byte(signing))
	sig, err := rsa.SignPKCS1v15(rand.Reader, key, crypto.SHA256, sum[:])
	if err != nil {
		return "", fmt.Errorf("sign JWT: %w", err)
	}
	return signing + "." + enc.EncodeToString(sig), nil
}

func openBrowser(url string) {
	for _, cmd := range [][]string{{"open", url}, {"xdg-open", url}} {
		if err := exec.Command(cmd[0], cmd[1:]...).Start(); err == nil {
			return
		}
	}
}

const pageHTML = `<!doctype html>
<html><body>
<p>Sending the pre-filled GitHub App manifest to GitHub…</p>
<form id="f" method="post" action="{{.Action}}">
<input type="hidden" name="manifest" value="{{.Manifest}}">
<noscript><button type="submit">Continue to GitHub</button></noscript>
</form>
<script>document.getElementById("f").submit()</script>
</body></html>`
