"use strict";

export function get_dual_reverse_config() {
    return {
        "general": {
            ".type": "general",
            ".name": "general",
            "reverse_only": "1",
            "transparent_proxy_enable": "0",
            "xray_bin": "/opt/xray/current/xray",
            "xray_location_asset": "/opt/xray/current",
            "loglevel": "warning",
            "access_log": "0"
        },
        "server_raw": {
            ".type": "servers",
            ".name": "server_raw",
            "alias": "reverse-raw",
            "tag": "reverse-raw",
            "reverse": "1",
            "reverse_tag": "reverse-raw-in",
            "server": "198.51.100.1",
            "server_port": "443",
            "password": "00000000-0000-0000-0000-000000000001",
            "protocol": "vless",
            "vless_encryption": "none",
            "vless_tls": "reality",
            "vless_flow_reality": "xtls-rprx-vision",
            "vless_reality_server_name": "example.com",
            "vless_reality_public_key": "dummy_public_key_for_testing",
            "vless_reality_short_id": "0123456789abcdef",
            "vless_reality_fingerprint": "chrome",
            "transport": "tcp"
        },
        "server_xhttp": {
            ".type": "servers",
            ".name": "server_xhttp",
            "alias": "reverse-xhttp",
            "tag": "reverse-xhttp",
            "reverse": "1",
            "reverse_tag": "reverse-xhttp-in",
            "server": "198.51.100.2",
            "server_port": "8443",
            "password": "00000000-0000-0000-0000-000000000002",
            "protocol": "vless",
            "vless_encryption": "none",
            "vless_tls": "none",
            "transport": "splithttp",
            "splithttp_host": "xhttp.example.com",
            "splithttp_path": "/xhttp-path"
        }
    };
}

export function get_normal_vless_config() {
    return {
        "general": {
            ".type": "general",
            ".name": "general",
            "reverse_only": "0",
            "transparent_proxy_enable": "1",
            "xray_bin": "/usr/bin/xray",
            "tcp_balancer_v4": ["normal_vless"]
        },
        "normal_vless": {
            ".type": "servers",
            ".name": "normal_vless",
            "alias": "normal-vless",
            "server": "203.0.113.10",
            "server_port": ["443", "8443"],
            "password": "11111111-1111-1111-1111-111111111111",
            "protocol": "vless",
            "vless_encryption": "none",
            "vless_tls": "tls",
            "vless_flow_tls": "xtls-rprx-vision",
            "vless_tls_host": "example.org",
            "transport": "tcp"
        }
    };
}

export function get_invalid_multi_port_reverse_config() {
    return {
        "general": {
            ".type": "general",
            ".name": "general",
            "reverse_only": "1"
        },
        "invalid_reverse": {
            ".type": "servers",
            ".name": "invalid_reverse",
            "alias": "invalid-reverse",
            "reverse": "1",
            "reverse_tag": "invalid-reverse-in",
            "server": "198.51.100.3",
            "server_port": ["443", "8443"],
            "password": "22222222-2222-2222-2222-222222222222",
            "protocol": "vless",
            "transport": "tcp"
        }
    };
}
