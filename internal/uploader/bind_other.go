//go:build !linux

package uploader

import (
	"context"
	"fmt"
	"net"
	"runtime"
)

// openUDP opens an ephemeral unconnected UDP socket. Binding egress to a specific
// interface relies on SO_BINDTODEVICE, which only exists on Linux (see
// bind_linux.go). On other platforms a configured interface is unsupported: rather
// than silently egress via the host's default route — which would misroute the
// manufactured traffic — we return an error. With no interface configured the
// socket opens normally.
func openUDP(ctx context.Context, iface string) (net.PacketConn, error) {
	if iface != "" {
		return nil, fmt.Errorf("binding egress to interface %q is not supported on %s", iface, runtime.GOOS)
	}
	var lc net.ListenConfig
	return lc.ListenPacket(ctx, "udp", ":0")
}
