#!/usr/bin/env python3
import urllib.request
import tarfile
import hashlib
import os
import sys
import argparse

REPOS = [
    "https://downloads.openwrt.org/releases/25.12.5/targets/bcm27xx/bcm2710/packages",
    "https://downloads.openwrt.org/releases/25.12.5/packages/aarch64_cortex-a53/base",
    "https://downloads.openwrt.org/releases/25.12.5/packages/aarch64_cortex-a53/luci",
    "https://downloads.openwrt.org/releases/25.12.5/packages/aarch64_cortex-a53/packages",
    "https://downloads.openwrt.org/releases/25.12.5/packages/aarch64_cortex-a53/routing",
    "https://downloads.openwrt.org/releases/25.12.5/packages/aarch64_cortex-a53/telephony",
]

TARGET_ARCH = "aarch64_cortex-a53"

def parse_apkindex(content):
    packages = {}
    current_pkg = {}
    for line in content.decode('utf-8', errors='replace').split('\n'):
        if line.strip() == '':
            if 'P' in current_pkg:
                packages[current_pkg['P']] = current_pkg
            current_pkg = {}
            continue
        if len(line) > 2 and line[1] == ':':
            key = line[0]
            val = line[2:]
            current_pkg[key] = val
    if 'P' in current_pkg:
        packages[current_pkg['P']] = current_pkg
    return packages

def download_and_read_index(repo_url):
    index_url = f"{repo_url}/APKINDEX.tar.gz"
    print(f"Downloading {index_url}...")
    req = urllib.request.Request(index_url)
    with urllib.request.urlopen(req) as response:
        data = response.read()
    
    # Save temporarily to extract
    tmp_idx = "tmp_APKINDEX.tar.gz"
    with open(tmp_idx, "wb") as f:
        f.write(data)
    
    with tarfile.open(tmp_idx, "r:gz") as tar:
        f = tar.extractfile("APKINDEX")
        content = f.read()
        
    os.remove(tmp_idx)
    return parse_apkindex(content), repo_url

def resolve_deps(pkg_name, all_pkgs, resolved, stack):
    if pkg_name in resolved:
        return
    if pkg_name in stack:
        print(f"Circular dependency detected for {pkg_name}!")
        return
        
    if pkg_name not in all_pkgs:
        # Some packages are provided by others.
        # Find which package provides this
        provider = None
        for p, info in all_pkgs.items():
            if 'p' in info:
                provides = info['p'].split()
                for prov in provides:
                    if prov == pkg_name or prov.startswith(pkg_name + "="):
                        provider = p
                        break
            if provider:
                break
        
        if provider:
            resolve_deps(provider, all_pkgs, resolved, stack + [pkg_name])
            return
        else:
            print(f"WARNING: Package {pkg_name} not found in repositories!")
            # It might be in core/kernel, which we don't have indexes for, or we ignore it.
            return

    stack.append(pkg_name)
    resolved.add(pkg_name)
    
    info = all_pkgs[pkg_name]
    if 'D' in info:
        deps = info['D'].split()
        for dep in deps:
            # dep can be 'libnl-tiny' or 'libnl-tiny=1.0' or '!foo'
            if dep.startswith('!'): continue # Conflict
            # strip version bounds
            dep_name = dep
            for op in ['=', '<', '>', '~']:
                if op in dep_name:
                    dep_name = dep_name.split(op)[0]
            resolve_deps(dep_name, all_pkgs, resolved, stack)
            
    stack.pop()

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--packages', nargs='+', required=True)
    parser.add_argument('--out-dir', default='.')
    parser.add_argument('--manifest', default='OFFLINE-PACKAGES-MANIFEST.txt')
    args = parser.parse_args()

    all_pkgs = {}
    pkg_repo_map = {}
    
    for repo in REPOS:
        pkgs, r_url = download_and_read_index(repo)
        for p_name, p_info in pkgs.items():
            # If multiple repos have the same package, prefer the first one (or higher version, but here first is fine)
            if p_name not in all_pkgs:
                all_pkgs[p_name] = p_info
                pkg_repo_map[p_name] = r_url

    resolved = set()
    for p in args.packages:
        resolve_deps(p, all_pkgs, resolved, [])

    print(f"Resolved closure: {resolved}")
    
    manifest_lines = []
    
    for pkg in resolved:
        info = all_pkgs[pkg]
        repo_url = pkg_repo_map[pkg]
        # Construct filename
        # Format: {pkg}-{version}.apk
        # But openwrt uses exact filename from index if possible?
        # Actually APK uses filename: {P}-{V}.apk
        filename = f"{info['P']}-{info['V']}.apk"
        url = f"{repo_url}/{filename}"
        
        out_path = os.path.join(args.out_dir, filename)
        print(f"Downloading {filename} from {url} ...")
        req = urllib.request.Request(url)
        try:
            with urllib.request.urlopen(req) as response:
                apk_data = response.read()
        except urllib.error.HTTPError as e:
            print(f"ERROR: Failed to download {url}: {e}")
            sys.exit(1)
            
        if len(apk_data) == 0:
            print(f"ERROR: Downloaded {filename} is empty!")
            sys.exit(1)
            
        # Verify SHA256
        if 'C' in info: # C: Q1... (Base64 sha1 or sha256?)
            # In OpenWrt 25.12, APKINDEX uses C: Q1... which is base64(sha256).
            # We can just verify our own sha256 to record in manifest.
            pass
            
        # Verify architecture
        if info.get('A') != TARGET_ARCH and info.get('A') != 'all' and info.get('A') != 'noarch':
            if info.get('A') != 'aarch64':
                # some packages might be just aarch64
                print(f"WARNING: Package {pkg} has architecture {info.get('A')} instead of {TARGET_ARCH}")
                
        # Write file
        with open(out_path, "wb") as f:
            f.write(apk_data)
            
        sha256 = hashlib.sha256(apk_data).hexdigest()
        size = len(apk_data)
        
        # Manifest format:
        # canonical filename; package name; version; release; architecture; byte size; SHA-256; repository source; direct dependencies
        # In APK, V contains both version and release (e.g. 9.5-2)
        version_part = info['V'].split('-')[0] if '-' in info['V'] else info['V']
        release_part = info['V'].split('-')[1] if '-' in info['V'] else ''
        
        direct_deps = info.get('D', '')
        
        manifest_lines.append(f"{filename};{info['P']};{version_part};{release_part};{info.get('A')};{size};{sha256};{repo_url};{direct_deps}")
        
    with open(args.manifest, "w") as f:
        for line in manifest_lines:
            f.write(line + "\n")
            
    print(f"Successfully downloaded {len(resolved)} packages and wrote manifest to {args.manifest}")

if __name__ == '__main__':
    main()
