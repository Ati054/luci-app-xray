'use strict';
'require view';
'require fs';
'require poll';

var helper = '/usr/libexec/xray-update';

function parseValues(stdout) {
	var result = {};
	(stdout || '').split('\n').forEach(function(line) {
		var separator = line.indexOf('=');
		if (separator > 0)
			result[line.slice(0, separator)] = line.slice(separator + 1);
	});
	return result;
}

function command(action) {
	return fs.exec(helper, [ action ]).then(function(result) {
		if (result.code !== 0)
			throw new Error((result.stderr || result.stdout || _('Операция обновления завершилась ошибкой.')).trim());
		return parseValues(result.stdout);
	});
}

return view.extend({
	load: function() {
		return command('status');
	},

	render: function(initial) {
		var current = initial || {};
		var pending = false;
		var localError = '';
		var statusBox = E('div', { 'class': 'cbi-section' });
		var releaseBox = E('div', { 'class': 'cbi-section' });
		var message = E('p', {
			'role': 'status',
			'aria-live': 'polite',
			'style': 'overflow-wrap:anywhere;min-height:1.4em'
		});
		var checkButton;
		var installButton;

		function line(label, value) {
			return E('div', { 'style': 'display:flex;gap:.6em;flex-wrap:wrap;margin:.3em 0' }, [
				E('strong', {}, label + ':'),
				E('span', {}, value || '\u2014')
			]);
		}

		function phaseMessage(info) {
			var phases = {
				checking: _('Проверяю подписанный релиз GitHub…'),
				preparing: _('Повторно проверяю релиз перед скачиванием…'),
				verifying: _('Проверяю подпись и метаданные релиза…'),
				downloading: _('Скачиваю полный офлайн-архив в RAM…'),
				extracting: _('Проверяю и распаковываю архив…'),
				installing: _('Создаю резервную копию, обновляю пакет и восстанавливаю туннели…')
			};
			return phases[info.phase] || phases[info.remote_phase] || '';
		}

		function display(info) {
			current = info || current;
			var busy = pending || current.busy === 'yes';
			var offered = current.available_version || '';
			var available = current.available === 'yes';

			checkButton.disabled = busy || !L.hasViewPermission();
			installButton.disabled = busy || !available || !L.hasViewPermission();
			installButton.hidden = !available;
			installButton.style.display = available ? '' : 'none';

			statusBox.replaceChildren(
				E('h3', {}, _('Установлено')),
				line(_('Пакет'), current.version),
				line(_('Ядро Xray'), current.xray_version)
			);

			var releaseChildren = [ E('h3', {}, _('GitHub Release')) ];
			if (offered) {
				releaseChildren.push(line(_('Пакет'), offered));
				releaseChildren.push(line(_('Ядро Xray'), current.available_xray));
				releaseChildren.push(E('p', {}, available ?
					_('Доступно новое подписанное обновление.') :
					_('Установлена актуальная версия.')));
				releaseChildren.push(E('p', {}, [
					E('a', {
						'href': 'https://github.com/Ati054/luci-app-xray/releases/tag/' + encodeURIComponent(current.available_tag || ''),
						'target': '_blank',
						'rel': 'noopener noreferrer'
					}, _('Описание релиза'))
				]));
			} else {
				releaseChildren.push(E('p', {}, _('Нажмите «Проверить обновления».')));
			}
			releaseBox.replaceChildren.apply(releaseBox, releaseChildren);

			if (current.remote_phase === 'failed' || current.phase === 'failed')
				message.textContent = current.error || _('Обновление завершилось ошибкой. Подробности сохранены в RAM до перезагрузки.');
			else if (localError)
				message.textContent = localError;
			else if (busy)
				message.textContent = phaseMessage(current) || _('Выполняется обновление…');
			else if (current.phase === 'completed')
				message.textContent = _('Обновление установлено, аппаратная проверка пройдена, прежние активные профили восстановлены.');
			else
				message.textContent = '';
		}

		function refresh() {
			return command('status').then(display).catch(function(error) {
				if (!pending)
					message.textContent = String(error);
			});
		}

		function run(action) {
			pending = true;
			localError = '';
			display(current);
			return command(action).then(refresh).catch(function(error) {
				localError = String(error);
			}).finally(function() {
				pending = false;
				display(current);
			});
		}

		checkButton = E('button', {
			'type': 'button',
			'class': 'btn cbi-button cbi-button-action',
			'click': function() { return run('check'); }
		}, _('Проверить обновления'));
		installButton = E('button', {
			'type': 'button',
			'class': 'btn cbi-button cbi-button-positive',
			'click': function() { return run('github-start'); }
		}, _('Скачать и установить'));

		display(current);
		poll.add(refresh, 3);

		return E('div', {}, [
			E('h2', {}, _('Xray Reverse — Обновление')),
			E('p', {}, _('Обновляется полный проверенный комплект: пакет LuCI, ядро Xray и его зависимости. Профили сохраняются, а активные до обновления туннели запускаются снова после аппаратной проверки.')),
			E('div', { 'style': 'display:grid;grid-template-columns:repeat(auto-fit,minmax(280px,1fr));gap:12px' }, [
				statusBox,
				releaseBox
			]),
			E('div', { 'class': 'cbi-section', 'style': 'display:flex;flex-wrap:wrap;gap:10px' }, [
				checkButton,
				installButton
			]),
			message,
			E('p', { 'class': 'cbi-value-description' }, _('Архив загружается только в RAM. Перед установкой повторно проверяются подпись релиза, архитектура, размер и SHA-256; при ошибке до транзакции система не изменяется.'))
		]);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
