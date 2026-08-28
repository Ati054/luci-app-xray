include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-xray
PKG_VERSION:=3.7.1
PKG_RELEASE:=4

PKG_LICENSE:=MPL-2.0
PKG_MAINTAINER:=yichya <mail@yichya.dev>

PKG_CONFIG_DEPENDS:= \
	CONFIG_PACKAGE_XRAY_INCLUDE_CLOUDFLARE_ORIGIN_ROOT_CA \
	CONFIG_PACKAGE_XRAY_IGNORE_TP_SPEC_DEF_GW \
	CONFIG_PACKAGE_XRAY_RESTART_DNSMASQ_ON_IFACE_CHANGE \
	CONFIG_PACKAGE_XRAY_RLIMIT_NOFILE_LARGE \
	CONFIG_PACKAGE_XRAY_RLIMIT_DATA_SMALL \
	CONFIG_PACKAGE_XRAY_RLIMIT_DATA_LARGE

LUCI_TITLE:=LuCI Xray client with modern VLESS Reverse
LUCI_DESCRIPTION:=LuCI client for Xray with modern VLESS Reverse support and optional transparent proxy features.
LUCI_DEPENDS:=+ucode +ucode-mod-uci +ucode-mod-fs +coreutils-base64 +ca-bundle +ip-full +kmod-nft-tproxy
LUCI_PKGARCH:=all

include $(TOPDIR)/feeds/luci/luci.mk

define Package/$(PKG_NAME)/config
menu "Configuration"
	depends on PACKAGE_$(PKG_NAME)

config PACKAGE_XRAY_INCLUDE_CLOUDFLARE_ORIGIN_ROOT_CA
	bool "Include Cloudflare Origin CA root certificates (for gRPC with custom domain)"
	default n

config PACKAGE_XRAY_IGNORE_TP_SPEC_DEF_GW
	bool "Do not query default gateway and don't add specific route for transparent proxy"
	default n

config PACKAGE_XRAY_RESTART_DNSMASQ_ON_IFACE_CHANGE
	bool "Restart dnsmasq on any network interface changes (for some dynamic direct rules)"
	default n

config PACKAGE_XRAY_RLIMIT_NOFILE_LARGE
	bool "Large file limit (about 51200)"
	default n

choice
	prompt "Data limit (for low-memory devices)"
	default PACKAGE_XRAY_RLIMIT_DATA_DEFAULT
	config PACKAGE_XRAY_RLIMIT_DATA_DEFAULT
		bool "Not limited"
	config PACKAGE_XRAY_RLIMIT_DATA_SMALL
		bool "Small limit (about 50MB)"
	config PACKAGE_XRAY_RLIMIT_DATA_LARGE
		bool "Large limit (about 321MB)"
endchoice

endmenu
endef

define Build/Compile
endef

define Package/$(PKG_NAME)/postinst
#!/bin/sh
if [[ -z "$${IPKG_INSTROOT}" ]]; then
	if [[ -f /etc/uci-defaults/xray_core ]]; then
		( . /etc/uci-defaults/xray_core ) && rm -f /etc/uci-defaults/xray_core
	fi
	rm -rf /tmp/luci-indexcache* /tmp/luci-modulecache
	if [ -L /usr/share/xray/xray.pid ]; then
		rm -f /usr/share/xray/xray.pid
	fi
	if [ -f /var/run/xray.pid ]; then
		PID="$$(cat /var/run/xray.pid 2>/dev/null)"
		if [ -z "$$PID" ] || ! kill -0 "$$PID" 2>/dev/null; then
			rm -f /var/run/xray.pid
		fi
	fi
fi
exit 0
endef

define Package/$(PKG_NAME)/conffiles
/etc/config/xray_core
endef

define Package/$(PKG_NAME)/install
	$(INSTALL_DIR) $(1)/etc/luci-uploads/xray
	$(INSTALL_DIR) $(1)/etc/ssl/certs
