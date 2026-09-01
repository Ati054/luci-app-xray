# Product

## Register

product

## Users

OpenWrt administrators who operate independent Xray VLESS Reverse profiles on a resource-constrained router. They need to understand connection health and control individual profiles quickly from LuCI without opening logs or a terminal.

## Product Purpose

Provide safe, compact management of isolated Xray Reverse profile processes: import and validate JSON, control lifecycle and autostart, and surface truthful operational state without enabling listeners, transparent proxying, or Raspberry-owned failover.

## Brand Personality

Compact, technical, trustworthy. The interface should feel native to LuCI, stay calm under frequent polling, and prioritize useful live signals over implementation metadata.

## Anti-references

- Wide metadata-first tables that spend permanent space on filenames, hashes, and byte sizes.
- Dense monitoring walls with unlabeled numbers, decorative gauges, or color-only status.
- Dashboard styling that fights the active LuCI theme or introduces a separate visual language.
- Metrics that imply precision or availability the backend cannot actually guarantee.

## Design Principles

1. Put operational signal first: state, traffic, connection age, and actionable warnings outrank file metadata.
2. Keep detail available on demand through keyboard-accessible tooltips instead of permanent columns.
3. Reuse LuCI controls, typography, colors, and responsive behavior so the page remains native to OpenWrt.
4. Preserve reverse-only isolation: observability must not add Xray API, metrics, or network listeners.
5. Degrade honestly: unavailable counters or latency show an explicit neutral state rather than fabricated zeroes.

## Accessibility & Inclusion

Target WCAG 2.1 AA. Interactive icons require visible focus, accessible names, and non-color status cues. Tooltips must work for keyboard focus as well as pointer hover. Motion must be minimal and respect reduced-motion preferences.
