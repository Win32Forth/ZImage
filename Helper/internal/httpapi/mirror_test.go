package httpapi

import (
	"net/http"
	"testing"
)

func TestMirrorDeniesEditsAndKeepsDiscard(t *testing.T) {
	if mirrorDenies(http.MethodGet, "/v1/assets") {
		t.Fatal("a read was refused")
	}
	if mirrorDenies(http.MethodHead, "/v1/health") {
		t.Fatal("a head was refused")
	}
	if mirrorDenies(http.MethodPost, "/v1/folders/rescan") {
		t.Fatal("rescan was refused")
	}
	if mirrorDenies(http.MethodPost, "/v1/folders/rescan-page") {
		t.Fatal("page rescan was refused")
	}
	if mirrorDenies(http.MethodPost, "/v1/focus") {
		t.Fatal("focus was refused")
	}
	if mirrorDenies(http.MethodPost, "/v1/pair/claim") {
		t.Fatal("pairing was refused")
	}
	if mirrorDenies(http.MethodPost, "/v1/assets/abc/to-removed") {
		t.Fatal("discard was refused")
	}
	if !mirrorDenies(http.MethodPost, "/v1/files/rename") {
		t.Fatal("rename was allowed")
	}
	if !mirrorDenies(http.MethodPut, "/v1/edits/abc") {
		t.Fatal("edits were allowed")
	}
	if !mirrorDenies(http.MethodPost, "/v1/reorg/start") {
		t.Fatal("reorg was allowed")
	}
}
