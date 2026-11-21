#!/usr/bin/env python3
"""Generate the project architecture diagrams as editable SVG and PNG files."""
from html import escape
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parent


class Diagram:
    def __init__(self, title, subtitle, height=900):
        self.width, self.height = 1500, height
        self.parts = [f'''<svg xmlns="http://www.w3.org/2000/svg" width="{self.width}" height="{height}" viewBox="0 0 {self.width} {height}">
<defs><marker id="arrow" markerWidth="10" markerHeight="10" refX="8" refY="5" orient="auto"><path d="M 0 0 L 10 5 L 0 10 z" fill="#64748b"/></marker></defs>
<rect width="100%" height="100%" fill="#f4f7fb"/>
<text x="55" y="60" font-family="DejaVu Sans,sans-serif" font-size="30" font-weight="700" fill="#12253f">{escape(title)}</text>
<text x="55" y="91" font-family="DejaVu Sans,sans-serif" font-size="16" fill="#52657d">{escape(subtitle)}</text>''']

    def box(self, x, y, w, h, title, lines=(), fill="#ffffff", stroke="#cbd5e1", color="#152942"):
        self.parts.append(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="12" fill="{fill}" stroke="{stroke}" stroke-width="1.5"/>')
        self.text(x + 17, y + 27, title, 17, color, "700")
        for index, line in enumerate(lines):
            self.text(x + 17, y + 52 + 22 * index, line, 14, "#415571")

    def text(self, x, y, content, size=15, color="#52657d", weight="400"):
        self.parts.append(f'<text x="{x}" y="{y}" font-family="DejaVu Sans,sans-serif" font-size="{size}" font-weight="{weight}" fill="{color}">{escape(content)}</text>')

    def line(self, points, label=None, lx=0, ly=0, dashed=False):
        coordinates = " ".join(f"{x},{y}" for x, y in points)
        dash = ' stroke-dasharray="7 5"' if dashed else ''
        self.parts.append(f'<polyline points="{coordinates}" fill="none" stroke="#64748b" stroke-width="2"{dash} marker-end="url(#arrow)"/>')
        if label:
            self.text(lx, ly, label, 13)

    def region(self, x, y, w, h, title, color="#dce9f8"):
        self.parts.append(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="16" fill="{color}" fill-opacity="0.45" stroke="#b7cbe1" stroke-width="1.2"/>')
        self.text(x + 16, y + 26, title, 15, "#385675", "700")

    def save(self, name):
        path = ROOT / f"{name}.svg"
        path.write_text("\n".join(self.parts) + "\n</svg>\n", encoding="utf-8")
        subprocess.run(["convert", "-background", "white", str(path), str(ROOT / f"{name}.png")], check=True)


def aws():
    d = Diagram("AWS infrastructure", "us-east-1 • six EC2 instances • one shared NAT • static NLB addresses", 900)
    d.box(55, 130, 250, 82, "Client", ["hosts: zabbix.wildeshanada.com", "HTTPS 443 • Zabbix TCP 10051"], "#eef5ff")
    d.box(400, 130, 390, 82, "Public Network Load Balancer", ["3 static Elastic IPs • ports 80 / 443 / 10051", "TCP forwarding to Swarm managers"], "#ecfdf5")
    d.line([(305, 170), (400, 170)])
    d.region(55, 265, 1390, 525, "VPC 10.60.0.0/16 • three availability zones")
    for i in range(3):
        x = 80 + i * 450
        d.region(x, 310, 420, 420, f"Availability zone {i + 1}", "#eef4ff")
        d.box(x + 20, 355, 380, 94, f"Manager {i + 1} — public subnet", ["Public IPv4 • Docker Swarm manager", "Traefik ingress participates in Swarm"], "#ffffff")
        lines = ["etcd • Patroni / TimescaleDB • Keeper", "ClickHouse • Zabbix HA server", "Dedicated EBS per persistent service"]
        if i == 2:
            lines.append("Proxy 001 + dedicated proxy EBS")
        d.box(x + 20, 540, 380, 132, f"Worker {i + 1} — private subnet", lines, "#ffffff")
        d.line([(x + 210, 449), (x + 210, 540)], "encrypted overlay", x + 222, 500)
        d.line([(530 + i * 65, 212), (x + 210, 355)])
    d.box(550, 804, 400, 67, "Shared NAT gateway + 1 Elastic IP", ["All private subnets use one NAT for outbound access"], "#fff8e8", "#eccd87")
    d.text(990, 840, "One NAT is a single outbound failure point.", 14, "#795c21")
    d.save("architecture-aws")


def stack():
    d = Diagram("Swarm services and data flow", "Encrypted overlays • labels pin persistent services to workers • no Prometheus server", 980)
    d.box(55, 135, 300, 75, "Client / NLB", ["HTTPS :443 • TCP :10051"], "#eef5ff")
    d.box(490, 135, 300, 75, "Traefik ×2 on managers", ["web / websecure • SNI + TCP routes"], "#ecfdf5")
    d.line([(355, 172), (490, 172)])
    d.region(45, 250, 1410, 640, "Docker Swarm encrypted backend overlay")
    d.box(75, 300, 350, 110, "Zabbix application", ["Frontend ×2 • web service • Selenium", "HA servers ×3: :10051 / :10052 / :10053", "Only the active HA server listens"], "#ffffff")
    d.box(555, 300, 325, 110, "Proxy 001 on worker 3", ["SQLite volume • TLS to HA servers", "Optional OTLP / APM collector :4317", "Telemetry provider uses ClickHouse"], "#ffffff")
    d.box(1030, 300, 350, 110, "Exporters / native metrics", ["PostgreSQL • PgBouncer • pgSCV", "etcd • Patroni • ClickHouse", "node • process • cAdvisor"], "#ffffff")
    d.line([(550, 210), (300, 300)])
    d.line([(425, 353), (555, 353)], "active server", 445, 340)
    d.box(75, 495, 310, 110, "PgBouncer ×2 + router ×2", ["Session pools • separate metrics", "HAProxy routes connections"], "#ecfdf5")
    d.box(465, 495, 330, 110, "Database HAProxy ×2", ["Routes writes to Patroni primary", "Checks Patroni REST endpoints"], "#ecfdf5")
    d.box(875, 490, 505, 120, "Patroni / PostgreSQL / TimescaleDB ×3", ["One primary, two physical replicas", "One node and one EBS volume per worker", "etcd ×3 maintains cluster consensus"], "#eef5ff")
    d.line([(245, 410), (230, 495)])
    d.line([(385, 550), (465, 550)])
    d.line([(795, 550), (875, 550)])
    d.box(555, 690, 370, 115, "ClickHouse Keeper ×3", ["Raft coordination • dedicated EBS", "One member on each worker"], "#fff8e8", "#eccd87")
    d.box(1010, 690, 370, 115, "ClickHouse ×3 + HTTP router ×2", ["Replicated telemetry tables", "Dedicated EBS on each worker"], "#fff8e8", "#eccd87")
    d.line([(925, 750), (1010, 750)], "coordination", 935, 737)
    d.line([(740, 410), (740, 450), (840, 450), (840, 650), (1200, 650), (1200, 690)], "APM / OTLP storage", 840, 440)
    d.text(65, 940, "TLS certificates and credentials are delivered as Swarm secrets; APM and failover still require end-to-end validation.", 14)
    d.save("architecture-stack")


def deployment():
    d = Diagram("Deployment and operational workflow", "GitHub Actions + OIDC • Terraform provisions infrastructure • Ansible configures Swarm", 790)
    d.box(60, 140, 300, 95, "Repository: main", ["Push / PR triggers validation", "No automatic infrastructure apply"], "#eef5ff")
    d.box(460, 140, 360, 95, "Production approval", ["Required after validation", "whanada reviews the selected operation"], "#ecfdf5")
    d.box(930, 140, 400, 95, "AWS resources", ["VPC • EC2 • EBS • NAT • NLB", "Fixed NLB IPs and private workers"], "#ffffff")
    d.line([(360, 185), (460, 185)])
    d.line([(820, 185), (930, 185)])
    d.box(60, 340, 350, 110, "Publish image — approved", ["Ansible build + database tests", "Publish versioned Patroni image to ECR", "Existing tags are not overwritten"], "#fff8e8", "#eccd87")
    d.box(510, 340, 350, 110, "Deploy — approved", ["Terraform plan and apply", "Join 3 managers + 3 workers", "Encrypted networks, labels and EBS"], "#ffffff")
    d.box(970, 340, 400, 110, "Deploy stack — Ansible", ["Secrets → data → schema → services", "AWS Secrets Manager + Swarm secrets", "Validate APM and failover separately"], "#ffffff")
    d.line([(1130, 235), (1130, 285), (685, 285), (685, 340)])
    d.line([(860, 395), (970, 395)])
    d.line([(410, 395), (510, 395)], "image ready", 425, 382, True)
    d.box(60, 550, 350, 100, "Private ECR", ["Patroni / TimescaleDB image", "12-hour registry token"], "#fff8e8", "#eccd87")
    d.box(510, 550, 350, 100, "Credential refresh — approval", ["Scheduled every 6 h; approval required", "Monitor pending runs and token expiry"], "#ffffff")
    d.box(970, 550, 400, 100, "Client trust", ["Private CA in Secrets Manager", "Import public CA; add NLB IP to hosts"], "#ffffff")
    d.line([(235, 450), (235, 550)])
    d.line([(410, 600), (510, 600)])
    d.line([(1170, 450), (1170, 550)])
    d.text(60, 730, "OIDC roles are configured. A real GitHub workflow run and distributed AWS validation are still required.", 14)
    d.save("architecture-deployment")


if __name__ == "__main__":
    aws()
    stack()
    deployment()
