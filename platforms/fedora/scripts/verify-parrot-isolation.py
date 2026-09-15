#!/usr/bin/env python3
"""Evaluate a Parrot VM's effective libvirt XML against the lab policy."""

from __future__ import annotations

import argparse
import os
import sys
import xml.etree.ElementTree as ET


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--domain", required=True)
    parser.add_argument("--network", required=True)
    parser.add_argument("--pool", required=True)
    parser.add_argument("--domain-xml", required=True)
    parser.add_argument("--network-xml", required=True)
    parser.add_argument("--pool-xml", required=True)
    return parser.parse_args()


def load_xml(path: str, description: str) -> ET.Element:
    try:
        return ET.parse(path).getroot()
    except (OSError, ET.ParseError) as error:
        raise SystemExit(f"Could not parse {description} XML {path}: {error}") from error


def main() -> int:
    args = parse_args()
    domain = load_xml(args.domain_xml, "domain")
    network = load_xml(args.network_xml, "network")
    pool = load_xml(args.pool_xml, "storage pool")

    verified: list[str] = [f"domain identity: {args.domain}"]
    not_observed: list[str] = []
    violations: list[str] = []
    manual: list[str] = [
        "clipboard policy in the active SPICE client",
        "secrets stored inside guest disks or entered interactively",
        "host firewall exposure and physical-network trust outside libvirt XML",
    ]

    interfaces = domain.findall("./devices/interface")
    if not interfaces:
        violations.append("domain has no inspectable network interface")
    for interface in interfaces:
        kind = interface.get("type", "unknown")
        source = interface.find("source")
        selected = source.get("network") if source is not None else None
        if kind == "network" and selected == args.network:
            verified.append(f"interface uses libvirt network: {args.network}")
        else:
            if source is None:
                source_description = "missing"
            else:
                source_description = selected or ET.tostring(source, encoding="unicode")
            violations.append(
                f"non-policy interface: type={kind}, source={source_description}"
            )

    forward = network.find("forward")
    forward_mode = forward.get("mode") if forward is not None else "isolated"
    if forward_mode == "nat":
        verified.append(f"network forwarding mode: NAT ({args.network})")
    else:
        violations.append(f"network forwarding mode is {forward_mode}, expected nat")

    filesystems = domain.findall("./devices/filesystem")
    if filesystems:
        for filesystem in filesystems:
            source = filesystem.find("source")
            target = filesystem.find("target")
            violations.append(
                "filesystem passthrough present: "
                f"source={source.attrib if source is not None else {}}, "
                f"target={target.attrib if target is not None else {}}"
            )
    else:
        not_observed.append("virtiofs/9p/filesystem passthrough devices")

    host_devices = domain.findall("./devices/hostdev")
    if host_devices:
        for device in host_devices:
            violations.append(
                "host USB/PCI/device passthrough present: "
                + ET.tostring(device, encoding="unicode").strip()
            )
    else:
        not_observed.append("USB/PCI hostdev passthrough")

    allowed_channels = {
        "org.qemu.guest_agent.0",
        "com.redhat.spice.0",
    }
    seen_channels: set[str] = set()
    for channel in domain.findall("./devices/channel"):
        target = channel.find("target")
        source = channel.find("source")
        name = target.get("name", "") if target is not None else ""
        path = source.get("path", "") if source is not None else ""
        seen_channels.add(name)
        forwarding_text = f"{name} {path}".lower()
        if name not in allowed_channels and any(
            marker in forwarding_text
            for marker in ("ssh", "gpg", "1password", "keyring", "agent")
        ):
            violations.append(f"possible forwarded host agent channel: {name or path}")
        elif name not in allowed_channels:
            manual.append(f"review additional channel: {name or path or 'unnamed'}")

    for required_channel in sorted(allowed_channels):
        if required_channel in seen_channels:
            verified.append(f"guest integration channel: {required_channel}")
        else:
            violations.append(f"required guest integration channel missing: {required_channel}")
    forwarding_markers = ("ssh", "gpg", "1password", "keyring")
    secret_channel_observed = False
    for channel in domain.findall("./devices/channel"):
        target = channel.find("target")
        source = channel.find("source")
        name = target.get("name", "") if target is not None else ""
        path = source.get("path", "") if source is not None else ""
        if any(marker in f"{name} {path}".lower() for marker in forwarding_markers):
            secret_channel_observed = True
            break
    if not secret_channel_observed:
        not_observed.append("SSH/GPG/password-manager agent forwarding channels")

    pool_target_node = pool.find("./target/path")
    pool_target = pool_target_node.text if pool_target_node is not None else None
    if not pool_target:
        violations.append(f"storage pool {args.pool} has no target path")
    else:
        verified.append(f"storage pool target: {args.pool} -> {pool_target}")
        file_disks = []
        for disk in domain.findall("./devices/disk"):
            if disk.get("device") != "disk":
                continue
            source = disk.find("source")
            disk_file = source.get("file") if source is not None else None
            if disk_file:
                file_disks.append(disk_file)
                try:
                    inside_pool = os.path.commonpath(
                        [os.path.realpath(disk_file), os.path.realpath(pool_target)]
                    ) == os.path.realpath(pool_target)
                except ValueError:
                    inside_pool = False
                if not inside_pool:
                    violations.append(
                        f"disk path is outside selected pool {args.pool}: {disk_file}"
                    )
        if file_disks and not any("disk path is outside" in item for item in violations):
            verified.append(f"file-backed disks are within pool target: {pool_target}")
        elif not file_disks:
            manual.append("review non-file-backed disk storage and pool ownership")

    print("VERIFIED")
    for item in verified:
        print(f"  - {item}")
    print("NOT OBSERVED")
    for item in not_observed:
        print(f"  - {item}")
    print("MANUAL ASSURANCE REQUIRED")
    for item in dict.fromkeys(manual):
        print(f"  - {item}")
    if violations:
        print("POLICY VIOLATIONS", file=sys.stderr)
        for item in violations:
            print(f"  - {item}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
