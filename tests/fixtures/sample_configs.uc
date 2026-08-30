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
            "vless_reverse": "1",
            "vless_reverse_tag": "reverse-raw-in",
            "server": "198.51.100.1",
            "server_port": "443",
            "password": "00000000-0000-0000-0000-000000000001",
            "protocol": "vless",
            "vless_encryption": "none",
            "vless_tls": "reality",
            "vless_flow_reality": "xtls-rprx-vision",
            "vless_reality_server_name": "example.com",
            "vless_reality_public_key": "67Crg1l33rjDO9A9mUkHQUIWyr1pBeFNNW93armtSEg",
            "vless_reality_short_id": "0123456789abcdef",
            "vless_reality_fingerprint": "chrome",
            "transport": "tcp"
        },
        "server_xhttp": {
            ".type": "servers",
            ".name": "server_xhttp",
            "alias": "reverse-xhttp",
            "tag": "reverse-xhttp",
            "vless_reverse": "1",
            "vless_reverse_tag": "reverse-xhttp-in",
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
};

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
};

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
            "vless_reverse": "1",
            "vless_reverse_tag": "invalid-reverse-in",
            "server": "198.51.100.3",
            "server_port": ["443", "8443"],
            "password": "22222222-2222-2222-2222-222222222222",
            "protocol": "vless",
            "transport": "tcp"
        }
    };
};

export function get_missing_port_reverse_config() {
    return {
        "general": { ".type": "general", ".name": "general", "reverse_only": "1" },
        "s1": {
            ".type": "servers",
            ".name": "s1",
            "vless_reverse": "1",
            "server": "198.51.100.1",
            "password": "00000000-0000-0000-0000-000000000001",
            "protocol": "vless"
        }
    };
};

export function get_port_zero_reverse_config() {
    return {
        "general": { ".type": "general", ".name": "general", "reverse_only": "1" },
        "s1": {
            ".type": "servers",
            ".name": "s1",
            "vless_reverse": "1",
            "server": "198.51.100.1",
            "server_port": "0",
            "password": "00000000-0000-0000-0000-000000000001",
            "protocol": "vless"
        }
    };
};

export function get_port_overflow_reverse_config() {
    return {
        "general": { ".type": "general", ".name": "general", "reverse_only": "1" },
        "s1": {
            ".type": "servers",
            ".name": "s1",
            "vless_reverse": "1",
            "server": "198.51.100.1",
            "server_port": "65536",
            "password": "00000000-0000-0000-0000-000000000001",
            "protocol": "vless"
        }
    };
};

export function get_nonnumeric_port_reverse_config() {
    return {
        "general": { ".type": "general", ".name": "general", "reverse_only": "1" },
        "s1": {
            ".type": "servers",
            ".name": "s1",
            "vless_reverse": "1",
            "server": "198.51.100.1",
            "server_port": "abc443",
            "password": "00000000-0000-0000-0000-000000000001",
            "protocol": "vless"
        }
    };
};

export function get_non_vless_reverse_config() {
    return {
        "general": { ".type": "general", ".name": "general", "reverse_only": "1" },
        "s1": {
            ".type": "servers",
            ".name": "s1",
            "vless_reverse": "1",
            "server": "198.51.100.1",
            "server_port": "443",
            "password": "00000000-0000-0000-0000-000000000001",
            "protocol": "vmess"
        }
    };
};

export function get_empty_uuid_reverse_config() {
    return {
        "general": { ".type": "general", ".name": "general", "reverse_only": "1" },
        "s1": {
            ".type": "servers",
            ".name": "s1",
            "vless_reverse": "1",
            "server": "198.51.100.1",
            "server_port": "443",
            "password": "",
            "protocol": "vless"
        }
    };
};

export function get_duplicate_outbound_tags_config() {
    return {
        "general": { ".type": "general", ".name": "general", "reverse_only": "1" },
        "s1": {
            ".type": "servers",
            ".name": "s1",
            "tag": "duplicate-tag",
            "vless_reverse": "1",
            "vless_reverse_tag": "rev-tag-1",
            "server": "198.51.100.1",
            "server_port": "443",
            "password": "00000000-0000-0000-0000-000000000001",
            "protocol": "vless"
        },
        "s2": {
            ".type": "servers",
            ".name": "s2",
            "tag": "duplicate-tag",
            "vless_reverse": "1",
            "vless_reverse_tag": "rev-tag-2",
            "server": "198.51.100.2",
            "server_port": "8443",
            "password": "00000000-0000-0000-0000-000000000002",
            "protocol": "vless"
        }
    };
};