ifdef CONFIG_PACKAGE_XRAY_INCLUDE_CLOUDFLARE_ORIGIN_ROOT_CA
	$(INSTALL_DATA) ./root/etc/ssl/certs/origin_ca_ecc_root.pem $(1)/etc/ssl/certs/origin_ca_ecc_root.pem
	$(INSTALL_DATA) ./root/etc/ssl/certs/origin_ca_rsa_root.pem $(1)/etc/ssl/certs/origin_ca_rsa_root.pem
endif
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./root/etc/init.d/xray_core $(1)/etc/init.d/xray_core
	$(INSTALL_BIN) ./root/etc/init.d/xray_profiles $(1)/etc/init.d/xray_profiles
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_DATA) ./root/etc/config/xray_core $(1)/etc/config/xray_core
	$(INSTALL_DIR) $(1)/etc/uci-defaults
	$(INSTALL_BIN) ./root/etc/uci-defaults/xray_core $(1)/etc/uci-defaults/xray_core
	$(INSTALL_DIR) $(1)/etc/hotplug.d/iface
	$(INSTALL_BIN) ./root/etc/hotplug.d/iface/01-transparent-proxy-ipset $(1)/etc/hotplug.d/iface/01-transparent-proxy-ipset
	$(INSTALL_DIR) $(1)/www/luci-static/resources/view/xray
	$(INSTALL_DATA) ./root/www/luci-static/resources/view/xray/core.js $(1)/www/luci-static/resources/view/xray/core.js
	$(INSTALL_DATA) ./root/www/luci-static/resources/view/xray/profiles.js $(1)/www/luci-static/resources/view/xray/profiles.js
	$(INSTALL_DATA) ./root/www/luci-static/resources/view/xray/preview.js $(1)/www/luci-static/resources/view/xray/preview.js
	$(INSTALL_DATA) ./root/www/luci-static/resources/view/xray/protocol.js $(1)/www/luci-static/resources/view/xray/protocol.js
	$(INSTALL_DATA) ./root/www/luci-static/resources/view/xray/shared.js $(1)/www/luci-static/resources/view/xray/shared.js
	$(INSTALL_DATA) ./root/www/luci-static/resources/view/xray/transport.js $(1)/www/luci-static/resources/view/xray/transport.js
	$(INSTALL_DIR) $(1)/usr/libexec/rpcd
	$(INSTALL_BIN) ./root/usr/libexec/rpcd/xray $(1)/usr/libexec/rpcd/xray
	$(INSTALL_BIN) ./root/usr/libexec/rpcd/xray_profiles $(1)/usr/libexec/rpcd/xray_profiles
	$(INSTALL_DIR) $(1)/usr/share/luci/menu.d
	$(INSTALL_DATA) ./root/usr/share/luci/menu.d/luci-app-xray.json $(1)/usr/share/luci/menu.d/luci-app-xray.json
	$(INSTALL_DIR) $(1)/usr/share/nftables.d/table-pre
	$(INSTALL_DATA) ./root/usr/share/nftables.d/table-pre/xray_core.nft $(1)/usr/share/nftables.d/table-pre/xray_core.nft
	$(INSTALL_DIR) $(1)/usr/share/rpcd/acl.d
	$(INSTALL_DATA) ./root/usr/share/rpcd/acl.d/luci-app-xray.json $(1)/usr/share/rpcd/acl.d/luci-app-xray.json
	$(INSTALL_DIR) $(1)/usr/share/xray
	$(LN) /opt/xray/current/xray $(1)/usr/share/xray/xray
ifdef CONFIG_PACKAGE_XRAY_IGNORE_TP_SPEC_DEF_GW
	$(INSTALL_DATA) ./root/usr/share/xray/ignore_tp_spec_def_gw $(1)/usr/share/xray/ignore_tp_spec_def_gw
endif
ifdef CONFIG_PACKAGE_XRAY_RESTART_DNSMASQ_ON_IFACE_CHANGE
	$(INSTALL_DATA) ./root/usr/share/xray/restart_dnsmasq_on_iface_change $(1)/usr/share/xray/restart_dnsmasq_on_iface_change
endif
ifdef CONFIG_PACKAGE_XRAY_RLIMIT_NOFILE_LARGE
	$(INSTALL_DATA) ./root/usr/share/xray/rlimit_nofile_large $(1)/usr/share/xray/rlimit_nofile
