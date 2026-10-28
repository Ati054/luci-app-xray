#!/usr/bin/ucode
"use strict";

import { readfile } from "fs";

if (length(ARGV) != 1) {
    die("Usage: profile_runtime.uc <stored-profile.json>");
}

const source_path = ARGV[0];
const source_text = readfile(source_path);
if (source_text == null) {
    die(`Unable to read stored profile: ${source_path}`);
}

let config = json(source_text);
if (type(config) != "object") {
    die(`Stored profile is not a JSON object: ${source_path}`);
}

let reverse_outbounds = 0;

if (type(config["outbounds"]) == "array") {
    for (let outbound in config["outbounds"]) {
        if (type(outbound) != "object" || outbound["protocol"] != "vless") {
            continue;
        }

        if (type(outbound["settings"]) != "object" ||
            type(outbound["settings"]["reverse"]) != "object") {
            continue;
        }

        reverse_outbounds++;

        if (type(outbound["streamSettings"]) != "object") {
            outbound["streamSettings"] = {};
        }
        if (type(outbound["streamSettings"]["sockopt"]) != "object") {
            outbound["streamSettings"]["sockopt"] = {};
        }

        const sockopt = outbound["streamSettings"]["sockopt"];
        if (sockopt["tcpcongestion"] == null) {
            sockopt["tcpcongestion"] = "bbr";
        }
    }
}

if (reverse_outbounds == 0) {
    die(`Stored profile has no VLESS Reverse outbound: ${source_path}`);
}

printf("%.4J\n", config);
