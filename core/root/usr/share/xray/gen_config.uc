#!/usr/bin/ucode
"use strict";

import { gen_config } from "./gen_config.mjs";

printf("%.4J\n", gen_config());
