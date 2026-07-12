package targets

import (
	"math/rand/v2"
	"net"
	"testing"

	"tavazon/internal/config"
	"tavazon/internal/geoip"
)

func mustCIDR(t *testing.T, s string) net.IPNet {
	t.Helper()
	_, n, err := net.ParseCIDR(s)
	if err != nil {
		t.Fatalf("bad CIDR %q: %v", s, err)
	}
	return *n
}

func testGeoIP(t *testing.T) *geoip.GeoIP {
	return geoip.NewForTest(
		map[uint32][]net.IPNet{
			100: {mustCIDR(t, "5.1.0.0/16")},
			200: {mustCIDR(t, "2.144.0.0/16"), mustCIDR(t, "37.32.0.0/19")},
			300: {mustCIDR(t, "8.8.8.0/24")},
		},
		map[uint32]string{100: "IR", 200: "IR", 300: "US"},
	)
}

func testCfg() config.TargetsConfig {
	return config.TargetsConfig{PortMin: 1024, PortMax: 65535}
}

func TestNewEmptySelection(t *testing.T) {
	tg, skipped, err := New(testGeoIP(t), nil, testCfg(), rand.New(rand.NewPCG(1, 2)))
	if err != nil {
		t.Fatalf("New with no ASNs should not error: %v", err)
	}
	if len(skipped) != 0 {
		t.Errorf("skipped = %v, want empty", skipped)
	}
	if !tg.Empty() {
		t.Error("Targets with no ASNs should be Empty")
	}
}

func TestNewSkipsUnknownASN(t *testing.T) {
	tg, skipped, err := New(testGeoIP(t), []uint32{100, 999}, testCfg(), rand.New(rand.NewPCG(1, 2)))
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	if len(skipped) != 1 || skipped[0] != 999 {
		t.Errorf("skipped = %v, want [999]", skipped)
	}
	if tg.Empty() {
		t.Error("Targets should not be Empty: ASN 100 resolved")
	}
}

func TestNewAllUnknownErrors(t *testing.T) {
	if _, _, err := New(testGeoIP(t), []uint32{999, 998}, testCfg(), rand.New(rand.NewPCG(1, 2))); err == nil {
		t.Fatal("New should error when no selected ASN resolves")
	}
}

func TestEnsureSelectionRebuildsLive(t *testing.T) {
	g := testGeoIP(t)
	cfg := testCfg()
	// Start idle: no ASNs selected.
	tg, _, err := New(g, nil, cfg, rand.New(rand.NewPCG(1, 2)))
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	if !tg.Empty() {
		t.Fatal("Targets should start Empty with no selection")
	}

	// Selecting ASN 100 live must make it resolve without a rebuild via New.
	tg.EnsureSelection([]uint32{100}, cfg)
	if tg.Empty() {
		t.Fatal("EnsureSelection([100]) should populate the pool")
	}
	for i := 0; i < 200; i++ {
		if _, _, asn := tg.RandomTarget(); asn != 100 {
			t.Fatalf("RandomTarget asn = %d, want 100", asn)
		}
	}

	// Switching the selection swaps the pool in place.
	tg.EnsureSelection([]uint32{300}, cfg)
	for i := 0; i < 200; i++ {
		if _, _, asn := tg.RandomTarget(); asn != 300 {
			t.Fatalf("after switch, RandomTarget asn = %d, want 300", asn)
		}
	}

	// Clearing the selection returns to idle.
	tg.EnsureSelection(nil, cfg)
	if !tg.Empty() {
		t.Fatal("EnsureSelection(nil) should empty the pool")
	}

	// An all-unknown selection also yields an idle pool (no panic, no targets).
	tg.EnsureSelection([]uint32{999}, cfg)
	if !tg.Empty() {
		t.Fatal("EnsureSelection([999]) should stay Empty: unknown ASN")
	}
}

func TestEnsureSelectionNilGeoIPStaysEmpty(t *testing.T) {
	tg, _, err := New(nil, nil, testCfg(), rand.New(rand.NewPCG(1, 2)))
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	tg.EnsureSelection([]uint32{100}, testCfg())
	if !tg.Empty() {
		t.Error("with nil GeoIP the pool must stay Empty even after selection")
	}
}

func TestRandomTargetCoverageAndBounds(t *testing.T) {
	g := testGeoIP(t)
	prefixes := map[uint32][]net.IPNet{
		100: g.Prefixes(100),
		200: g.Prefixes(200),
		300: g.Prefixes(300),
	}
	cfg := testCfg()
	tg, _, err := New(g, []uint32{100, 200, 300}, cfg, rand.New(rand.NewPCG(42, 7)))
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	seen := map[uint32]bool{}
	for i := 0; i < 10000; i++ {
		ip, port, asn := tg.RandomTarget()
		seen[asn] = true
		if port < cfg.PortMin || port > cfg.PortMax {
			t.Fatalf("port %d outside [%d,%d]", port, cfg.PortMin, cfg.PortMax)
		}
		inside := false
		for _, p := range prefixes[asn] {
			if p.Contains(ip) {
				inside = true
				break
			}
		}
		if !inside {
			t.Fatalf("IP %v is not inside any prefix of ASN %d", ip, asn)
		}
	}
	for _, asn := range []uint32{100, 200, 300} {
		if !seen[asn] {
			t.Errorf("ASN %d was never selected over 10000 draws", asn)
		}
	}
}
