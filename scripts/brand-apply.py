#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把 site-profile.properties 的品牌与身份注入工程，然后重新生成 Xcode 工程。

    python3 scripts/brand-apply.py [--check]

三条必须知道的事实：

1. **Info.plist 与 entitlements 都是 XcodeGen 从 project.yml 生成的产物**，
   而且被 .gitignore 掉了。所以品牌只能改 `project.yml`，改生成物没有意义
   （下次 `configure.py` 一跑就没了）。

2. **权限说明文案不在这里改**。上游已经把它们做成了本地化的
   `InfoPlist.strings`（en / zh-Hans 都有且中文质量没问题），运行时以本地化为准，
   `project.yml` 里那份英文只是兜底。本脚本刻意不碰它们。

3. **上游 configure.py 有缺口**：它只改 project.yml 的 HAKO_BUNDLE_BASE 和两个
   Identifiers.swift，但另有 12 个 Swift 文件把 `org.example.hako` 硬编码进了
   **Darwin 通知名、DispatchQueue 标签、Logger subsystem 和 Control Center 的 controlKind**。
   通知名与 controlKind 是**系统级命名空间**——不改的话，本应用会与真正的 Clash、
   以及将来同族的 52nm 版互相串扰。本脚本补上这一段。

幂等：旧家族名从 project.yml 现读，不写死，所以重复跑、或换个 bundle.base 再跑都正确。
"""
from pathlib import Path
import argparse
import re
import subprocess
import sys

import yaml

ROOT = Path(__file__).resolve().parents[1]
PROFILE = ROOT / 'site-profile.properties'
PROJECT_YML = ROOT / 'apple/HakoClient/project.yml'

# 每个 target 的展示名取 site-profile 里的哪个键
TARGET_NAME_KEY = {
    'HakoClient': 'app.name',
    'HakoMac': 'app.name',
    'HakoTV': 'app.name',
    'HakoMacWidgets': 'app.name',
    'HakoClientExtension': 'app.name.extension',
    'HakoMacExtension': 'app.name.extension',
    'HakoTVExtension': 'app.name.extension',
    'HakoControlsExtension': 'app.name.controls',
    'HakoShareExtension': 'app.name.share',
}
REQUIRED = ('profile.id', 'bundle.base', 'app.name', 'url.schemes')


class NoAliasDumper(yaml.SafeDumper):
    """两个 target 共用同一份 scheme 列表时，PyYAML 默认会写成 &id001 / *id001 锚点。
    合法但难读，而且上游 configure.py 之后还会再 round-trip 一次把它保留下来。"""

    def ignore_aliases(self, data):
        return True


def read_profile():
    profile = {}
    for line in PROFILE.read_text(encoding='utf-8').splitlines():
        line = line.strip()
        if not line or line.startswith('#') or '=' not in line:
            continue
        key, _, value = line.partition('=')
        profile[key.strip()] = value.strip()
    missing = [k for k in REQUIRED if not profile.get(k)]
    if missing:
        sys.exit('site-profile.properties 缺少：%s' % ', '.join(missing))
    if not re.fullmatch(r'[A-Za-z0-9]+(?:[.-][A-Za-z0-9]+)+', profile['bundle.base']):
        sys.exit('bundle.base 不是合法的 Bundle ID 家族：%s' % profile['bundle.base'])
    return profile


def apply_project_yml(project, profile, base):
    """就地修改已解析的 project.yml，返回改动说明列表。"""
    changed = []
    schemes = [s.strip() for s in profile['url.schemes'].split(',') if s.strip()]

    for target, spec in project.get('targets', {}).items():
        properties = ((spec.get('info') or {}).get('properties') or {})
        if not properties:
            continue

        key = TARGET_NAME_KEY.get(target, 'app.name')
        wanted = profile.get(key) or profile['app.name']
        if properties.get('CFBundleDisplayName') != wanted:
            changed.append('%s: 显示名 %r -> %r' % (target, properties.get('CFBundleDisplayName'), wanted))
            properties['CFBundleDisplayName'] = wanted

        for entry in properties.get('CFBundleURLTypes') or []:
            if 'CFBundleURLSchemes' in entry and entry['CFBundleURLSchemes'] != schemes:
                changed.append('%s: URL scheme %s -> %s' % (target, entry['CFBundleURLSchemes'], schemes))
                entry['CFBundleURLSchemes'] = list(schemes)

        # 上游把容器 ID 硬编码成 iCloud.com.hako.network，没跟着 HAKO_ICLOUD_CONTAINER 走。
        containers = properties.get('NSUbiquitousContainers')
        if isinstance(containers, dict) and containers:
            wanted_id = 'iCloud.' + base
            wanted_name = profile.get('icloud.container.name') or profile['app.name']
            rebuilt = {}
            for _, value in containers.items():
                value = dict(value)
                value['NSUbiquitousContainerName'] = wanted_name
                rebuilt[wanted_id] = value
            if rebuilt != containers:
                changed.append('%s: iCloud 容器 %s -> %s' % (target, list(containers), [wanted_id]))
                properties['NSUbiquitousContainers'] = rebuilt

    return changed


GENERATED_PROFILE = ROOT / 'apple/ShenxianyunKit/Sources/ShenxianyunKit/Generated/ShenxianyunProfile.swift'

PROFILE_TEMPLATE = '''// 由 scripts/brand-apply.py 从根目录 site-profile.properties 生成。
// 不要手改——下次 brand-apply 会覆盖。要改值改 site-profile.properties。
import Foundation

public enum ShenxianyunProfile {{
    /// 站点标识，用于区分 sxnn / 52nm 等品牌。
    public static let id = "{profile_id}"

    /// 展示名。
    public static let appName = "{app_name}"

    /// Bundle ID 家族。
    public static let bundleBase = "{bundle_base}"

    /// App Group。**Extension 靠它读设备凭据**，不能用 UserDefaults.standard。
    public static let appGroup = "group.{bundle_base}"

    /// 内置的引导 API 地址。客户端只内置这一个，
    /// 启动后一律以 /api/endpoints 下发的为准；换线路改后台即可，不必发新版。
    public static let bootstrapAPI = URL(string: "{api_bootstrap}")!

    /// 上报给后端的平台标识（exchange 的 platform 字段）。
    public static let platform: String = {{
        #if os(tvOS)
            return "tvos"
        #elseif os(macOS)
            return "macos"
        #else
            return "ios"
        #endif
    }}()
}}
'''


def render_profile_constants(profile, check):
    """把 site-profile 的值烧进 ShenxianyunKit，业务代码就不必再解析 properties。"""
    rendered = PROFILE_TEMPLATE.format(
        profile_id=profile['profile.id'],
        app_name=profile['app.name'],
        bundle_base=profile['bundle.base'],
        api_bootstrap=profile.get('api.bootstrap', ''),
    )
    if GENERATED_PROFILE.exists() and GENERATED_PROFILE.read_text(encoding='utf-8') == rendered:
        return []
    if not check:
        GENERATED_PROFILE.parent.mkdir(parents=True, exist_ok=True)
        GENERATED_PROFILE.write_text(rendered, encoding='utf-8')
    return ['%s: 重新生成常量' % GENERATED_PROFILE.relative_to(ROOT)]


def rewrite_hardcoded_sources(old, new, check):
    """configure.py 覆盖不到的那批文件。跳过两个 Identifiers.swift——它们归 configure.py 管。"""
    changed = []
    if old == new:
        return changed
    for path in sorted(ROOT.joinpath('apple').rglob('*.swift')):
        if path.name in ('HakoAppIdentifiers.swift', 'HakoClientKitIdentifiers.swift'):
            continue
        text = path.read_text(encoding='utf-8')
        if old not in text:
            continue
        changed.append('%s: %d 处硬编码标识' % (path.relative_to(ROOT), text.count(old)))
        if not check:
            path.write_text(text.replace(old, new), encoding='utf-8')
    return changed


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--check', action='store_true', help='只报告将要发生的改动，不落盘、不生成工程')
    args = parser.parse_args()

    profile = read_profile()
    project = yaml.safe_load(PROJECT_YML.read_text(encoding='utf-8'))
    old = project['settings']['base']['HAKO_BUNDLE_BASE']
    new = profile['bundle.base']

    print('品牌注入：%s（profile.id=%s）' % (profile['app.name'], profile['profile.id']))
    print('  Bundle 家族: %s -> %s' % (old, new))
    print('  URL scheme : %s' % profile['url.schemes'])
    print('  Team       : %s' % (profile.get('development.team') or '(空 → 只能不签名构建)'))
    print()

    changed = apply_project_yml(project, profile, new)
    changed += rewrite_hardcoded_sources(old, new, args.check)
    changed += render_profile_constants(profile, args.check)

    if not changed:
        print('无改动，已是目标状态。')
        if args.check:
            return
    for item in changed:
        print(('  待改 ' if args.check else '  改 ') + item)

    if args.check:
        print('\n[--check] 共 %d 处，未落盘。' % len(changed))
        return

    PROJECT_YML.write_text(
        yaml.dump(project, Dumper=NoAliasDumper, sort_keys=False, allow_unicode=True),
        encoding='utf-8')

    # 交给上游脚本处理 HAKO_BUNDLE_BASE、两个 Identifiers.swift，并生成 Xcode 工程。
    cmd = [sys.executable, str(ROOT / 'scripts/configure.py'), '--bundle-base', new]
    if profile.get('development.team'):
        cmd += ['--team', profile['development.team']]
    print('\n$ ' + ' '.join(cmd))
    subprocess.run(cmd, cwd=ROOT, check=True)
    print('\n完成。Bundle ID / App Group / URL scheme 都是编译期身份，必须重新编译才生效。')


if __name__ == '__main__':
    main()
