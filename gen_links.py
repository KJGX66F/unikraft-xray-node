#!/usr/bin/env python3
"""生成 Unikraft 节点的全套交付物：直连 + CF 双链，WS 主用 + XHTTP 备用。

只依赖 Python 标准库（二维码可选，需 qrcode+Pillow，缺了也不报错）。
用法：
    python3 gen_links.py --domain xxx.sin.unikraft.app --uuid <UUID> \\
        --ws-path /abc --xhttp-path /def --out-dir ./node-out
    python3 gen_links.py --domain xxx.sin.unikraft.app --cf-domain v.example.com \\
        --uuid <UUID> --ws-path /abc --xhttp-path /def --out-dir ./node-out

输出：
    links.txt       2 条直连（WS 443 + XHTTP 8443），有 CF 域名时再加 2 条 CF 链
    clash.yaml      全部 4 条（mihomo >= 1.19.22 才支持 XHTTP；低版本只用 WS 那两条）
    sing-box.json   只含 WS 的 2 条 —— sing-box 任何版本都不支持 XHTTP，别把 XHTTP 往里加
    node.json       清单（不含 UUID 以外的秘密）
    node-ws-direct.png  主用 WS 直连的二维码（有 qrcode 库时才生成）

注意：
  - XHTTP 客户端统一用 mode=packet-up：对 CDN / 反向代理兼容性最高。
  - CF 回源用客户端同端口：CF 443 -> 源站 443（WS），CF 8443 -> 源站 8443（XHTTP）。
  - 直连和 CF 链共用同一套 UUID / 路径，只换 host 和 sni。
"""
import argparse
import json
import os
import sys
import urllib.parse
import uuid as uuid_mod


def build_ws_link(host, uuid, port, path, name):
    q = urllib.parse.urlencode({
        "encryption": "none", "security": "tls", "sni": host, "fp": "chrome",
        "type": "ws", "host": host, "path": path,
    })
    return f"vless://{uuid}@{host}:{port}?{q}#{urllib.parse.quote(name)}"


def build_xhttp_link(host, uuid, port, path, name):
    q = urllib.parse.urlencode({
        "encryption": "none", "security": "tls", "sni": host, "fp": "chrome",
        "type": "xhttp", "host": host, "path": path, "mode": "packet-up",
    })
    return f"vless://{uuid}@{host}:{port}?{q}#{urllib.parse.quote(name)}"


def clash_yaml(entries):
    """entries: list of dicts {name, host, port, uuid, transport, path, mode?}。手写最小 YAML，不依赖 PyYAML。"""
    lines = ["proxies:"]
    for e in entries:
        lines += [
            f"  - name: \"{e['name']}\"",
            "    type: vless",
            f"    server: {e['host']}",
            f"    port: {e['port']}",
            f"    uuid: {e['uuid']}",
            "    tls: true",
            f"    servername: {e['host']}",
            "    fingerprint: chrome",
            f"    network: {e['transport']}",
        ]
        if e["transport"] == "ws":
            lines += [
                "    ws-opts:",
                f"      path: {e['path']}",
                "      headers:",
                f"        Host: {e['host']}",
            ]
        else:
            lines += [
                "    xhttp-opts:",
                f"      path: {e['path']}",
                "      mode: packet-up",
                "      headers:",
                f"        Host: {e['host']}",
            ]
        lines.append("    udp: true")
    names = ", ".join(f"\"{e['name']}\"" for e in entries)
    lines += [
        "proxy-groups:",
        "  - name: PROXY",
        "    type: url-test",
        f"    proxies: [{names}]",
        "    url: http://www.gstatic.com/generate_204",
        "    interval: 300",
        "  - name: 手动选择",
        "    type: select",
        f"    proxies: [{names}]",
        "rules:",
        "  - MATCH,PROXY",
        "",
    ]
    return "\n".join(lines)


