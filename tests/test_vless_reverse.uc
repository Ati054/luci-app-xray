#!/usr/bin/ucode
"use strict";

import { vless_outbound } from "../core/root/usr/share/xray/protocol/vless.mjs";
import { server_outbound } from "../core/root/usr/share/xray/feature/outbound.mjs";
import {
    get_dual_reverse_config,
    get_normal_vless_config,
    get_invalid_multi_port_reverse_config,
    get_missing_port_reverse_config,
    get_port_zero_reverse_config,
    get_port_overflow_reverse_config,
    get_nonnumeric_port_reverse_config,
    get_empty_uuid_reverse_config,
    get_normal_server_blank_reverse_tag_config,
    get_reverse_with_custom_mark_config
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

print("=== Test Suite: VLESS Protocol Module & Reverse Validation ===\n");

// Test 1: Reverse VLESS uses simplified settings and contains no vnext
{
    print("Test 1: Reverse VLESS uses simplified settings and contains no vnext");
    const config = get_dual_reverse_config();
    const server_raw = config["server_raw"];
    const res = vless_outbound(server_raw, "reverse-raw");
    const outbound = res.outbound;

    assert(outbound.protocol == "vless", "protocol must be vless");
    assert(outbound.tag == "reverse-raw", "tag must match provided tag");
    assert(outbound.settings.vnext == null, "settings.vnext must not exist in reverse VLESS");
    assert(outbound.settings.address == "198.51.100.1", "settings.address must be 198.51.100.1");
    assert(outbound.settings.port == 443, "settings.port must be integer 443");
    assert(outbound.settings.id == "00000000-0000-0000-0000-000000000001", "settings.id must match password/uuid");
    assert(outbound.settings.flow == "xtls-rprx-vision", "settings.flow must match configured flow");
    assert(outbound.settings.encryption == "none", "settings.encryption must be none");
    assert(type(outbound.settings.reverse) == "object", "settings.reverse must be an object");
    assert(outbound.settings.reverse.tag == "reverse-raw-in", "settings.reverse.tag must match reverse_tag");
}

// Test 2: Normal VLESS still uses the existing vnext format
{
    print("\nTest 2: Normal VLESS still uses existing vnext format");
    const config = get_normal_vless_config();
    const normal_server = config["normal_vless"];
    const res = vless_outbound(normal_server, "normal-vless");
    const outbound = res.outbound;

    assert(outbound.protocol == "vless", "protocol must be vless");
    assert(type(outbound.settings.vnext) == "array", "settings.vnext must be an array");
    assert(length(outbound.settings.vnext) == 2, "settings.vnext must have 2 ports");
    assert(outbound.settings.reverse == null, "settings.reverse must not exist in normal VLESS");
}

// Test 3: Reverse VLESS rejects multiple endpoint ports
{
    print("\nTest 3: Reverse VLESS rejects multiple endpoint ports");
    const config = get_invalid_multi_port_reverse_config();
    const invalid_server = config["invalid_reverse"];
    let caught = false;
    try {
        vless_outbound(invalid_server, "invalid-reverse");
    } catch (e) {
        caught = true;
    }
    assert(caught, "calling vless_outbound with multiple ports on reverse VLESS must throw an error");
}

// Test 4: Two Reverse links produce two distinct VLESS outbounds
{
    print("\nTest 4: Two Reverse links produce two distinct VLESS outbounds");
    const config = get_dual_reverse_config();
    const res_raw = vless_outbound(config["server_raw"], "reverse-raw");
    const res_xhttp = vless_outbound(config["server_xhttp"], "reverse-xhttp");

    assert(res_raw.outbound.tag != res_xhttp.outbound.tag, "tags must be distinct");
    assert(res_raw.outbound.settings.reverse.tag != res_xhttp.outbound.settings.reverse.tag, "reverse tags must be distinct");
    assert(res_raw.outbound.settings.id != res_xhttp.outbound.settings.id, "UUIDs must be distinct");
    assert(res_raw.outbound.streamSettings.network == "tcp", "raw link network must be tcp");
    assert(res_raw.outbound.streamSettings.tcpSettings == null, "raw TCP without disguise must omit tcpSettings");
    assert(res_xhttp.outbound.streamSettings.network == "splithttp", "xhttp link network must be splithttp");
}

// Test 11: Missing port rejection
{
    print("\nTest 11: Missing port rejection on reverse VLESS");
    const config = get_missing_port_reverse_config();
    let caught = false;
    try {
        vless_outbound(config["s1"], "s1");
    } catch (e) {
        caught = true;
    }
    assert(caught, "reverse VLESS without port must throw an error");
}

// Test 12: Port 0 rejection
{
    print("\nTest 12: Port 0 rejection on reverse VLESS");
    const config = get_port_zero_reverse_config();
    let caught = false;
    try {
        vless_outbound(config["s1"], "s1");
    } catch (e) {
        caught = true;
    }
    assert(caught, "reverse VLESS with port 0 must throw an error");
}

// Test 13: Port 65536 overflow rejection
{
    print("\nTest 13: Port 65536 overflow rejection on reverse VLESS");
    const config = get_port_overflow_reverse_config();
    let caught = false;
    try {
        vless_outbound(config["s1"], "s1");
    } catch (e) {
        caught = true;
    }
    assert(caught, "reverse VLESS with port 65536 must throw an error");
}

// Test 14: Nonnumeric port rejection
{
    print("\nTest 14: Nonnumeric port rejection on reverse VLESS");
    const config = get_nonnumeric_port_reverse_config();
    let caught = false;
    try {
        vless_outbound(config["s1"], "s1");
    } catch (e) {
        caught = true;
    }
    assert(caught, "reverse VLESS with nonnumeric port must throw an error");
}

// Test 15: Empty UUID rejection
{
    print("\nTest 15: Empty UUID rejection on reverse VLESS");
    const config = get_empty_uuid_reverse_config();
    let caught = false;
    try {
        vless_outbound(config["s1"], "s1");
    } catch (e) {
        caught = true;
    }
    assert(caught, "reverse VLESS with empty UUID must throw an error");
}

// Test 16: Blank optional reverse_tag on normal server does not activate reverse
{
    print("\nTest 16: Blank optional reverse_tag on normal server does not activate reverse");
    const config = get_normal_server_blank_reverse_tag_config();
    const res = vless_outbound(config["s1"], "s1");
    assert(res.outbound.settings.vnext != null, "normal server with blank reverse_tag must remain normal vnext");
    assert(res.outbound.settings.reverse == null, "normal server must not have settings.reverse");
}

// Test 17: Reverse custom_config cannot restore sockopt.mark
{
    print("\nTest 17: Reverse custom_config cannot restore sockopt.mark");
    const config = get_reverse_with_custom_mark_config();
    const outbounds = server_outbound(config["s1"], "rev-custom", config);
    assert(length(outbounds) == 1, "must produce one outbound");
    const ob = outbounds[0];
    assert(ob.streamSettings == null || ob.streamSettings.sockopt == null || ob.streamSettings.sockopt.mark == null, "reverse outbound must not contain sockopt.mark even if injected via custom_config");
}

printf("\nSummary: %d passed, %d failed\n", passed, failed);
if (failed > 0) {
    exit(1);
}
exit(0);
