"use strict";

import { port_array, stream_settings } from "../common/stream.mjs";
import { fallbacks, reality_inbound_settings, tls_inbound_settings } from "../common/tls.mjs";

function vless_inbound_user(k, flow) {
    return {
        id: k,
        email: k,
        flow: flow,
    };
}

export function vless_outbound(server, tag) {
    let flow = null;
    if (server["vless_tls"] == "tls") {
        flow = server["vless_flow_tls"];
    } else if (server["vless_tls"] == "reality") {
        flow = server["vless_flow_reality"];
    }
    if (flow == "none") {
        flow = null;
    }
    const stream_settings_object = stream_settings(server, "vless", tag);
    const stream_settings_result = stream_settings_object["stream_settings"];
    const dialer_proxy = stream_settings_object["dialer_proxy"];
    const is_reverse = server["reverse"] == "1" || server["vless_reverse"] == "1" || server["reverse_tag"] != null || server["vless_reverse_tag"] != null;

    if (is_reverse) {
        const ports = port_array(server["server_port"]);
        if (length(ports) != 1 || !server["server"]) {
            die("Reverse VLESS outbound requires exactly one server endpoint and port");
        }
        const reverse_tag = server["reverse_tag"] || server["vless_reverse_tag"] || `reverse_${tag}`;
        let reverse_settings = {
            address: server["server"],
            port: ports[0],
            id: server["password"],
            encryption: server["vless_encryption"] || "none",
            reverse: {
                tag: reverse_tag
            }
        };
        if (flow != null && flow != "none" && flow != "") {
            reverse_settings["flow"] = flow;
        }
        return {
            outbound: {
                protocol: "vless",
                tag: tag,
                settings: reverse_settings,
                streamSettings: stream_settings_result
            },
            dialer_proxy: dialer_proxy
        };
    }

    return {
        outbound: {
            protocol: "vless",
            tag: tag,
            settings: {
                vnext: map(port_array(server["server_port"]), function (v) {
                    return {
                        address: server["server"],
                        port: v,
                        users: [
                            {
                                email: server["username"],
                                id: server["password"],
                                flow: flow,
                                encryption: server["vless_encryption"] || "none"
                            }
                        ]
                    };
                })
            },
            streamSettings: stream_settings_result
        },
        dialer_proxy: dialer_proxy
    };
};

export function https_vless_inbound(proxy, config) {
    let flow = null;
    if (proxy["vless_tls"] == "tls") {
        flow = proxy["vless_flow_tls"];
    } else if (proxy["vless_tls"] == "reality") {
        flow = proxy["vless_flow_reality"];
    }
    if (flow == "none") {
        flow = null;
    }
    return {
        port: proxy["web_server_port"] || 443,
        protocol: "vless",
        tag: "https_inbound",
        settings: {
            clients: map(proxy["web_server_password"], k => vless_inbound_user(k, flow)),
            decryption: proxy["vless_decryption"] || "none",
            fallbacks: fallbacks(proxy, config)
        },
        streamSettings: {
            network: "tcp",
            security: proxy["vless_tls"],
            tlsSettings: proxy["vless_tls"] == "tls" ? tls_inbound_settings(proxy, "vless") : null,
            realitySettings: proxy["vless_tls"] == "reality" ? reality_inbound_settings(proxy, "vless") : null,
        }
    };
};