def singbox_json(ws_entries):
    outbounds = []
    for e in ws_entries:
        outbounds.append({
            "type": "vless", "tag": e["name"], "server": e["host"],
            "server_port": e["port"], "uuid": e["uuid"],
            "tls": {"enabled": True, "server_name": e["host"],
                    "utls": {"enabled": True, "fingerprint": "chrome"}},
            "transport": {"type": "ws", "path": e["path"],
                          "headers": {"Host": e["host"]}},
        })
    outbounds.append({"type": "direct", "tag": "direct"})
    return {"outbounds": outbounds}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--domain", required=True, help="Unikraft 平台给的域名，如 xxx.sin.unikraft.app")
    ap.add_argument("--cf-domain", default=None, help="可选：已接 Cloudflare 的自有域名，如 v.example.com")
    ap.add_argument("--uuid", required=True)
    ap.add_argument("--ws-path", default="/ws")
    ap.add_argument("--xhttp-path", default="/xhttp")
    ap.add_argument("--out-dir", required=True)
    args = ap.parse_args()

    try:
        uuid_mod.UUID(args.uuid)
    except ValueError:
        print(f"[FAIL] UUID 非法: {args.uuid}", file=sys.stderr)
        return 2
    for p, label in [(args.ws_path, "WS"), (args.xhttp_path, "XHTTP")]:
        if not p.startswith("/"):
            print(f"[FAIL] {label} 路径必须以 / 开头: {p}", file=sys.stderr)
            return 2

    entries = [
        {"name": "Unikraft-WS-Direct", "host": args.domain, "port": 443,
         "uuid": args.uuid, "transport": "ws", "path": args.ws_path,
         "link": build_ws_link(args.domain, args.uuid, 443, args.ws_path, "Unikraft-WS-Direct")},
        {"name": "Unikraft-XHTTP-Direct", "host": args.domain, "port": 8443,
         "uuid": args.uuid, "transport": "xhttp", "path": args.xhttp_path,
         "link": build_xhttp_link(args.domain, args.uuid, 8443, args.xhttp_path, "Unikraft-XHTTP-Direct")},
    ]
    if args.cf_domain:
        entries += [
            {"name": "Unikraft-WS-CF", "host": args.cf_domain, "port": 443,
             "uuid": args.uuid, "transport": "ws", "path": args.ws_path,
             "link": build_ws_link(args.cf_domain, args.uuid, 443, args.ws_path, "Unikraft-WS-CF")},
            {"name": "Unikraft-XHTTP-CF", "host": args.cf_domain, "port": 8443,
             "uuid": args.uuid, "transport": "xhttp", "path": args.xhttp_path,
             "link": build_xhttp_link(args.cf_domain, args.uuid, 8443, args.xhttp_path, "Unikraft-XHTTP-CF")},
        ]

    out = os.path.abspath(args.out_dir)
    os.makedirs(out, exist_ok=True)
    with open(os.path.join(out, "links.txt"), "w", encoding="utf-8") as f:
        for e in entries:
            f.write(f"# {e['name']}\n{e['link']}\n\n")
    with open(os.path.join(out, "clash.yaml"), "w", encoding="utf-8") as f:
        f.write(clash_yaml(entries))
    ws_entries = [e for e in entries if e["transport"] == "ws"]
    with open(os.path.join(out, "sing-box.json"), "w", encoding="utf-8") as f:
        f.write(json.dumps(singbox_json(ws_entries), indent=2, ensure_ascii=False) + "\n")

    qr_done = False
    try:
        import qrcode
        from PIL import Image  # noqa: F401  (qrcode 依赖 Pillow)
        qr = qrcode.QRCode(error_correction=qrcode.constants.ERROR_CORRECT_M, box_size=10, border=4)
        qr.add_data(entries[0]["link"])
        qr.make(fit=True)
        qr.make_image(fill_color="black", back_color="white").save(os.path.join(out, "node-ws-direct.png"))
        qr_done = True
    except Exception as exc:  # noqa: BLE001 - 二维码是锦上添花，缺库也不应阻断交付
        print(f"[WARN] 二维码未生成（{exc}）；手机端可直接粘贴 links.txt 里的链接导入", file=sys.stderr)

    manifest = {
        "domain": args.domain, "cf_domain": args.cf_domain,
        "ws_path": args.ws_path, "xhttp_path": args.xhttp_path,
        "links": [{"name": e["name"], "link": e["link"]} for e in entries],
        "notes": [
            "主用 WS（443），备用 XHTTP（8443，mode=packet-up）。",
            "sing-box.json 只含 WS：sing-box 不支持 XHTTP，XHTTP 请用 v2rayNG / NekoBox / mihomo>=1.19.22。",
            "Unikraft Hobby 免费档无公开月流量上限数字，别当无限流量用；只做个人自用，别公开分享。",
            "CF 链需要域名已托管到 Cloudflare 且开了小黄云（Proxied），SSL 模式 Full (Strict)。",
        ],
        "qr_generated": qr_done,
    }
    with open(os.path.join(out, "node.json"), "w", encoding="utf-8") as f:
        f.write(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n")

    print(f"已生成到 {out}：")
    for e in entries:
        print(f"  - {e['name']}: {e['host']}:{e['port']} ({e['transport']})")
    print("  - links.txt / clash.yaml / sing-box.json / node.json" + (" / node-ws-direct.png" if qr_done else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main())
