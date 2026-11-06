// Command cshared builds the bridge as a C library for the Linux app, which can't use
// gomobile. The app loads it with dart:ffi; see app/lib/core/tunnel/ffi_tunnel_bridge.dart.
// Strings returned to the app must be freed with YomiTunnelFree.
package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"unsafe"

	bridge "yomi/tailscale_bridge"
)

func errorText(err error) *C.char {
	if err == nil {
		return nil
	}
	return C.CString(err.Error())
}

//export YomiTunnelStart
func YomiTunnelStart(stateDir, authKey, hostname *C.char) *C.char {
	return errorText(bridge.Start(C.GoString(stateDir), C.GoString(authKey), C.GoString(hostname)))
}

// YomiTunnelForward returns the local port, or -1 with the reason in errorOut.
//
//export YomiTunnelForward
func YomiTunnelForward(remote *C.char, errorOut **C.char) C.int {
	port, err := bridge.Forward(C.GoString(remote))
	if err != nil {
		*errorOut = errorText(err)
		return -1
	}
	return C.int(port)
}

//export YomiTunnelNetworkChanged
func YomiTunnelNetworkChanged() { bridge.NetworkChanged() }

//export YomiTunnelState
func YomiTunnelState() *C.char { return C.CString(bridge.State()) }

//export YomiTunnelStop
func YomiTunnelStop() *C.char { return errorText(bridge.Stop()) }

//export YomiTunnelFree
func YomiTunnelFree(text *C.char) { C.free(unsafe.Pointer(text)) }

func main() {}
