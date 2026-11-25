# PC original configuration → Android execution

## Settled user goal

The user explicitly started execution of PC record25 (混淆订阅测试,93sites/78CSP) on a selected existing Android environment. Keep originalPCrecordid/json/sourceKey/history/favorites; Android creates/reuses a nonactive copy, never switches activeconfig. No arbitraryJAR upload or localbundle support inV1.

Android control contract is accepted and committed25541eda19b057ab84d798606d7c7e654954c19f: POST /manage/config/import, urlencoded url/name/type0, X-WebHTV-PC-Import:1, actual-loopback only/noOrigin; response code0,data{id,interfaceKey,url,name,created,active}. T4 configKey is interfaceKey, nevernumericid. Normal热播source category12/detail1/3flags/143episodes proven, active204keys unchanged; playback remainsnextverification.

## Design

- OriginalPCJSON/source identities areimmutable. Use a separate version1 execution-binding store and an effectivein-memory AppConfig overlay. Never write bridgeInterfaceKey/bridgeTransport ontooriginalrecords.
- Binding key=(originalsourceKey,Androidprofile.connectionKey), with one selectedprofile per source. Persistent fields:sourceKey,profileConnectionKey,deviceUuid,interfaceKey,configHash,snapshotToken,guestPort. interfaceKeymay beempty forreservedpendingbinding, but cannotbeenableduntilready. guestPort consistentperprofile.
- PC snapshot server binds127.0.0.1:0; exact token.json paths, GET/HEADonly,noCORS/no-store, bounded2MiBJSON. Snapshot token is highentropy andstable; no rawURLs/tokens/credentialsinlogs. Preserve rawfields, resolve supportedrelativeHTTPrefs againstoriginalorigin; reject localJAR/ext/PCbundle/webhome references explicitly.
- ADBreverse is a DEVICE service aftertransport selection. Runtime exposes ensureReverse(uuid,{requiredlocalPort,guestPort=0})→actualguestPort and releaseReverse(uuid,guestPort). tcp0onlyfirstallocation; persistactualguestport andrestorenorebindtoit. Reuse exactexistingrows asborrowed; conflicts failclosed, neveroverwrite orremoveall. Ownership includesserver/serial/deviceUUID/remote/local andattempt/session; releaseonlyown.
- Stable deviceURL=http://127.0.0.1:guestPort/snapshotToken.json. It stayssameacrossPCreconnect whilelocalsnapshotserverportchanges. Contentupdate requiretargetedAndroidcataloginvalidation onre-import (current60sTTLmustnotserveoldJSON); no globalcacheclear/performancechange.
- Prepare: validateoriginalsnapshot→connect expecteddevice→startpublisher→ensurereverse→reservebinding(token/port)beforecreatingAndroidrow→POSTimport→rejectactivecopy→fetchT4byinterfaceKey→validatealloriginalkeys→overlayoriginalsites(type4/API/ext fromT4, originalkey/name/display/header retained, removejar)→savecompletedbinding→enable/apply.
- Missingoriginalkeys fail preparation withdiagnostics; Androidauto-injectedextra sites areexcluded. No implicitPCfallback onselectedAndroidconfiguration.
- Onlytopruntime changes; existinglive/settings/extraneouslocalinjectionsretain theirprior semantics. Pipeline caches includeexecutionepoch/gateway. Playbackresolverusesoriginatingoverlayservice/gatewayandactualmediaURI, notmutableactiveconfig, nolegacyplaybackbridgeforoverlay.
- Reconnect/activate/refresh/historycontext prepareselectedbindingbeforeusingcachedAPIs; missingforgottenprofile/wrongUUID/portconflict failclearly, neveroldport. DisableAndroidexecution restoresoriginalPCview while retainingbindingtoken/portfornextreuse; cleanupownreverse/profile-refcount/publication, don'tstopuserAndroid.

## Work topology

Hybrid: Lead ownscontrolclient andintegrationdecisions; SDKreverse andsnapshot/bindingcore areindependent settledadapters. Orchestrator thenUI/state followacceptedinterfaces. Scope-awaretests andrealdeviceR6, no fullJarcompatibilitypromise.