export function get_duplicate_reverse_tags_config() {
    return {
        "general": { ".type": "general", ".name": "general", "reverse_only": "1" },
        "s1": {
            ".type": "servers",
            ".name": "s1",
            "tag": "out-tag-1",
            "vless_reverse": "1",
            "vless_reverse_tag": "duplicate-rev-tag",
            "server": "198.51.100.1",
            "server_port": "443",
            "password": "00000000-0000-0000-0000-000000000001",
            "protocol": "vless"
        },
        "s2": {
            ".type": "servers",
            ".name": "s2",
            "tag": "out-tag-2",
            "vless_reverse": "1",
            "vless_reverse_tag": "duplicate-rev-tag",
            "server": "198.51.100.2",
            "server_port": "8443",
            "password": "00000000-0000-0000-0000-000000000002",
            "protocol": "vless"
        }
    };
};

export function get_normal_server_blank_reverse_tag_config() {
    return {
        "general": { ".type": "general", ".name": "general", "reverse_only": "0", "transparent_proxy_enable": "1" },
        "s1": {
            ".type": "servers",
            ".name": "s1",
            "server": "203.0.113.10",
            "server_port": "443",
            "password": "11111111-1111-1111-1111-111111111111",
            "protocol": "vless",
            "vless_reverse_tag": "",
            "reverse_tag": ""
        }
    };
};

export function get_reverse_with_custom_mark_config() {
    return {
        "general": { ".type": "general", ".name": "general", "reverse_only": "1" },
        "s1": {
            ".type": "servers",
            ".name": "s1",
            "tag": "rev-custom",
            "vless_reverse": "1",
            "vless_reverse_tag": "rev-custom-in",
            "server": "198.51.100.1",
            "server_port": "443",
            "password": "00000000-0000-0000-0000-000000000001",
            "protocol": "vless",
            "custom_config": "{\"streamSettings\":{\"sockopt\":{\"mark\":253}}}"
        }
    };
};

export function get_reserved_tag_reverse_config() {
    return {
        "general": { ".type": "general", ".name": "general", "reverse_only": "1" },
        "s1": {
            ".type": "servers",
            ".name": "s1",
            "tag": "reverse-egress",
            "vless_reverse": "1",
            "server": "198.51.100.1",
            "server_port": "443",
            "password": "00000000-0000-0000-0000-000000000001",
            "protocol": "vless"
        }
    };
};

export function get_reserved_reverse_tag_config() {
    return {
        "general": { ".type": "general", ".name": "general", "reverse_only": "1" },
        "s1": {
            ".type": "servers",
            ".name": "s1",
            "tag": "rev-link-1",
            "vless_reverse": "1",
            "vless_reverse_tag": "reverse-egress",
            "server": "198.51.100.1",
            "server_port": "443",
            "password": "00000000-0000-0000-0000-000000000001",
            "protocol": "vless"
        }
    };
};

export function get_alias_variant_configs() {
    return {
        "cfg_alias1": {
            "general": { ".type": "general", ".name": "general", "reverse_only": "1" },
            "srv_section_1": {
                ".type": "servers",
                ".name": "srv_section_1",
                "alias": "Human Readable Name 1",
                "vless_reverse": "1",
                "server": "198.51.100.1",
                "server_port": "443",
                "password": "00000000-0000-0000-0000-000000000001",
                "protocol": "vless"
            }
        },
        "cfg_alias2": {
            "general": { ".type": "general", ".name": "general", "reverse_only": "1" },
            "srv_section_1": {
                ".type": "servers",
                ".name": "srv_section_1",
                "alias": "Different Name 2",
                "vless_reverse": "1",
                "server": "198.51.100.1",
                "server_port": "443",
                "password": "00000000-0000-0000-0000-000000000001",
                "protocol": "vless"
            }
        },
        "cfg_explicit_tag": {
            "general": { ".type": "general", ".name": "general", "reverse_only": "1" },
            "srv_section_1": {
                ".type": "servers",
                ".name": "srv_section_1",
                "tag": "custom-explicit-tag",
                "alias": "Different Name 2",
                "vless_reverse": "1",
                "server": "198.51.100.1",
                "server_port": "443",
                "password": "00000000-0000-0000-0000-000000000001",
                "protocol": "vless"
            }
        }
    };
};