endif
ifdef CONFIG_PACKAGE_XRAY_RLIMIT_DATA_SMALL
	$(INSTALL_DATA) ./root/usr/share/xray/rlimit_data_small $(1)/usr/share/xray/rlimit_data
endif
ifdef CONFIG_PACKAGE_XRAY_RLIMIT_DATA_LARGE
	$(INSTALL_DATA) ./root/usr/share/xray/rlimit_data_large $(1)/usr/share/xray/rlimit_data
endif
	$(INSTALL_BIN) ./root/usr/share/xray/default_gateway.uc $(1)/usr/share/xray/default_gateway.uc
	$(INSTALL_BIN) ./root/usr/share/xray/dnsmasq_include.ut $(1)/usr/share/xray/dnsmasq_include.ut
	$(INSTALL_BIN) ./root/usr/share/xray/firewall_include.ut $(1)/usr/share/xray/firewall_include.ut
	$(INSTALL_DATA) ./root/usr/share/xray/gen_config.mjs $(1)/usr/share/xray/gen_config.mjs
	$(INSTALL_BIN) ./root/usr/share/xray/gen_config.uc $(1)/usr/share/xray/gen_config.uc
	$(INSTALL_DIR) $(1)/usr/share/xray/common
	$(INSTALL_DATA) ./root/usr/share/xray/common/config.mjs $(1)/usr/share/xray/common/config.mjs
	$(INSTALL_DATA) ./root/usr/share/xray/common/stream.mjs $(1)/usr/share/xray/common/stream.mjs
	$(INSTALL_DATA) ./root/usr/share/xray/common/tls.mjs $(1)/usr/share/xray/common/tls.mjs
	$(INSTALL_DIR) $(1)/usr/share/xray/feature
	$(INSTALL_DATA) ./root/usr/share/xray/feature/bridge.mjs $(1)/usr/share/xray/feature/bridge.mjs
	$(INSTALL_DATA) ./root/usr/share/xray/feature/dns.mjs $(1)/usr/share/xray/feature/dns.mjs
	$(INSTALL_DATA) ./root/usr/share/xray/feature/fake_dns.mjs $(1)/usr/share/xray/feature/fake_dns.mjs
	$(INSTALL_DATA) ./root/usr/share/xray/feature/inbound.mjs $(1)/usr/share/xray/feature/inbound.mjs
	$(INSTALL_DATA) ./root/usr/share/xray/feature/manual_tproxy.mjs $(1)/usr/share/xray/feature/manual_tproxy.mjs
	$(INSTALL_DATA) ./root/usr/share/xray/feature/outbound.mjs $(1)/usr/share/xray/feature/outbound.mjs
	$(INSTALL_DATA) ./root/usr/share/xray/feature/system.mjs $(1)/usr/share/xray/feature/system.mjs
	$(INSTALL_DIR) $(1)/usr/share/xray/protocol
	$(INSTALL_DATA) ./root/usr/share/xray/protocol/http.mjs $(1)/usr/share/xray/protocol/http.mjs
	$(INSTALL_DATA) ./root/usr/share/xray/protocol/hysteria.mjs $(1)/usr/share/xray/protocol/hysteria.mjs
	$(INSTALL_DATA) ./root/usr/share/xray/protocol/shadowsocks.mjs $(1)/usr/share/xray/protocol/shadowsocks.mjs
	$(INSTALL_DATA) ./root/usr/share/xray/protocol/socks.mjs $(1)/usr/share/xray/protocol/socks.mjs
	$(INSTALL_DATA) ./root/usr/share/xray/protocol/trojan.mjs $(1)/usr/share/xray/protocol/trojan.mjs
	$(INSTALL_DATA) ./root/usr/share/xray/protocol/vless.mjs $(1)/usr/share/xray/protocol/vless.mjs
	$(INSTALL_DATA) ./root/usr/share/xray/protocol/vmess.mjs $(1)/usr/share/xray/protocol/vmess.mjs
endef

# call BuildPackage - OpenWrt buildroot signature
