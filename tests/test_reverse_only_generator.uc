#!/usr/bin/ucode
"use strict";

import {
    get_dual_reverse_config,
    get_normal_vless_config,
    get_non_vless_reverse_config,
    get_duplicate_outbound_tags_config,
    get_duplicate_reverse_tags_config
} from "./fixtures/sample_configs.uc";

let passed = 0;
let failed = 0;

function assert(cond, msg) {
    if (cond) {
        printf("  [PASS] %s\n", msg);
        passed++;
    } else {
        printf("  [FAIL] %s\n", msg);
        failed++;
    }
}

print("=== Test Suite: Reverse-only Generator Contract ===\n");

import { outbounds_reverse, rules_reverse, gen_config_from_data } from "../core/root/usr/share/xray/gen_config.uc";

// Test 5 & 6: Reverse egress finalRules and clean routing rule
{
    print("Test 5 & 6: Reverse egress finalRules and clean routing rule");
    const config = get_dual_reverse_config();
    const result = gen_config_from_data(config);

    assert(type(result.routing) == "object", "routing must exist");
    assert(type(result.routing.rules) == "array", "routing.rules must be an array");

    // Find the reverse egress routing rule
    let egress_rule = null;
    for (let r in result.routing.rules) {
        if (r.outboundTag == "reverse-egress") {
            egress_rule = r;
            break;
        }
    }
    assert(egress_rule != null, "reverse-egress routing rule must exist");
    assert(index(egress_rule.inboundTag, "reverse-raw-in") >= 0, "rule must match reverse-raw-in");
    assert(index(egress_rule.inboundTag, "reverse-xhttp-in") >= 0, "rule must match reverse-xhttp-in");
    assert(egress_rule.ip == null, "routing rule must not put ip matcher as substitute for finalRules");
    assert(egress_rule.network == null, "routing rule must not put network matcher as substitute for finalRules");

    // Verify reverse-egress freedom outbound finalRules
    let egress_outbound = null;
    for (let ob in result.outbounds) {
        if (ob.tag == "reverse-egress") {
            egress_outbound = ob;
            break;
        }
    }
    assert(egress_outbound != null, "reverse-egress outbound must exist");
    assert(egress_outbound.protocol == "freedom", "reverse-egress protocol must be freedom");
    assert(type(egress_outbound.settings) == "object", "settings must exist on reverse-egress");
    assert(egress_outbound.settings.domainStrategy == "UseIP", "domainStrategy must be UseIP");
    assert(type(egress_outbound.settings.finalRules) == "array", "finalRules must exist on reverse-egress");
    assert(length(egress_outbound.settings.finalRules) == 1, "finalRules must have 1 rule");
    const fr = egress_outbound.settings.finalRules[0];
    assert(fr.action == "allow", "finalRules action must be allow");
    assert(fr.network == "tcp,udp", "finalRules network must be tcp,udp");
    assert(length(fr.ip) == 1 && fr.ip[0] == "!geoip:private", "finalRules ip must be exactly [\"!geoip:private\"]");
}

// Test 7: Reverse-only config contains no listening SOCKS, HTTP, TProxy, FakeDNS, DNS interception, observatory, or balancers
{
    print("\nTest 7: Reverse-only config contains no listening SOCKS, HTTP, TProxy, FakeDNS, DNS interception, observatory, or balancers");
    const config = get_dual_reverse_config();
    const result = gen_config_from_data(config);

    assert(length(result.inbounds) == 0, "inbounds must be empty in reverse-only mode");
    assert(result.dns == null, "dns config must be null in reverse-only mode");
    assert(result.fakedns == null, "fakedns config must be null in reverse-only mode");
    assert(result.observatory == null, "observatory must be null in reverse-only mode");
    assert(result.routing.balancers == null || length(result.routing.balancers) == 0, "balancers must be null or empty in reverse-only mode");
    assert(result.reverse == null, "legacy reverse bridge must be null in reverse-only mode");

    // Check outbounds structure
    assert(length(result.outbounds) == 4, "outbounds must contain default freedom, reverse-egress, and 2 reverse VLESS links");
    assert(result.outbounds[0].protocol == "freedom", "outbound[0] must be default freedom placeholder");
    assert(result.outbounds[0].tag == null, "outbound[0] must be untagged default placeholder");
    assert(result.outbounds[1].protocol == "freedom" && result.outbounds[1].tag == "reverse-egress", "outbound[1] must be dedicated reverse-egress freedom outbound");

    // Check reverse outbounds
    assert(result.outbounds[2].protocol == "vless" && result.outbounds[2].settings.reverse.tag == "reverse-raw-in", "outbound[2] must be reverse-raw");
    assert(result.outbounds[3].protocol == "vless" && result.outbounds[3].settings.reverse.tag == "reverse-xhttp-in", "outbound[3] must be reverse-xhttp");

    // Check logs
    assert(result.log.access == "none", "access log must be disabled in reverse-only mode");
    assert(result.log.loglevel == "warning", "log level must be warning");
}

// Test 9: Legacy/non-Reverse mode retains existing generator behavior
{
    print("\nTest 9: Legacy/non-Reverse mode retains existing generator behavior");
    const config = get_normal_vless_config();
    const result = gen_config_from_data(config);

    assert(length(result.inbounds) > 0, "inbounds must be populated in legacy transparent proxy mode");
    assert(result.dns != null, "dns config must be present in legacy mode");
    assert(result.routing.balancers != null && length(result.routing.balancers) > 0, "balancers must be populated in legacy mode");
}

// Test 10: Verify outbounds are generated when custom_config is unset/null
{
    print("\nTest 10: Verify outbounds are correctly generated when custom_config is unset");
    const config = get_dual_reverse_config();
    assert(config["server_raw"]["custom_config"] == null, "sample server_raw has no custom_config");
    const outbounds = outbounds_reverse(config["general"], config);
    assert(length(outbounds) == 4, "outbounds_reverse must return exactly 4 outbounds");
    assert(outbounds[2].tag == "reverse-raw", "reverse-raw outbound must be properly formed without custom_config");
}

// Test 18: Non-VLESS protocol marked Reverse rejection
{
    print("\nTest 18: Non-VLESS protocol marked Reverse must be rejected");
    const config = get_non_vless_reverse_config();
    let caught = false;
    try {
        outbounds_reverse(config["general"], config);
    } catch (e) {
        caught = true;
    }
    assert(caught, "non-VLESS protocol with vless_reverse=1 must throw an error");
}

// Test 19: Duplicate outbound tags rejection
{
    print("\nTest 19: Duplicate outbound tags rejection");
    const config = get_duplicate_outbound_tags_config();
    let caught = false;
    try {
        outbounds_reverse(config["general"], config);
    } catch (e) {
        caught = true;
    }
    assert(caught, "duplicate outbound tags in reverse configuration must throw an error");
}

// Test 20: Duplicate local Reverse tags rejection
{
    print("\nTest 20: Duplicate local Reverse tags rejection");
    const config = get_duplicate_reverse_tags_config();
    let caught = false;
    try {
        outbounds_reverse(config["general"], config);
    } catch (e) {
        caught = true;
    }
    assert(caught, "duplicate local reverse tags in reverse configuration must throw an error");
}

printf("\nSummary: %d passed, %d failed\n", passed, failed);
if (failed > 0) {
    exit(1);
}
exit(0);
