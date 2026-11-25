# Real AppState run of the original PC configuration (blocked at playlist rewriting)

Scenario: read-only copy of PC record25 (93 sites, 78 CSP) executed on the selected Android environment through the real AppState path (no injected SDK), on 192.168.50.3:5555. Original PC database untouched.

Verified in this run: 93/93 overlay sites all type 4; original record JSON byte-identical; source key unchanged; 代表性影视源A home 6 classes, category 12 items, 3 play flags; playback decision returned a proxied URL; the proxied fetch returned HTTP 206 with 45460 bytes of an HLS media playlist (488 segment URIs).

Regression found and fixed before this run: the earlier HTTP 400 was produced by Flutter test binding MockHttpOverrides in the private harness, not by the device, runtime, bridge, or the Android import guard. Corrected by a scoped real HttpOverrides; no production change to that path.

Blocking defect: those 488 child URIs were NOT rewritten (uri_abs_proxy=0, uri_abs_other=488), because the upstream labelled the playlist application/octet-stream and the proxy streamed it as opaque bytes. Segment fetch from PC therefore 404s. Fix dispatched: content-sniffed bounded playlist rewriting for managed sessions only.

Not verified: segment bytes and full playback, restart persistence assertions after that point, and all other 78 CSP sources.

Address-namespace correction
- Parsedactualmanifest URIs:488total,10publicIP+478domain,5distincthosts,478.pngpaths. They arenotguest-loopbackURLs. Priorstatementthat404necessarilycamefromguest-onlyaddresswasover-inferred.
- Skippedcontent-typeHLSrewrite stillisacontractgap(sessionheaders/policy/childrenmustberewritten), butthefirstupstream404needstobecomparedwiththeheader-preservingrewrittenrequest beforeattributingitsolelytothisgap. Do notclaimallsegmentsworkingyet.
- Unknown-type sniffhardcap1MiB: unprovenbinaryoverflowstreamunchanged; provenmanifestoverflowfailclosedratherthanrawURIforward. KnownMIMEmanifestexistingbounds unchanged.
