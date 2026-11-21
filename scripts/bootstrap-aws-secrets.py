#!/usr/bin/env python3
"""Create missing Zabbix secrets in AWS without printing their values."""
import base64
import datetime
import json
import os
import secrets
from pathlib import Path

import boto3
from botocore.exceptions import ClientError
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import padding, rsa
from cryptography.x509.oid import ExtendedKeyUsageOID, NameOID

client = boto3.client("secretsmanager", region_name=os.getenv("AWS_REGION", "us-east-1"))
prefix = os.getenv("ZABBIX_SECRET_PREFIX", "zabbix-ha").rstrip("/")


def read(name):
    try:
        return client.get_secret_value(SecretId=f"{prefix}/{name}")["SecretString"]
    except ClientError as exc:
        if exc.response["Error"]["Code"] != "ResourceNotFoundException":
            raise
        return None


def ensure(name, value):
    existing = read(name)
    if existing is not None:
        return existing
    try:
        client.create_secret(Name=f"{prefix}/{name}", SecretString=value)
        return value
    except ClientError as exc:
        if exc.response["Error"]["Code"] != "ResourceExistsException":
            raise
        return read(name)


def private_key():
    return rsa.generate_private_key(public_exponent=65537, key_size=3072)


def pem_key(key):
    return key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()).decode()


def certificate(subject, key, issuer, issuer_key, is_ca, names):
    now = datetime.datetime.now(datetime.timezone.utc)
    builder = (x509.CertificateBuilder().subject_name(subject).issuer_name(issuer)
               .public_key(key.public_key()).serial_number(x509.random_serial_number())
               .not_valid_before(now - datetime.timedelta(minutes=5))
               .not_valid_after(now + datetime.timedelta(days=365 if not is_ca else 3650))
               .add_extension(x509.BasicConstraints(ca=is_ca, path_length=None), critical=True)
               .add_extension(x509.KeyUsage(digital_signature=True, content_commitment=False,
                                            key_encipherment=not is_ca, data_encipherment=False,
                                            key_agreement=False, key_cert_sign=is_ca, crl_sign=is_ca,
                                            encipher_only=None, decipher_only=None), critical=True))
    if not is_ca:
        builder = builder.add_extension(x509.ExtendedKeyUsage([ExtendedKeyUsageOID.SERVER_AUTH, ExtendedKeyUsageOID.CLIENT_AUTH]), critical=False)
    if names:
        builder = builder.add_extension(x509.SubjectAlternativeName([x509.DNSName(n) for n in names]), critical=False)
    return builder.sign(issuer_key, hashes.SHA256()).public_bytes(serialization.Encoding.PEM).decode()


def validate_pair(cert_pem, key_pem, label, ca=None):
    try:
        cert = x509.load_pem_x509_certificate(cert_pem.encode())
        key = serialization.load_pem_private_key(key_pem.encode(), password=None)
        cert_public = cert.public_key().public_bytes(serialization.Encoding.DER, serialization.PublicFormat.SubjectPublicKeyInfo)
        key_public = key.public_key().public_bytes(serialization.Encoding.DER, serialization.PublicFormat.SubjectPublicKeyInfo)
        if cert_public != key_public:
            raise ValueError("certificate and private key do not match")
        now = datetime.datetime.now(datetime.timezone.utc)
        if not cert.not_valid_before_utc <= now < cert.not_valid_after_utc:
            raise ValueError("certificate is not currently valid")
        if ca is not None:
            if cert.issuer != ca.subject:
                raise ValueError("certificate issuer does not match the internal CA")
            ca.public_key().verify(cert.signature, cert.tbs_certificate_bytes, padding.PKCS1v15(), cert.signature_hash_algorithm)
    except Exception as exc:
        raise SystemExit(f"Invalid {label} certificate or key: {exc}") from exc
    return cert


# Check the hostname and any existing TLS pair before changing secrets.
frontend_host = os.getenv("ZABBIX_FRONTEND_HOST", "").strip()
if not frontend_host:
    raise SystemExit("ZABBIX_FRONTEND_HOST is required to provision the frontend certificate")
try:
    x509.DNSName(frontend_host)
