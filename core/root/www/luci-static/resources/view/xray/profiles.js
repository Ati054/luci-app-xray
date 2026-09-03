'use strict';
'require view';
'require dom';
'require poll';
'require rpc';
'require ui';

var callProfilesList = rpc.declare({
    object: 'xray_profiles',
    method: 'list',
    expect: { '': {} }
});

var callProfilesImport = rpc.declare({
    object: 'xray_profiles',
    method: 'import',
    params: ['name', 'filename', 'content', 'autostart'],
    expect: { '': {} }
});

var callProfilesReplace = rpc.declare({
    object: 'xray_profiles',
    method: 'replace',
    params: ['id', 'content'],
    expect: { '': {} }
});

var callProfilesValidate = rpc.declare({
    object: 'xray_profiles',
    method: 'validate',
    params: ['content'],
    expect: { '': {} }
});

var callProfilesStart = rpc.declare({
    object: 'xray_profiles',
    method: 'start',
    params: ['id'],
    expect: { '': {} }
});

var callProfilesStop = rpc.declare({
    object: 'xray_profiles',
    method: 'stop',
    params: ['id'],
    expect: { '': {} }
});

var callProfilesRestart = rpc.declare({
    object: 'xray_profiles',
    method: 'restart',
    params: ['id'],
    expect: { '': {} }
});

var callProfilesSetAutostart = rpc.declare({
    object: 'xray_profiles',
    method: 'set_autostart',
    params: ['id', 'autostart'],
    expect: { '': {} }
});

var callProfilesRename = rpc.declare({
    object: 'xray_profiles',
    method: 'rename',
    params: ['id', 'name'],
    expect: { '': {} }
});

var callProfilesReorder = rpc.declare({
    object: 'xray_profiles',
    method: 'reorder',
    params: ['id', 'direction'],
    expect: { '': {} }
});

var callProfilesDelete = rpc.declare({
    object: 'xray_profiles',
    method: 'delete',
    params: ['id'],
    expect: { '': {} }
});

var callProfilesEnableService = rpc.declare({
    object: 'xray_profiles',
    method: 'enable_service',
    expect: { '': {} }
});

var callProfilesDisableService = rpc.declare({
    object: 'xray_profiles',
    method: 'disable_service',
    expect: { '': {} }
});

var callProfilesDisableLegacy = rpc.declare({
    object: 'xray_profiles',
    method: 'disable_legacy',
    expect: { '': {} }
});

