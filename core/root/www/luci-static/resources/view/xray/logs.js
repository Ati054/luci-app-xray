'use strict';
'require view';
'require dom';
'require poll';
'require rpc';
'require ui';

var callLogs = rpc.declare({
    object: 'xray_profiles',
    method: 'logs',
    params: [ 'limit' ],
    expect: { '': {} }
});

return view.extend({
    handleSave: null,
    handleSaveApply: null,
    handleReset: null,
    refreshInFlight: null,
    paused: false,
    limit: 200,
    allLines: [],

    severityClass: function(line) {
        var value = String(line || '').toLowerCase();
        if (value.indexOf('.err ') >= 0 || value.indexOf(' error') >= 0 || value.indexOf('failed') >= 0)
            return 'xray-log-error';
        if (value.indexOf('.warn ') >= 0 || value.indexOf(' warning') >= 0)
            return 'xray-log-warning';
        return 'xray-log-info';
    },

    filteredLines: function() {
        var query = String(this.searchInput ? this.searchInput.value : '').trim().toLowerCase();
        var severity = this.severitySelect ? this.severitySelect.value : 'all';

        return this.allLines.filter(L.bind(function(line) {
            if (query && String(line).toLowerCase().indexOf(query) < 0) return false;
            return severity === 'all' || this.severityClass(line) === 'xray-log-' + severity;
        }, this));
    },

    renderLines: function() {
        var lines = this.filteredLines();
        var children = [];

        if (!lines.length) {
            children.push(E('div', { 'class': 'xray-log-empty' }, _('Подходящих записей нет.')));
        } else {
            for (var i = 0; i < lines.length; i++) {
                children.push(E('div', { 'class': 'xray-log-line ' + this.severityClass(lines[i]) }, lines[i]));
            }
        }

        dom.content(this.logBox, children);
        this.counter.textContent = _('%d показано / %d получено').format(lines.length, this.allLines.length);
        this.logBox.scrollTop = this.logBox.scrollHeight;
    },

    refreshLogs: function(force) {
        if (this.paused && !force) return Promise.resolve();
        if (this.refreshInFlight) return this.refreshInFlight;

        this.refreshInFlight = callLogs(this.limit).then(L.bind(function(data) {
            if (!data || data.ok !== true || !Array.isArray(data.lines))
                throw new Error((data && data.error) || _('Не удалось прочитать журнал'));

            this.allLines = data.lines.slice(-this.limit);
            this.storageBadge.textContent = _('RAM · logd · максимум %d строк').format(data.maximum_limit || 500);
            this.renderLines();
        }, this)).catch(function(error) {
            ui.addNotification(null, E('p', {}, error.message || error));
        }).finally(L.bind(function() {
            this.refreshInFlight = null;
        }, this));

        return this.refreshInFlight;
    },

    togglePause: function() {
        this.paused = !this.paused;
        this.pauseButton.textContent = this.paused ? _('▶ Продолжить') : _('Ⅱ Пауза');
        this.pauseButton.classList.toggle('cbi-button-positive', this.paused);
        if (!this.paused) return this.refreshLogs(true);
    },

    render: function() {
        this.storageBadge = E('span', { 'class': 'label notice' }, _('RAM · logd · максимум 500 строк'));
        this.counter = E('span', { 'class': 'xray-log-counter' }, _('0 показано / 0 получено'));
        this.searchInput = E('input', {
            'type': 'search',
            'placeholder': _('Фильтр по тексту'),
            'aria-label': _('Фильтр журнала по тексту')
        });
        this.searchInput.addEventListener('input', L.bind(this.renderLines, this));

        this.severitySelect = E('select', { 'aria-label': _('Уровень журнала') }, [
            E('option', { 'value': 'all' }, _('Все уровни')),
            E('option', { 'value': 'error' }, _('Ошибки')),
            E('option', { 'value': 'warning' }, _('Предупреждения')),
            E('option', { 'value': 'info' }, _('Информация'))
        ]);
        this.severitySelect.addEventListener('change', L.bind(this.renderLines, this));

        var limitSelect = E('select', { 'aria-label': _('Количество строк') }, [
            E('option', { 'value': '100' }, _('100 строк')),
            E('option', { 'value': '200', 'selected': 'selected' }, _('200 строк')),
            E('option', { 'value': '500' }, _('500 строк'))
        ]);
        limitSelect.addEventListener('change', L.bind(function(ev) {
            this.limit = Number(ev.target.value) || 200;
            return this.refreshLogs(true);
        }, this));

        this.pauseButton = E('button', {
            'class': 'cbi-button cbi-button-neutral',
            'type': 'button',
            'click': ui.createHandlerFn(this, 'togglePause')
        }, _('Ⅱ Пауза'));

        this.logBox = E('div', {
            'class': 'xray-log-box',
            'role': 'log',
            'aria-live': 'polite',
            'aria-label': _('Журнал Xray Reverse')
        }, E('div', { 'class': 'xray-log-empty' }, _('Загрузка журнала…')));

        var root = E('div', { 'class': 'cbi-map' }, [
            E('style', {}, [
                '.xray-log-toolbar{display:flex;gap:.5rem;align-items:center;flex-wrap:wrap;margin:1rem 0}',
                '.xray-log-toolbar input{min-width:16rem;flex:1}',
                '.xray-log-counter{margin-left:auto;color:#999}',
                '.xray-log-box{height:min(62vh,42rem);overflow:auto;background:#111;color:#ddd;border:1px solid #444;border-radius:4px;padding:.65rem;font:12px/1.45 ui-monospace,SFMono-Regular,Consolas,monospace;white-space:pre-wrap;overflow-wrap:anywhere}',
                '.xray-log-line{padding:.12rem .25rem;border-left:3px solid transparent}',
                '.xray-log-warning{color:#ffd166;border-left-color:#d79b00}',
                '.xray-log-error{color:#ff8f8f;border-left-color:#e34b4b}',
                '.xray-log-info{border-left-color:#3d7ea6}',
                '.xray-log-empty{color:#999;padding:1rem;text-align:center}'
            ].join('')),
            E('h2', {}, _('Xray Reverse — Журнал')),
            E('p', {}, [
                _('Диагностические записи Xray, менеджера профилей и watchdog читаются из ограниченного RAM-буфера OpenWrt. На флешку журнал этой страницей не записывается. '),
                this.storageBadge
            ]),
            E('div', { 'class': 'xray-log-toolbar' }, [
                this.searchInput,
                this.severitySelect,
                limitSelect,
                this.pauseButton,
                E('button', {
                    'class': 'cbi-button cbi-button-action',
                    'type': 'button',
                    'click': ui.createHandlerFn(this, function() { return this.refreshLogs(true); })
                }, _('↻ Обновить')),
                E('button', {
                    'class': 'cbi-button cbi-button-neutral',
                    'type': 'button',
                    'click': ui.createHandlerFn(this, function() {
                        this.allLines = [];
                        this.renderLines();
                    })
                }, _('Очистить экран')),
                this.counter
            ]),
            this.logBox
        ]);

        poll.add(L.bind(function() { return this.refreshLogs(false); }, this), 5);
        this.refreshLogs(true);
        return root;
    }
});
