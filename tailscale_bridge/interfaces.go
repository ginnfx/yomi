package bridge

import (
	"net"
	"net/netip"
	"strconv"
	"strings"

	"tailscale.com/net/netmon"
)

const interfaceFieldCount = 5

// InterfaceSource supplies network interfaces from the app. Android 11 and later block
// Go's own way of listing them, which would leave Tailscale thinking it's offline.
type InterfaceSource interface {
	// Interfaces returns one line per interface: name,index,mtu,flags,addr/prefix;addr/prefix
	// where flags is any of the letters u(p), l(oopback), p(oint to point), m(ulticast).
	Interfaces() string
}

// SetInterfaceSource must be called before Start on Android.
func SetInterfaceSource(source InterfaceSource) {
	netmon.RegisterInterfaceGetter(func() ([]netmon.Interface, error) {
		return parseInterfaces(source.Interfaces()), nil
	})
}

func parseInterfaces(report string) []netmon.Interface {
	var result []netmon.Interface
	for _, line := range strings.Split(strings.TrimSpace(report), "\n") {
		fields := strings.Split(line, ",")
		if len(fields) != interfaceFieldCount {
			continue
		}
		index, indexErr := strconv.Atoi(fields[1])
		mtu, mtuErr := strconv.Atoi(fields[2])
		if indexErr != nil || mtuErr != nil {
			continue
		}
		iface := netmon.Interface{
			Interface: &net.Interface{Index: index, MTU: mtu, Name: fields[0], Flags: parseFlags(fields[3])},
		}
		for _, raw := range strings.Split(fields[4], ";") {
			if prefix, err := netip.ParsePrefix(raw); err == nil {
				iface.AltAddrs = append(iface.AltAddrs, &net.IPNet{
					IP:   prefix.Addr().AsSlice(),
					Mask: net.CIDRMask(prefix.Bits(), prefix.Addr().BitLen()),
				})
			}
		}
		result = append(result, iface)
	}
	return result
}

func parseFlags(flags string) net.Flags {
	var parsed net.Flags
	for letter, flag := range map[string]net.Flags{
		"u": net.FlagUp, "l": net.FlagLoopback, "p": net.FlagPointToPoint, "m": net.FlagMulticast,
	} {
		if strings.Contains(flags, letter) {
			parsed |= flag
		}
	}
	return parsed
}
