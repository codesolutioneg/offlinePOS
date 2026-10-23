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
});