except ValueError as exc:
    raise SystemExit("Invalid ZABBIX_FRONTEND_HOST") from exc
external_tls = {}
for name in ("traefik_tls_cert", "traefik_tls_key"):
    external_tls[name] = read(name)
if (external_tls["traefik_tls_cert"] is None) != (external_tls["traefik_tls_key"] is None):
    raise SystemExit("Incomplete Traefik certificate pair; refusing to replace it")
if external_tls["traefik_tls_cert"] is not None:
    cert = validate_pair(external_tls["traefik_tls_cert"], external_tls["traefik_tls_key"], "Traefik")
    try:
        names = cert.extensions.get_extension_for_class(x509.SubjectAlternativeName).value.get_values_for_type(x509.DNSName)
    except x509.ExtensionNotFound as exc:
        raise SystemExit("Traefik certificate must include the frontend hostname in its SAN") from exc
    if frontend_host not in names:
        raise SystemExit("Existing Traefik certificate does not cover ZABBIX_FRONTEND_HOST; rotate it deliberately")

values = {}
for name in ("patroni_superuser_password", "patroni_replication_password", "zabbix_db_password", "clickhouse_zabbix_password", "metrics_pg_password", "metrics_pgbouncer_password"):
    values[name] = ensure(name, secrets.token_urlsafe(36))
values["zabbix_db_user"] = ensure("zabbix_db_user", "zabbix")

ca_pem, ca_key_pem = read("zabbix_ca"), read("zabbix_ca_key")
if (ca_pem is None) != (ca_key_pem is None):
    raise SystemExit("Incomplete Zabbix CA in Secrets Manager; refusing to replace it")
if ca_pem is None:
    ca_key = private_key()
    ca_subject = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "Zabbix HA internal CA")])
    ca_key_pem = ensure("zabbix_ca_key", pem_key(ca_key))
    ca_pem = ensure("zabbix_ca", certificate(ca_subject, ca_key, ca_subject, ca_key, True, []))
ca = validate_pair(ca_pem, ca_key_pem, "Zabbix CA")
ca_key = serialization.load_pem_private_key(ca_key_pem.encode(), password=None)
if ca.public_key().public_numbers() != ca_key.public_key().public_numbers():
    raise SystemExit("Zabbix CA certificate and key do not match")
values.update(zabbix_ca=ca_pem, zabbix_ca_key=ca_key_pem)

for role, names in (("server", ["zabbix_app_server1", "zabbix_app_server2", "zabbix_app_server3"]), ("proxy", ["zabbix_app_proxy001"])):
    cert_name, key_name = f"zabbix_{role}_cert", f"zabbix_{role}_key"
    cert, key_pem = read(cert_name), read(key_name)
    if (cert is None) != (key_pem is None):
        raise SystemExit(f"Incomplete {role} certificate pair; refusing to replace it")
    if cert is None:
        key = private_key()
        subject = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, f"zabbix-{role}")])
        key_pem = ensure(key_name, pem_key(key))
        cert = ensure(cert_name, certificate(subject, key, ca.subject, ca_key, False, names))
    validate_pair(cert, key_pem, f"Zabbix {role}", ca)
    values[cert_name], values[key_name] = cert, key_pem

if external_tls["traefik_tls_cert"] is None:
    key = private_key()
    subject = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, frontend_host)])
    external_tls["traefik_tls_key"] = ensure("traefik_tls_key", pem_key(key))
    external_tls["traefik_tls_cert"] = ensure("traefik_tls_cert", certificate(subject, key, ca.subject, ca_key, False, [frontend_host]))
    validate_pair(external_tls["traefik_tls_cert"], external_tls["traefik_tls_key"], "Traefik", ca)
values.update(external_tls)

path = Path(os.getenv("ZABBIX_SECRET_EXPORT", ".secrets-temp.txt"))
fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
os.fchmod(fd, 0o600)
with os.fdopen(fd, "a", encoding="utf-8") as output:
    for name, value in values.items():
        output.write(f"{name}={base64.b64encode(value.encode()).decode()}\n")
print("AWS secret preflight completed; secret values were not printed")
