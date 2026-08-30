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

    load: function() {
        return callProfilesList().catch(function() {
            return { ok: false, profiles: [], summary: {} };
        });
    },

    render: function(data) {
        var viewContainer = E('div', { 'class': 'cbi-map' });

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
                ' | ', E('strong', {}, _('Активных: ')), E('span', { 'class': 'badge success' }, summary.running_count || 0)
            ])
        ]);
        statusContainer.appendChild(cards);

        // 2. Render Profiles Table
        dom.content(tableContainer, null);
        var table = E('table', { 'class': 'table cbi-section-table' }, [
            E('tr', { 'class': 'tr cbi-section-table-titles' }, [
                E('th', { 'class': 'th' }, _('Название профиля')),
                E('th', { 'class': 'th' }, _('Имя файла JSON')),
                E('th', { 'class': 'th' }, _('Размер')),
                E('th', { 'class': 'th' }, _('SHA-256')),
                E('th', { 'class': 'th' }, _('Статус процесса')),
                E('th', { 'class': 'th' }, _('Автозапуск')),
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

        tableContainer.appendChild(E('div', { 'class': 'cbi-section' }, [ table ]));
    },

    renderProfileRow: function(p) {
        var self = this;
        var statusBadge = p.running ?
            E('span', { 'class': 'label success' }, _('Работает (PID: %d)').format(p.pid || 0)) :
            E('span', { 'class': 'label' }, _('Остановлен'));

        var geodata = p.geodata || {};
        var missingGeodata = Array.isArray(geodata.missing) ? geodata.missing : [];
        var statusContent = [ statusBadge ];
        if (missingGeodata.length > 0) {
            statusContent.push(E('div', {
                'class': 'alert-message warning',
                'style': 'margin-top: 6px; padding: 4px 6px; font-size: 85%;'
            }, _('Профилю требуются отсутствующие файлы: %s').format(missingGeodata.join(', '))));
        }

        var autostartBtn = E('button', {
            'class': 'btn cbi-button ' + (p.autostart ? 'cbi-button-positive' : 'cbi-button-neutral'),
            'style': 'padding: 2px 8px; font-size: 90%;',
            'click': function() {
                callProfilesSetAutostart(p.id, !p.autostart).then(function() {
                    ui.addNotification(null, E('p', {}, _('Автозапуск для профиля «%s» изменен.').format(p.name)), 'info');
                });
            }
        }, p.autostart ? _('Включен') : _('Выключен'));

        var actions = E('div', { 'class': 'right' }, [
            p.running ?
                E('button', {
                    'class': 'btn cbi-button cbi-button-reset',
                    'style': 'margin-right: 4px;',
                    'click': function() {
                        callProfilesStop(p.id).then(function() {
                            ui.addNotification(null, E('p', {}, _('Профиль «%s» остановлен.').format(p.name)), 'info');
                        });
                    }
                }, _('Остановить')) :
                E('button', {
                    'class': 'btn cbi-button cbi-button-action',
                    'style': 'margin-right: 4px;',
                    'click': function() {
                        callProfilesStart(p.id).then(function(res) {
                            if (res && res.ok) {
                                ui.addNotification(null, E('p', {}, _('Профиль «%s» запущен.').format(p.name)), 'info');
                            } else {
                                ui.addNotification(null, E('p', {}, _('Ошибка запуска: %s').format(res.error || 'не удалось запустить процесс')), 'error');
                            }
                        });
                    }
                }, _('Запустить')),

            E('button', {
                'class': 'btn cbi-button',
                'style': 'margin-right: 4px;',
                'click': function() {
                    callProfilesRestart(p.id).then(function(res) {
                        if (res && res.ok) {
                            ui.addNotification(null, E('p', {}, _('Профиль «%s» перезапущен.').format(p.name)), 'info');
                        } else {
                            ui.addNotification(null, E('p', {}, _('Ошибка перезапуска: %s').format(res.error || 'не удалось перезапустить')), 'error');
                        }
                    });
                }
            }, _('Перезапуск')),

            E('button', {
                'class': 'btn cbi-button',
                'style': 'margin-right: 4px;',
                'title': _('Переименовать профиль'),
                'click': function() {
                    self.handleRenameModal(p);
                }
            }, _('Имя')),

            E('button', {
                'class': 'btn cbi-button',
                'style': 'margin-right: 4px;',
                'title': _('Переместить вверх'),
                'click': function() {
                    callProfilesReorder(p.id, 'up');
                }
            }, '▲'),

            E('button', {
                'class': 'btn cbi-button',
                'style': 'margin-right: 4px;',
                'title': _('Переместить вниз'),
                'click': function() {
                    callProfilesReorder(p.id, 'down');
                }
            }, '▼'),

            E('button', {
                'class': 'btn cbi-button',
                'style': 'margin-right: 4px;',
                'click': function() {
                    self.handleReplaceModal(p);
                }
            }, _('Заменить')),

            E('button', {
                'class': 'btn cbi-button cbi-button-negative',
                'click': function() {
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
                }
            }, _('Удалить'))
        ]);

        return E('tr', { 'class': 'tr cbi-rowstyle-1' }, [
            E('td', { 'class': 'td' }, E('strong', {}, p.name)),
            E('td', { 'class': 'td' }, E('code', {}, p.filename)),
            E('td', { 'class': 'td' }, '%d B'.format(p.size)),
            E('td', { 'class': 'td' }, E('code', {}, p.sha256 || '-')),
            E('td', { 'class': 'td' }, statusContent),
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
