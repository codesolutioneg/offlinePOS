function required(name: string): string {
  const value = process.env[name];
  if (!value) throw new Error(`${name} is not set (see .env.example)`);
  return value;
}

export const config = () => ({
  port: Number(process.env.PORT ?? 8080),
  host: process.env.HOST ?? '0.0.0.0',
  databaseUrl: required('DATABASE_URL'),
  storageDir: process.env.STORAGE_DIR ?? '/data/backups',
  adminToken: process.env.ADMIN_TOKEN ?? '',
  maxBackupBytes: Number(process.env.MAX_BACKUP_MB ?? 1024) * 1024 * 1024,
  webDir: process.env.WEB_DIR ?? '/app/web',
  voucherBaseUrl: process.env.VOUCHER_BASE_URL ?? '',
  voucherAdminKey: process.env.VOUCHER_ADMIN_KEY ?? '',
  /// Dishflow Firebase (tax upload). Empty = feature off until credentials are set.
  firebaseProjectId: process.env.FIREBASE_PROJECT_ID ?? '',
  firebaseCredentialsFile: process.env.FIREBASE_SERVICE_ACCOUNT_FILE ?? '',
  firebaseCredentialsJson: process.env.FIREBASE_SERVICE_ACCOUNT ?? '',
  etaProxyBase: process.env.ETA_PROXY_BASE ?? '',
  taxDefaultConnectionId:
    process.env.TAX_DEFAULT_CONNECTION_ID ?? 'yFsBtvlradoAkKSascZ3',
});
