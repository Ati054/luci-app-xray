"use strict";

import { cursor } from "uci";

export function load_config() {
    const uci = cursor();
    if (!uci.load("xray_core")) {
        die("Failed to load UCI configuration for xray_core");
    }
    const data = uci.get_all("xray_core");
    if (!data) {
        die("Failed to retrieve UCI configuration data for xray_core");
    }
    return data;
};
