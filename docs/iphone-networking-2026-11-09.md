# iPhone playback and standalone networking incident — 2026-11-09

## Result and scope

The user confirmed iPhone playback working after installation of **1.1.7 (10112)**
and runtime investigation. This followed a request to test with the separate
Tailscale app off. The agent did not independently observe the final Play action
or VPN switch state: iPhone Mirroring displayed the screen, but taps/text were
inert or failed with `noWindowsAvailable`. Treat this as user-confirmed recovery,
not an independently recorded cold-start pass.

The active deployment source is
`/Users/brajanzalta/Desktop/code/android-homelab/yomi-cloud-first`, branch
`cloud-first-iphone`. `Yomi-work` is an older checkout; it does not contain all the
deployed routing changes. Preserve the active checkout's existing modifications.
The build tree used was `/private/tmp/yomi-mac-update`.

## Confirmed defects and observed startup failure

There were several confirmed defects, followed by a transient startup failure.
Do not collapse these into a claim that a single timeout change fixed everything.

1. **Native audio was blocked by App Transport Security (ATS).** Both Apple
   Info.plists combined `NSAllowsArbitraryLoads=true` with
   `NSAllowsLocalNetworking=true`. Apple's documented precedence makes the former
   ineffective when the latter is present. The Mac native-player log explicitly
   reported `Cannot start load ... since it does not conform to ATS policy`.
   Dart library requests and a command-line stream check succeeding did not test
   this native-player path. Removing the conflicting local-networking key restored
   the app's existing arbitrary-load policy for configurable personal HTTP
   servers. Mac playback was then observed advancing from 0:02 to 0:11. The iPhone
   had the same source configuration; its native failure was not separately logged.

2. **The embedded tunnel's saved destination was still Android.** Reading the
   iPhone app preferences showed `flutter.tunnel.serverHost=100.88.180.104`, even
   though the account's primary server had migrated to cloud. `TunnelController`
   uses this separate preference when establishing its default forwards. Build
   10112 migrates that known personal destination to `100.82.99.19`, retaining
   enrollment, node state and account data. A post-install preference read verified
   the cloud destination. No new invite or node reset was required.

3. **Failover omitted the current logical server after a direct failure.**
   `_failOver` excluded `deadUrl` before calling `_probeAddress`, even though
   `_probeAddress` also tries the embedded path. An unavailable system-VPN route
   therefore skipped recovery of that same primary through the app's node and
   went to peers/default tunnel recovery instead. Build 10112 includes the current
   logical address and gives it selection priority. Candidate probes still run
   concurrently. Other paths such as pool refresh could also probe the primary;
   the old code did not prove embedded cloud access was impossible in every case.

4. **The first observed embedded peer connections timed out.** At 21:39:04 UTC,
   the device console showed the enrolled node starting and reporting `Running`.
   At 21:39:19, dials to both cloud and Mac music port 4533 timed out. The bridge's
   peer-dial deadline is 15 seconds. Recovery restarted the node; a later
   diagnostic launch at 21:41:13 reported `Starting` and subsequently exchanged
   traffic with cloud. These peer connection attempts failed despite valid enrollment;
   the underlying NAT/DERP/peer-path delay remains **unknown**. No timeout,
   firewall or ACL change was made to resolve this transient failure. A cloud-side
   ping also occurred during investigation, so spontaneous warmup and the effect
   of that probe cannot be separated from these observations.

The external Tailscale app supplied a working direct route when enabled, masking
problems in Yomi's separate embedded route. Its success is not a test of the
embedded node.

Apple reference: [NSAllowsArbitraryLoads precedence](https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity/nsallowsarbitraryloads).

## Evidence that narrowed the investigation

- Cloud authentication, raw audio ranges and actual song bytes passed checks.
  The stalled Mac song was available on cloud and Mac and used AAC in an M4A
  container. Neither a blanket cloud outage nor unsupported audio explained it.
- The embedded iPhone node was `yomi-501696`, address `100.81.117.81`; it remained
  enrolled and its key had not expired. Cloud TSMP ping reached it in about 28 ms.
  Enrollment/control-plane health still did not prove TCP reachability.
