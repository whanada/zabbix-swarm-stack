#!/usr/bin/env python3
"""Exercise AWS certificate bootstrap with an in-memory Secrets Manager."""
import contextlib
import datetime
import io
import os
from pathlib import Path
import runpy
import tempfile
from unittest import mock

from botocore.exceptions import ClientError
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.x509.oid import NameOID


class SecretsManager:
    def __init__(self, values):
        self.values = values
        self.created = 0

    def get_secret_value(self, SecretId):
        if SecretId not in self.values:
            raise ClientError({'Error': {'Code': 'ResourceNotFoundException', 'Message': 'missing'}}, 'GetSecretValue')
        return {'SecretString': self.values[SecretId]}

    def create_secret(self, Name, SecretString):
        assert Name not in self.values
        self.values[Name] = SecretString
        self.created += 1


def tls_pair():
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, 'test.example')])
    now = datetime.datetime.now(datetime.timezone.utc)
    cert = (x509.CertificateBuilder().subject_name(name).issuer_name(name).public_key(key.public_key())
            .serial_number(x509.random_serial_number()).not_valid_before(now - datetime.timedelta(minutes=1))
            .not_valid_after(now + datetime.timedelta(days=1))
            .add_extension(x509.SubjectAlternativeName([x509.DNSName('test.example')]), critical=False)
            .sign(key, hashes.SHA256()))
    return (cert.public_bytes(serialization.Encoding.PEM).decode(),
            key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
                              serialization.NoEncryption()).decode())


def main():
    cert, key = tls_pair()
    client = SecretsManager({'zabbix-ha/traefik_tls_cert': cert, 'zabbix-ha/traefik_tls_key': key})
    script = Path(__file__).resolve().parents[1] / 'scripts/bootstrap-aws-secrets.py'
    with tempfile.TemporaryDirectory() as directory:
        path = Path(directory) / 'secrets'
        with mock.patch('boto3.client', return_value=client), mock.patch.dict(os.environ, {'ZABBIX_SECRET_EXPORT': str(path), 'ZABBIX_FRONTEND_HOST': 'test.example'}), contextlib.redirect_stdout(io.StringIO()):
            runpy.run_path(str(script), run_name='__main__')
            snapshot = dict(client.values)
            count = client.created
            runpy.run_path(str(script), run_name='__main__')
            assert client.values == snapshot and client.created == count
            assert path.stat().st_mode & 0o777 == 0o600
            assert 'zabbix-ha/zabbix_server_cert' in snapshot
            assert 'zabbix-ha/zabbix_proxy_cert' in snapshot
            client.values['zabbix-ha/traefik_tls_key'] = tls_pair()[1]
            try:
                runpy.run_path(str(script), run_name='__main__')
            except SystemExit as exc:
                assert 'do not match' in str(exc)
            else:
                raise AssertionError('mismatched TLS key accepted')
            assert client.created == count
        generated = SecretsManager({})
        with mock.patch('boto3.client', return_value=generated), mock.patch.dict(os.environ, {'ZABBIX_SECRET_EXPORT': str(path), 'ZABBIX_FRONTEND_HOST': 'zabbix.wildeshanada.com'}), contextlib.redirect_stdout(io.StringIO()):
            runpy.run_path(str(script), run_name='__main__')
            cert = x509.load_pem_x509_certificate(generated.values['zabbix-ha/traefik_tls_cert'].encode())
            names = cert.extensions.get_extension_for_class(x509.SubjectAlternativeName).value.get_values_for_type(x509.DNSName)
            assert 'zabbix.wildeshanada.com' in names
            assert cert.issuer == x509.load_pem_x509_certificate(generated.values['zabbix-ha/zabbix_ca'].encode()).subject
            snapshot, count = dict(generated.values), generated.created
            runpy.run_path(str(script), run_name='__main__')
            assert generated.values == snapshot and generated.created == count
    print('AWS certificate bootstrap: creation, reuse, file mode and TLS mismatch verified')


if __name__ == '__main__':
    main()
