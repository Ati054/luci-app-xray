#!/usr/bin/ucode
"use strict";

import { get_dual_reverse_config, get_normal_vless_config } from "./fixtures/sample_configs.uc";

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

// We test generator logic by passing mocked configs into core generator logic
import { outbounds_reverse, rules_reverse, gen_config_from_data } from "../core/root/usr/share/xray/gen_config.uc";

// Test 5 & 6: Reverse routing and freedom egress rule with !geoip:private
{
    print("Test 5 & 6: Both local Reverse tags route to dedicated freedom outbound with !geoip:private");
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
    assert(index(egress_rule.ip, "!geoip:private") >= 0, "rule must enforce !geoip:private");
    assert(egress_rule.network == "tcp,udp", "rule must cover tcp,udp");
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
    assert(length(result.outbounds) >= 3, "outbounds must contain default freedom, reverse-egress, and 2 reverse VLESS links");
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

printf("\nSummary: %d passed, %d failed\n", passed, failed);
if (failed > 0) {
    exit(1);
}
exit(0);
