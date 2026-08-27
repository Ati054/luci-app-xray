"use strict";

import { cursor } from "uci";

export function load_config() {
    try {
        const uci = cursor();
        uci.load("xray_core");
        return uci.get_all("xray_core") || {};
    } catch (e) {
        return {};
    }
};
