#!/usr/bin/ucode
"use strict";

import { gen_config } from "./gen_config.mjs";

if (!sourcepath(1)) {
    printf("%.4J\n", gen_config(getenv("UCI_CONFIG_DIR")));
}
