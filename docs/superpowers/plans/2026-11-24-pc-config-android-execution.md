# PC Configuration Android Execution Plan

**Goal:** run user'soriginalPCconfiguration inselectedAndroidenvironment withoutreplacingPCconfiguration orswitchingAndroidactiveconfig.
**Spec:** ../specs/2026-11-24-pc-config-android-execution.md
**Interfaces:** allbriefsbelowfreezeexactconsumednames; atmost3runsperbrief.

1. Lead typedAndroidBridgeService.importPcConfig controlclient + tests. AcceptedAndroidPOSTcontractwithinterfaceKey, sanitizedfailures, actual-loopbackbase.
2. SDKreverse adapter: AndroidAdbRuntime.ensureReverse(uuid,{requiredlocalPort,guestPort=0})→Future<int>, releaseReverse(uuid,guestPort)→Future<void>, rawwireverification andexistingownershipregression. Writesonlyruntime+its2testfiles.
3. Binding/snapshotcore: newcore/android_config_execution.dart, services/android_config_execution_store.dart, services/pc_config_snapshot_server.dart andfocusedtests. Stabletokens/profileguestport, pureoverlay/rawsnapshotvalidation, atomicstore.
4. ScopedAndroidcacheinvalidation tinyunit: no globalcacheclear, noactiveconfigswitch; sameURLimportinvalidateonlythatinterfaceKeybeforeT4fetch. FollowAndroidguardbeforeedits/closure.
5. Orchestrator services/android_config_execution_service.dart +tests, usingfrozenclient/reverse/store/publisher APIs; freshleases/reservation/rollback/expectedUUID/sourcekeys.
6. State/UI adapter app_state+config_pages: per-recordexecute menu/profilepicker, bindingactivation/overlay/epoch/sourcecontexts/refresh/delete/history; preserveoriginalDBcontentandsourceKey. No newDBbridgecolumns.
7. LeadR6: fullchanged diff andfocusedregressions, fullanalyze, Before/After ofnewUI, actual record25+selectedemulator→normalmovie playresolution/boundedmedia andsame-source reconnect. Capturefailurestateshonestly. BuildcurrentPCbinaryorclearlymarksource-onlydelivery, nofalseoldbinaryfeatureclaims.