- A header-only capture on cloud's `tailscale0` observed TCP handshakes and request
  data from that embedded address to `100.82.99.19:4533`. No packet payloads were
  retained. This established an embedded data path, not native audio playback.
- Later `broken pipe` messages occurred with stable loopback listeners and no
  corresponding node restart. They can mean a local HTTP consumer cancelled a
  request; they are not evidence of repeated tunnel teardown by themselves.
- The independent review found no stream-URL bypass: logical URL resolution feeds
  `_build`, `SubsonicClient.streamUri`, and the player's audio source. It flagged
  the missing physical integration test and inadequate readiness evidence.

## Why earlier verification missed this

`bridge.Start`/`Running` establishes node/backend state. `bridge.Forward` allocates
a loopback listener **before** any remote dial. Remote dialing happens when a
consumer connects. Neither result demonstrates that cloud is reachable.

The 38 passing routing/tunnel regression tests used fake bridges and successful
probe responses. They verify migration, route selection and companion-port
mapping; they cannot verify tsnet, the device network, URLSession or AVPlayer.
The initial claim that server checks established iPhone playback was incorrect.

## Required acceptance checks for future networking changes

1. Identify the actual running app and active source checkout. On this Mac, the
   signed-in app was `Desktop/code/Yomi/release/Yomi.app`; `/Applications/Yomi.app`
   was a different, older copy. Inspect the running executable rather than assuming
   bundle ID/name selects the intended copy.
2. Preserve credentials, account ID, downloaded audio and the embedded node state.
   Check the logical primary, home/extras **and** `tunnel.serverHost` independently.
   Use personal migration only for known managed addresses; retain custom setups.
3. Inspect the built iOS/macOS Info.plists, not just source. Do not reintroduce ATS
   keys that override the intended policy. Retain the local-network usage text.
4. On the physical iPhone, disconnect the **separate Tailscale VPN** and verify
   the OS VPN is disconnected, including any on-demand reconnection. Merely closing
   the Tailscale app does not disconnect its VPN. Perform the first cold start
   **before** cloud-side ping or Connection doctor probes that could warm the path.
   Verify loopback HTTP reaches cloud through the embedded node. Record elapsed
   startup time and any dial failures. Repeat after background/resume and a network
   change. One warm successful request is insufficient.
5. Play a **non-downloaded** song. Observe its duration, advancing position and
   audible output. Verify the stream comes from the embedded node, then seek and
   skip. A server-side Range response or a cached/downloaded track alone is not a
   standalone playback pass.
6. Verify the companion upload port and writable-primary role through the resolved
   route. Mac standby playback must not be mistaken for writable cloud recovery.
7. Test cloud outage/return without repeatedly restarting a healthy shared node.
   Report a cold-start failure as unresolved even if playback eventually works.
8. State separately: automated tests passed; native data path observed; native
   playback observed; user-confirmed behavior; and any unavailable verification.
   If Mirroring input fails, report that limitation and request one physical action
   instead of declaring success from a screenshot.

## Recovery and remaining work

Keep public version **1.1.7** until the user requests a release. The iPhone is on
internal build **10112**. Mac copies are **10110** with the ATS fix; the later
embedded-recovery changes were deployed to iPhone only. No release/tag was made.

If startup fails again, first capture a timestamped device console and cloud-side
header-only trace before restarting. Distinguish direct address, loopback listener,
remote TCP dial, authenticated HTTP and AVPlayer. Do not delete enrollment, expand
ACLs, alter firewall rules or increase deadlines without evidence for that action.

The precise cause of the transient 15-second peer-path timeout and repeatable
cold-start reliability remain **unproven**. There is a possible cross-probe restart
race between pool refresh and failover, but the captured stable listeners do not
show it caused this incident. Do not describe it as a confirmed root cause.

Raw console/prefs files in `/private/tmp` are temporary and may contain private
state or authenticated URLs. Do not commit them. This report preserves the relevant
redacted observations; it is not a complete network trace.