return view.extend({
    handleSave: null,
    handleSaveApply: null,
    handleReset: null,
    refreshInFlight: null,
    trafficSnapshots: {},
    cpuSnapshot: null,

    formatMetricNumber: function(value) {
        if (value >= 100) return value.toFixed(0);
        return value.toFixed(1).replace(/\.0$/, '');
    },

    formatBitRate: function(bitsPerSecond) {
        if (bitsPerSecond == null || !isFinite(bitsPerSecond)) return '—';
        var value = Math.max(0, bitsPerSecond);
        var units = [ 'bps', 'Kbps', 'Mbps', 'Gbps', 'Tbps' ];
        var unit = 0;
        while (value >= 1000 && unit < units.length - 1) {
            value /= 1000;
            unit++;
        }
        return unit === 0 ? '%d %s'.format(Math.round(value), units[unit]) :
            '%s %s'.format(this.formatMetricNumber(value), units[unit]);
    },

    formatBytes: function(bytes) {
        if (bytes == null || !isFinite(bytes)) return '—';
        var value = Math.max(0, bytes);
        var units = [ 'B', 'KB', 'MB', 'GB', 'TB' ];
        var unit = 0;
        while (value >= 1024 && unit < units.length - 1) {
            value /= 1024;
            unit++;
        }
        return unit === 0 ? '%d %s'.format(Math.round(value), units[unit]) :
            '%s %s'.format(this.formatMetricNumber(value), units[unit]);
    },

    formatDuration: function(seconds) {
        if (seconds == null || !isFinite(seconds) || seconds < 0) return '—';
        var total = Math.floor(seconds);
        var days = Math.floor(total / 86400);
        var hours = Math.floor((total % 86400) / 3600);
        var minutes = Math.floor((total % 3600) / 60);
        var secs = total % 60;
        if (days > 0) return _('%d д %d ч').format(days, hours);
        if (hours > 0) return _('%d ч %d мин').format(hours, minutes);
        if (minutes > 0) return _('%d мин %d с').format(minutes, secs);
        return _('%d с').format(secs);
    },

    renderHardwareHealth: function(summary) {
        var hardware = summary.hardware || {};
        var temperatureText = hardware.temperature_available &&
            Number.isFinite(Number(hardware.temperature_millidegrees)) ?
            _('%s °C').format((Number(hardware.temperature_millidegrees) / 1000).toFixed(1)) : '—';
        var temperatureTitle = hardware.temperature_available ?
            _('Температура CPU Raspberry Pi. Обновляется каждые 5 секунд.') :
            _('Датчик температуры недоступен на этом устройстве.');
        var cpuText = '—';
        var cpuTotal = Number(hardware.cpu_total_ticks);
        var cpuIdle = Number(hardware.cpu_idle_ticks);
        if (hardware.cpu_available && Number.isFinite(cpuTotal) && Number.isFinite(cpuIdle)) {
            if (this.cpuSnapshot && cpuTotal > this.cpuSnapshot.total && cpuIdle >= this.cpuSnapshot.idle) {
                var totalDelta = cpuTotal - this.cpuSnapshot.total;
                var idleDelta = Math.min(totalDelta, cpuIdle - this.cpuSnapshot.idle);
                cpuText = _('%s%%').format(((totalDelta - idleDelta) * 100 / totalDelta).toFixed(1));
            }
            this.cpuSnapshot = { total: cpuTotal, idle: cpuIdle };
        } else {
            this.cpuSnapshot = null;
        }

        var children = [
            E('span', {
                'class': 'xray-hardware-temperature',
                'title': temperatureTitle,
                'tabindex': '0'
            }, [ E('strong', {}, _('Температура: ')), temperatureText ]),
            E('span', {
                'class': 'xray-hardware-cpu',
                'title': hardware.cpu_available ?
                    _('Средняя загрузка всех ядер CPU между двумя обновлениями страницы.') :
                    _('Счётчики загрузки CPU недоступны на этом устройстве.'),
                'tabindex': '0'
            }, [ E('strong', {}, _('CPU: ')), cpuText ])
        ];

        if (hardware.power_status_available &&
                (hardware.undervoltage_now || hardware.undervoltage_occurred)) {
            var powerText = hardware.undervoltage_now ?
                _('Пониженное напряжение питания обнаружено сейчас.') :
                _('Пониженное напряжение питания фиксировалось после загрузки.');
            children.push(E('span', {
                'class': 'label ' + (hardware.undervoltage_now ? 'danger' : 'warning') + ' xray-power-warning',
                'title': powerText,
                'aria-label': powerText,
                'role': 'img',
                'tabindex': '0'
            }, '⚡'));
        }

        return E('div', { 'class': 'xray-hardware-health' }, children);
    },

    getTrafficDisplay: function(p) {
        var traffic = p.traffic || {};
        var display = { traffic: traffic, rxBps: null, txBps: null };

        if (!p.running || !traffic.available || !traffic.bytes_available) {
            delete this.trafficSnapshots[p.id];
            return display;
        }

        var now = Number(traffic.sample_time) || Date.now() / 1000;
        var rxBytes = Math.max(0, Number(traffic.rx_bytes) || 0);
        var txBytes = Math.max(0, Number(traffic.tx_bytes) || 0);
        var previous = this.trafficSnapshots[p.id];

        if (previous && previous.pid === p.pid && now > previous.sampleTime &&
                rxBytes >= previous.rxBytes && txBytes >= previous.txBytes) {
            var elapsed = now - previous.sampleTime;
            display.rxBps = (rxBytes - previous.rxBytes) * 8 / elapsed;
            display.txBps = (txBytes - previous.txBytes) * 8 / elapsed;
        } else if ((Number(traffic.connections) || 0) === 0) {
            display.rxBps = 0;
            display.txBps = 0;
        }

        this.trafficSnapshots[p.id] = {
            pid: p.pid,
            sampleTime: now,
            rxBytes: rxBytes,
            txBytes: txBytes
        };
        return display;
    },

    trafficUnavailableText: function(reason) {
        if (reason === 'stopped') return _('Профиль остановлен.');
        if (reason === 'ss_failed') return _('Не удалось прочитать TCP_INFO через ss.');
        if (reason === 'tcp_info_fields_unavailable')
            return _('Соединения найдены, но эта сборка ядра не предоставляет счётчики TCP_INFO. Ноль не подставляется.');
        return _('TCP-метрики недоступны на этом устройстве.');
    },

    renderTrafficCell: function(p, display, direction) {
        var traffic = display.traffic;
        var isRx = direction === 'rx';
        var bytes = isRx ? traffic.rx_bytes : traffic.tx_bytes;
        var rate = isRx ? display.rxBps : display.txBps;
        var directionName = isRx ? _('Принято') : _('Отправлено');
        var title;

        if (!p.running || !traffic.available || !traffic.bytes_available) {
            title = this.trafficUnavailableText(traffic.reason || (p.running ? 'ss_unavailable' : 'stopped'));
            return E('td', { 'class': 'td xray-traffic-cell', 'title': title }, [
                E('span', { 'class': 'xray-traffic-rate' }, '—'),
                E('span', { 'class': 'xray-traffic-separator', 'aria-hidden': 'true' }, '·'),
                E('span', { 'class': 'xray-traffic-total' }, _('всего —'))
            ]);
        }

        title = _('%s: текущая скорость %s; всего %s по активным TCP-соединениям текущего процесса. Счётчик сбрасывается при перезапуске процесса или соединения.')
            .format(directionName, this.formatBitRate(rate), this.formatBytes(bytes));
        return E('td', { 'class': 'td xray-traffic-cell', 'title': title }, [
            E('span', { 'class': 'xray-traffic-rate' }, this.formatBitRate(rate)),
            E('span', { 'class': 'xray-traffic-separator', 'aria-hidden': 'true' }, '·'),
            E('span', { 'class': 'xray-traffic-total' }, _('всего %s').format(this.formatBytes(bytes)))
        ]);
    },

    load: function() {
        return callProfilesList().catch(function() {
            return { ok: false, profiles: [], summary: {} };
        });
    },

    render: function(data) {
        this.trafficSnapshots = {};
        this.cpuSnapshot = null;
        var viewContainer = E('div', { 'class': 'cbi-map' });

        viewContainer.appendChild(E('style', {}, `
            .xray-profile-cell { min-width: 10.5rem; }
            .xray-profile-name { display: block; cursor: help; text-decoration: underline dotted; text-underline-offset: .2em; }
            .xray-profile-stack { display: block; margin-top: .2rem; max-width: 18rem; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; font-size: 80%; font-weight: 400; opacity: .72; }
            .xray-profile-name:focus-visible, .xray-process-indicator:focus-visible, .xray-hardware-temperature:focus-visible, .xray-hardware-cpu:focus-visible, .xray-power-warning:focus-visible { outline: 2px solid currentColor; outline-offset: 3px; }
            .xray-status-cell { width: 3.5rem; text-align: center; }
            .xray-process-indicator { display: inline-flex; min-width: 1.65rem; min-height: 1.65rem; align-items: center; justify-content: center; cursor: help; font-size: 1rem; }
            .xray-traffic-cell { min-width: 10rem; white-space: nowrap; font-variant-numeric: tabular-nums; }
            .xray-traffic-rate { display: inline; font-weight: 600; }
            .xray-traffic-separator { margin: 0 .35rem; opacity: .45; }
            .xray-traffic-total { display: inline; font-size: 85%; opacity: .72; }
            .xray-link-cell { min-width: 8rem; white-space: nowrap; font-variant-numeric: tabular-nums; }
            .xray-link-cell > span { display: block; }
            .xray-link-uptime { margin-top: .15rem; font-size: 85%; opacity: .72; }
            .xray-autostart-toggle { min-width: 3.6rem; padding: 2px 7px !important; font-size: 85% !important; }
            .xray-profile-actions { display: flex; justify-content: flex-end; gap: 3px; flex-wrap: nowrap; }
            .xray-profile-actions .btn { margin: 0 !important; }
            .xray-action-btn { box-sizing: border-box; min-width: 2rem; padding: 2px 6px !important; font-size: 1rem !important; line-height: 1.35 !important; text-align: center; }
            .xray-hardware-health { display: flex; align-items: center; gap: .45rem; margin-top: .55rem; min-height: 1.4rem; font-variant-numeric: tabular-nums; }
            .xray-hardware-temperature, .xray-hardware-cpu { cursor: help; white-space: nowrap; }
            .xray-power-warning { display: inline-flex; align-items: center; justify-content: center; min-width: 1.35rem; cursor: help; font-size: 1rem; line-height: 1.35; }
            .xray-table-scroll { overflow-x: auto; }
        `));

        // Header Title
        viewContainer.appendChild(E('h2', {}, _('Xray Reverse — Управление профилями')));
        viewContainer.appendChild(E('div', { 'class': 'cbi-map-descr' },
            _('Автономный запуск независимых JSON-профилей VLESS Reverse с полной изоляцией процессов.')
        ));

        // Dynamic State Containers
        var statusContainer = E('div', { 'id': 'xray-status-container' });
        var tableContainer = E('div', { 'id': 'xray-profiles-table' });
        viewContainer.appendChild(statusContainer);

        // Top Action Bar
        var self = this;
        var actionBar = E('div', { 'class': 'cbi-page-actions', 'style': 'margin-bottom: 1em; display: flex; gap: 8px; flex-wrap: wrap;' }, [
            E('button', {
                'class': 'btn cbi-button cbi-button-action',
                'click': ui.createHandlerFn(this, 'handleImportModal')
            }, _('Импортировать JSON-профиль')),
            E('button', {
                'class': 'btn cbi-button',
                'click': ui.createHandlerFn(this, 'handleStandaloneValidateModal')
            }, _('Проверить JSON-файл'))
        ]);
        viewContainer.appendChild(actionBar);
        viewContainer.appendChild(tableContainer);

        this.updateView(data, statusContainer, tableContainer);

        // Poll actual process state every 5 seconds (non-overlapping)
        poll.add(function() {
            if (self.refreshInFlight)
                return self.refreshInFlight;

            self.refreshInFlight = callProfilesList().then(function(newData) {
                self.updateView(newData, statusContainer, tableContainer);
            }).catch(function() {}).finally(function() {
                self.refreshInFlight = null;
            });

            return self.refreshInFlight;
        }, 5);

        return viewContainer;
    },

    updateView: function(data, statusContainer, tableContainer) {
        var summary = (data && data.summary) ? data.summary : {};
        var profiles = (data && Array.isArray(data.profiles)) ? data.profiles : [];

        // 1. Render Status Cards
        dom.content(statusContainer, null);

        if (summary.legacy_running) {
            statusContainer.appendChild(E('div', { 'class': 'alert-message warning' }, [
                E('h4', {}, _('Внимание: запущен устаревший сервис xray_core')),
                E('p', {}, _('Для стабильной работы режима Reverse-профилей рекомендуется остановить и отключить сервис xray_core.')),
                E('button', {
                    'class': 'btn cbi-button cbi-button-negative',
                    'click': function() {
                        callProfilesDisableLegacy().then(function() {
                            ui.addNotification(null, E('p', {}, _('Сервис xray_core остановлен и отключен.')), 'info');
                        }).catch(function(e) {
                            ui.addNotification(null, E('p', {}, _('Ошибка отключения: %s').format(e.message || e)), 'error');
                        });
                    }
                }, _('Остановить и отключить xray_core'))
            ]));
        }

        var binStatusBadge = summary.binary_found ?
            E('span', { 'class': 'label success' }, summary.binary_version || _('Установлен')) :
            E('span', { 'class': 'label danger' }, _('Не найден'));
            
        var binPathText = summary.binary_path || '/opt/xray/current/xray';

        var serviceStatusBadge = summary.service_enabled ?
            E('span', { 'class': 'label success' }, _('Включен в автозагрузку')) :
            E('span', { 'class': 'label' }, _('Отключен'));

        var serviceToggleBtn = summary.service_enabled ?
            E('button', {
                'class': 'btn cbi-button cbi-button-reset',
                'style': 'padding: 2px 8px; font-size: 85%; margin-left: 8px;',
                'click': function() {
                    callProfilesDisableService().then(function() {
                        ui.addNotification(null, E('p', {}, _('Автозагрузка сервиса отключена.')), 'info');
                    });
                }
            }, _('Отключить')) :
            E('button', {
                'class': 'btn cbi-button cbi-button-action',
                'style': 'padding: 2px 8px; font-size: 85%; margin-left: 8px;',
                'click': function() {
                    callProfilesEnableService().then(function() {
                        ui.addNotification(null, E('p', {}, _('Автозагрузка сервиса включена.')), 'info');
                    });
                }
            }, _('Включить'));

        var cards = E('div', { 'class': 'cbi-section', 'style': 'display: flex; flex-wrap: wrap; gap: 10px; margin-bottom: 1.5em;' }, [
            E('div', { 'class': 'cbi-value', 'style': 'flex: 1 1 200px; padding: 10px; border: 1px solid #e0e0e0; border-radius: 4px;' }, [
                E('strong', {}, _('Xray (%s): ').format(binPathText)), binStatusBadge
            ]),
            E('div', { 'class': 'cbi-value', 'style': 'flex: 1 1 200px; padding: 10px; border: 1px solid #e0e0e0; border-radius: 4px;' }, [
                E('strong', {}, _('Сервис xray_profiles: ')), serviceStatusBadge, serviceToggleBtn
            ]),
            E('div', { 'class': 'cbi-value', 'style': 'flex: 1 1 200px; padding: 10px; border: 1px solid #e0e0e0; border-radius: 4px;' }, [
                E('strong', {}, _('Сохраненных: ')), E('span', { 'class': 'badge' }, summary.stored_count || 0),
                ' | ', E('strong', {}, _('Активных: ')), E('span', { 'class': 'badge success' }, summary.running_count || 0),
                this.renderHardwareHealth(summary)
            ])
        ]);
        statusContainer.appendChild(cards);

        // 2. Render Profiles Table
        dom.content(tableContainer, null);
        var table = E('table', { 'class': 'table cbi-section-table' }, [
            E('tr', { 'class': 'tr cbi-section-table-titles' }, [
                E('th', { 'class': 'th' }, _('Название профиля')),
                E('th', { 'class': 'th xray-status-cell' }, _('Статус')),
                E('th', { 'class': 'th' }, _('↓ Принято')),
                E('th', { 'class': 'th' }, _('↑ Отправлено')),
                E('th', { 'class': 'th' }, _('Связь')),
                E('th', { 'class': 'th' }, _('Авто')),
                E('th', { 'class': 'th right' }, _('Действия'))
            ])
        ]);

        if (profiles.length === 0) {
            table.appendChild(E('tr', { 'class': 'tr' }, [
                E('td', { 'class': 'td', 'colspan': 7, 'style': 'text-align: center; color: #888;' },
                    _('Нет загруженных профилей. Нажмите «Импортировать JSON-профиль» для добавления.')
                )
            ]));
        } else {
            // Sort profiles by display order
            profiles.sort(function(a, b) {
                return (a.order || 0) - (b.order || 0);
            });
            for (var i = 0; i < profiles.length; i++) {
                table.appendChild(this.renderProfileRow(profiles[i]));
            }
        }

        tableContainer.appendChild(E('div', { 'class': 'cbi-section xray-table-scroll' }, [ table ]));
    },

    renderProfileRow: function(p) {
        var self = this;
        var geodata = p.geodata || {};
        var missingGeodata = Array.isArray(geodata.missing) ? geodata.missing : [];
        var trafficDisplay = this.getTrafficDisplay(p);
        var traffic = trafficDisplay.traffic;
        var statusLines = [ p.running ? _('Состояние: работает') : _('Состояние: остановлен') ];
        if (p.running) statusLines.push(_('PID: %d').format(p.pid || 0));
        if ((p.respawn_count || 0) > 0) statusLines.push(_('Перезапусков procd: %d').format(p.respawn_count));
        if (p.running && traffic.available)
            statusLines.push(_('Активных TCP-соединений: %d').format(traffic.connections || 0));
        if (missingGeodata.length > 0)
            statusLines.push(_('Отсутствуют обязательные файлы: %s').format(missingGeodata.join(', ')));
        var statusTitle = statusLines.join('\n');
        var statusClass = missingGeodata.length > 0 ? 'label danger' : (p.running ? 'label success' : 'label');
        var statusIcon = E('span', {
            'class': statusClass + ' xray-process-indicator',
            'role': 'img',
            'tabindex': '0',
            'title': statusTitle,
            'aria-label': statusTitle
        }, missingGeodata.length > 0 ? '!' : (p.running ? '●' : '○'));

        var autostartBtn = E('button', {
            'type': 'button',
            'class': 'btn cbi-button xray-autostart-toggle ' + (p.autostart ? 'cbi-button-positive' : 'cbi-button-neutral'),
            'aria-pressed': p.autostart ? 'true' : 'false',
            'title': p.autostart ?
                _('Автозапуск включён. Нажмите, чтобы выключить.') :
                _('Автозапуск выключен. Нажмите, чтобы включить.'),
            'click': function() {
                callProfilesSetAutostart(p.id, !p.autostart).then(function() {
                    ui.addNotification(null, E('p', {}, _('Автозапуск для профиля «%s» изменен.').format(p.name)), 'info');
                });
            }
        }, p.autostart ? _('✓ Авто') : _('○ Авто'));

        var linkTitle = p.running ?
            _('RTT берётся из TCP_INFO активных соединений и не является ICMP ping. Uptime — время работы текущего процесса Xray.') :
            _('Профиль остановлен.');
        var linkCell = E('td', { 'class': 'td xray-link-cell', 'title': linkTitle }, [
            E('span', {}, _('RTT %s').format(
                p.running && traffic.available && traffic.rtt_ms != null ?
                    _('%d ms').format(traffic.rtt_ms) : '—'
            )),
            E('span', { 'class': 'xray-link-uptime' }, _('uptime %s').format(
                p.running ? this.formatDuration(traffic.uptime_seconds) : '—'
            ))
        ]);

        var actionButton = function(extraClass, symbol, label, handler) {
            return E('button', {
                'type': 'button',
                'class': 'btn cbi-button xray-action-btn ' + (extraClass || ''),
                'title': label,
                'aria-label': label,
                'click': handler
            }, symbol);
        };

        var actions = E('div', { 'class': 'right xray-profile-actions' }, [
            p.running ?
                actionButton('cbi-button-reset', '■', _('Остановить профиль'), function() {
                    callProfilesStop(p.id).then(function() {
                        ui.addNotification(null, E('p', {}, _('Профиль «%s» остановлен.').format(p.name)), 'info');
                    });
                }) :
                actionButton('cbi-button-action', '▶', _('Запустить профиль'), function() {
                    callProfilesStart(p.id).then(function(res) {
                        if (res && res.ok) {
                            ui.addNotification(null, E('p', {}, _('Профиль «%s» запущен.').format(p.name)), 'info');
                        } else {
                            ui.addNotification(null, E('p', {}, _('Ошибка запуска: %s').format(res.error || 'не удалось запустить процесс')), 'error');
                        }
                    });
                }),

            actionButton('', '↻', _('Перезапустить профиль'), function() {
                callProfilesRestart(p.id).then(function(res) {
                    if (res && res.ok) {
                        ui.addNotification(null, E('p', {}, _('Профиль «%s» перезапущен.').format(p.name)), 'info');
                    } else {
                        ui.addNotification(null, E('p', {}, _('Ошибка перезапуска: %s').format(res.error || 'не удалось перезапустить')), 'error');
                    }
                });
            }),

            actionButton('', '✎', _('Переименовать профиль'), function() {
                self.handleRenameModal(p);
            }),

            actionButton('', '▲', _('Переместить вверх'), function() {
                callProfilesReorder(p.id, 'up');
            }),

            actionButton('', '▼', _('Переместить вниз'), function() {
                callProfilesReorder(p.id, 'down');
            }),

            actionButton('', '⇄', _('Заменить JSON-профиль'), function() {
                self.handleReplaceModal(p);
            }),

            actionButton('cbi-button-negative', '×', _('Удалить профиль'), function() {
                ui.showModal(_('Удаление профиля'), [
                    E('p', {}, _('Вы действительно хотите удалить профиль «%s» (%s)?').format(p.name, p.filename)),
                    E('p', { 'class': 'cbi-map-descr' }, _('Файл профиля будет безопасно перемещен в архив .trash/.')),
                    E('div', { 'class': 'right' }, [
                        E('button', { 'class': 'btn', 'click': ui.hideModal }, _('Отмена')),
                        ' ',
                        E('button', {
                            'class': 'btn cbi-button-negative',
                            'click': function() {
                                callProfilesDelete(p.id).then(function() {
                                    ui.hideModal();
                                    ui.addNotification(null, E('p', {}, _('Профиль «%s» удален.').format(p.name)), 'info');
                                });
                            }
                        }, _('Удалить'))
                    ])
                ]);
            })
        ]);

        var nameContent = [ E('strong', {
            'class': 'xray-profile-name',
            'tabindex': '0',
            'title': _('Имя файла JSON: %s').format(p.filename),
            'aria-label': _('%s. Имя файла JSON: %s').format(p.name, p.filename)
        }, p.name) ];
        if (p.protocol_stack) {
            nameContent.push(E('span', {
                'class': 'xray-profile-stack',
                'title': p.protocol_stack
            }, p.protocol_stack));
        }

        return E('tr', { 'class': 'tr cbi-rowstyle-1' }, [
            E('td', { 'class': 'td xray-profile-cell' }, nameContent),
            E('td', { 'class': 'td xray-status-cell' }, statusIcon),
            this.renderTrafficCell(p, trafficDisplay, 'rx'),
            this.renderTrafficCell(p, trafficDisplay, 'tx'),
            linkCell,
            E('td', { 'class': 'td' }, autostartBtn),
            E('td', { 'class': 'td right' }, actions)
        ]);
    },

    handleRenameModal: function(p) {
        var nameInput = E('input', { 'type': 'text', 'class': 'cbi-input-text', 'value': p.name });

        ui.showModal(_('Переименование профиля'), [
            E('div', { 'class': 'cbi-value' }, [
                E('label', { 'class': 'cbi-value-title' }, _('Новое название')),
                E('div', { 'class': 'cbi-value-field' }, nameInput)
            ]),
            E('div', { 'class': 'right' }, [
                E('button', { 'class': 'btn', 'click': ui.hideModal }, _('Отмена')),
                ' ',
                E('button', {
                    'class': 'btn cbi-button-action',
                    'click': function() {
                        var newName = nameInput.value ? nameInput.value.trim() : '';
                        if (!newName) return;
                        callProfilesRename(p.id, newName).then(function() {
                            ui.hideModal();
                            ui.addNotification(null, E('p', {}, _('Название профиля обновлено.')), 'info');
                        });
                    }
                }, _('Сохранить'))
            ])
        ]);
    },

    handleStandaloneValidateModal: function() {
        var fileInput = E('input', { 'type': 'file', 'accept': '.json', 'class': 'cbi-input-file' });

        ui.showModal(_('Проверка JSON-файла Reverse-профиля'), [
            E('p', { 'class': 'cbi-map-descr' },
                _('Выберите JSON-файл для проверки корректности синтаксиса, совместимости с Xray и политики безопасности.')
            ),
            E('div', { 'class': 'cbi-value' }, [
                E('label', { 'class': 'cbi-value-title' }, _('Файл конфигурации (.json)')),
                E('div', { 'class': 'cbi-value-field' }, fileInput)
            ]),
            E('div', { 'class': 'right' }, [
                E('button', { 'class': 'btn', 'click': ui.hideModal }, _('Закрыть')),
                ' ',
                E('button', {
                    'class': 'btn cbi-button-action',
                    'click': function() {
                        var file = fileInput.files[0];
                        if (!file) {
                            ui.addNotification(null, E('p', {}, _('Пожалуйста, выберите файл .json.')), 'error');
                            return;
                        }
                        var reader = new FileReader();
                        reader.onload = function(e) {
                            var content = e.target.result;
                            callProfilesValidate(content).then(function(res) {
                                if (res && res.ok) {
                                    ui.addNotification(null, E('p', {}, _('Конфигурация успешно прошла проверку Xray и политику безопасности.')), 'info');
                                } else {
                                    ui.addNotification(null, E('p', {}, _('Ошибка проверки: %s').format(res.error || 'неизвестная ошибка')), 'error');
                                }
                            }).catch(function(err) {
                                ui.addNotification(null, E('p', {}, _('Ошибка RPC: %s').format(err.message || err)), 'error');
                            });
                        };
                        reader.readAsText(file);
                    }
                }, _('Проверить'))
            ])
        ]);
    },

    handleImportModal: function() {
        var nameInput = E('input', { 'type': 'text', 'class': 'cbi-input-text', 'placeholder': 'MikroTik Channel A' });
        var fileInput = E('input', { 'type': 'file', 'accept': '.json', 'class': 'cbi-input-file' });
        var autostartCheckbox = E('input', { 'type': 'checkbox', 'class': 'cbi-input-checkbox' });

        var modalBody = E('div', {}, [
            E('p', { 'class': 'cbi-map-descr' },
                _('Выберите полный JSON-конфигурационный файл Reverse-клиента, сгенерированный на MikroTik.')
            ),
            E('div', { 'class': 'cbi-value' }, [
                E('label', { 'class': 'cbi-value-title' }, _('Название профиля')),
                E('div', { 'class': 'cbi-value-field' }, nameInput)
            ]),
            E('div', { 'class': 'cbi-value' }, [
                E('label', { 'class': 'cbi-value-title' }, _('Файл конфигурации (.json)')),
                E('div', { 'class': 'cbi-value-field' }, fileInput)
            ]),
            E('div', { 'class': 'cbi-value' }, [
                E('label', { 'class': 'cbi-value-title' }, _('Автозапуск при загрузке')),
                E('div', { 'class': 'cbi-value-field' }, autostartCheckbox)
            ])
        ]);

        ui.showModal(_('Импорт JSON-профиля'), [
            modalBody,
            E('div', { 'class': 'right' }, [
                E('button', { 'class': 'btn', 'click': ui.hideModal }, _('Отмена')),
                ' ',
                E('button', {
                    'class': 'btn cbi-button-action',
                    'click': function() {
                        var file = fileInput.files[0];
                        var name = nameInput.value ? nameInput.value.trim() : '';
                        if (!name) {
                            ui.addNotification(null, E('p', {}, _('Пожалуйста, укажите название профиля.')), 'error');
                            return;
                        }
                        if (!file) {
                            ui.addNotification(null, E('p', {}, _('Пожалуйста, выберите файл .json.')), 'error');
                            return;
                        }
                        var filename = file.name.replace(/[^a-zA-Z0-9_.-]/g, '_');
                        if (!filename.endsWith('.json')) filename += '.json';

                        var reader = new FileReader();
                        reader.onload = function(e) {
                            var content = e.target.result;
                            callProfilesImport(name, filename, content, autostartCheckbox.checked).then(function(res) {
                                ui.hideModal();
                                if (res && res.ok) {
                                    ui.addNotification(null, E('p', {}, _('Профиль «%s» успешно импортирован.').format(name)), 'info');
                                } else {
                                    ui.addNotification(null, E('p', {}, _('Ошибка импорта: %s').format(res.error || 'unknown')), 'error');
                                }
                            }).catch(function(err) {
                                ui.addNotification(null, E('p', {}, _('Ошибка RPC: %s').format(err.message || err)), 'error');
                            });
                        };
                        reader.readAsText(file);
                    }
                }, _('Импортировать'))
            ])
        ]);
    },

    handleReplaceModal: function(p) {
        var fileInput = E('input', { 'type': 'file', 'accept': '.json', 'class': 'cbi-input-file' });

        var modalBody = E('div', {}, [
            E('p', { 'class': 'cbi-map-descr' },
                _('Загрузите обновленный JSON-файл для профиля «%s» (%s). Профиль будет проверен перед атомарной заменой.').format(p.name, p.filename)
            ),
            E('div', { 'class': 'cbi-value' }, [
                E('label', { 'class': 'cbi-value-title' }, _('Новый файл конфигурации (.json)')),
                E('div', { 'class': 'cbi-value-field' }, fileInput)
            ])
        ]);

        ui.showModal(_('Замена JSON-файла профиля'), [
            modalBody,
            E('div', { 'class': 'right' }, [
                E('button', { 'class': 'btn', 'click': ui.hideModal }, _('Отмена')),
                ' ',
                E('button', {
                    'class': 'btn cbi-button-action',
                    'click': function() {
                        var file = fileInput.files[0];
                        if (!file) {
                            ui.addNotification(null, E('p', {}, _('Пожалуйста, выберите файл .json.')), 'error');
                            return;
                        }
                        var reader = new FileReader();
                        reader.onload = function(e) {
                            var content = e.target.result;
                            callProfilesReplace(p.id, content).then(function(res) {
                                ui.hideModal();
                                if (res && res.ok) {
                                    ui.addNotification(null, E('p', {}, _('Профиль «%s» успешно обновлен.').format(p.name)), 'info');
                                } else {
                                    ui.addNotification(null, E('p', {}, _('Ошибка замены: %s').format(res.error || 'unknown')), 'error');
                                }
                            }).catch(function(err) {
                                ui.addNotification(null, E('p', {}, _('Ошибка RPC: %s').format(err.message || err)), 'error');
                            });
                        };
                        reader.readAsText(file);
                    }
                }, _('Заменить'))
            ])
        ]);
    }
});
