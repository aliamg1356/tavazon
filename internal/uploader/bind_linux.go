//go:build linux

package uploader

import (
	"context"
	"net"
	"syscall"
)

// openUDP opens an ephemeral unconnected UDP socket. When iface is non-empty the
// socket is bound to that interface with SO_BINDTODEVICE, so manufactured traffic
// egresses and is routed by the chosen interface (an internal NIC or a VPN/TUN)
// instead of the host's default route. The destination must be routable via that
// interface, or the send fails with ENETUNREACH. Binding needs CAP_NET_RAW; the
// systemd service runs as root.
//
// SO_BINDTODEVICE is Linux-only; see bind_other.go for the fallback on other
// platforms.
func openUDP(ctx context.Context, iface string) (net.PacketConn, error) {
	var lc net.ListenConfig
	if iface != "" {
		lc.Control = func(_, _ string, c syscall.RawConn) error {
			var serr error
			if err := c.Control(func(fd uintptr) {
				serr = syscall.SetsockoptString(int(fd), syscall.SOL_SOCKET, syscall.SO_BINDTODEVICE, iface)
			}); err != nil {
				return err
			}
			return serr
		}
	}
	return lc.ListenPacket(ctx, "udp", ":0")
}