## Acceptance

- Snapshot/import/reconnectsamepayload producesoneAndroidcopyURL/interfaceKey andnoAndroidactiveconfigchange.
- PC originalrecordid/json/sourceKey/rowcount remainunchanged, includinghistorysource linkage.
- Original93siteoverlay excludesinjectedextra, retainskeys/metadata; source routing isAndroidwhenenabled andPCwhendisabled.
- Token/HTTP/reverseownership/wrongdevice/conflict/bounds/cleanup tests, actualwireframing beforemockgreenclaims.
- Catalogrefresh target-only: updatedJSONread immediately afterreimport without60s stalecache.
- ActualnewUIBefore/After, Androidmovie detail+playresolution+boundedmedia whenavailable; unavailableproviderresponses notfakepass.

Orchestrator input/rollback correction (Lead)
- Constructor also receives AndroidConnectionStore connections; savedprofile lookup is independentofliveRuntime forprocessrestart.
- prepare requires explicitoriginalsourceKey fromAppState; refresh requires originalConfig AND ConfigRecord (rawJSON/origin) andusessavedprofile, neverAppConfig.toJson as a replacementforrawsnapshot.
- Pendingbinding(token/deviceguestport) isdurablyreservedbeforeAndroidimport so importsuccess/fetchfailure retryreusesoneURL/copy. Existingreadybinding/selection isnotreplacedbyanunreadyplaceholder.
- Sharedreverse leases areprofile-scoped; failedprepareB cannotremove successfulprepareA's shared reverse/snapshot; changedpayload preparations do notraceone stablepublication.
Reverse ownership follow-up: explicit acquireReverse returns AndroidReverseLease(guestPort,created,uuid,release), borrowed release no-op; async bind after owner close mustrollback ratherthanleave anorphan. Two simultaneouslylive Appgateway identities sharingserial canborrow butnever releaseeachother's lease; ordinarydisconnect shouldleave no late-createdrows.

Public Android media provenance routing (existing managed HLS standard)
- Content-inspection source hint is separate from SDK targetResolver. Public media from a validated Android-execution source still inspects/tokenizes HLS children; resolver may be null when no ADB mapping is needed.
- Only explicit provenance sessions use an empty per-session host set, delegating to Global ProxyTargetPolicy (allowedHosts, scheme, DNS IP checks, redirects). No private/loopback/metadata grant and no runtime-origin matcher change. Ordinary PC sessions keep top-host fence.
- SensitiveHeaders Cookie/Authorization/extra credentials stay pinned to logical origin; cross-CDN host does not inherit them. Existing explicit UA/Referer rules unchanged.

## User-approved PNG-wrapped MPEG-TS compatibility

Actual source media contains a complete 69-byte PNG prefix followed by MPEG-TS. A payload probe after the prefix identifies H.264 1920x818 and AAC; generic FFmpeg HLS instead detects png_pipe. User approved bounded compatibility, not merely byte transfer. Existing Android MpvHlsSegmentContentPolicy/MpvHlsProxy are the standard reference.

Only validated Android-origin media is eligible. A <=16KiB prefix probe must prove PNG signature + IEND + at least three 188-byte TS syncs. Genuine PNG, MP4, unproven prefixes, errors, and ordinary PC streams are byte-exact. Proven segments stream as video/mp2t with prefix stripped; no whole media buffering. Normalized entities use full200 with honest headers, not stale partial206 metadata. Necessary no-Range/prefix requests remain finite, endpoint-pinned, quota-accounted, and token/policy checked. HEAD creates no extra GET. No source record/JAR/global authorization changes. Final acceptance requires native HLS/codec detection of normalized payload, not just >1024 bytes.
Decoder format hint finding: normalized MPEG-TS with an extensionless child URI still fails native FFmpeg HLS extension validation. A bounded registered child `.ts` alias plus video/mp2t decodes H264/AAC without globally disabling extension checks. Implement only the needed source-media format hint; retain legacy routes/token index binding and do not rename variants/encryption keys/fMP4 indiscriminately. Native decode evidence must use actual proxy output, not only pre-trimmed forced-format input.
