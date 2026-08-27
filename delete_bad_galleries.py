import sqlite3, os, re

db_path = os.path.join(os.environ['APPDATA'], 'top.jtmonster', 'jhentai', 'db.sqlite')
download_path = r'G:\jhentai'
visible_dir = os.path.join(os.environ['APPDATA'], 'top.jtmonster', 'jhentai')

conn = sqlite3.connect(db_path)
c = conn.cursor()

# Find galleries where cover image doesn't exist
c.execute('SELECT gid, sanitized_title FROM gallery_downloaded_v2')
bad_gids = []

for gid, sanitized in c.fetchall():
    dir_name = f'{gid} - {sanitized}'
    dir_path = os.path.join(download_path, dir_name)

    if not os.path.exists(dir_path):
        bad_gids.append((gid, sanitized, 'dir_missing'))
        continue

    # Check if cover (serialNo=0) file exists
    c2 = conn.cursor()
    c2.execute('SELECT path FROM image WHERE gid=? AND serialNo=0', (gid,))
    row = c2.fetchone()
    if row is None or row[0] is None:
        bad_gids.append((gid, sanitized, 'no_cover_record'))
        continue

    img_path = row[0]
    if os.path.isabs(img_path):
        abs_path = img_path
    else:
        abs_path = os.path.normpath(os.path.join(visible_dir, img_path))

    if not os.path.exists(abs_path):
        bad_gids.append((gid, sanitized, 'cover_file_missing'))

print(f'发现 {len(bad_gids)} 个封面缺失的画廊')

# Show details
for gid, sanitized, reason in bad_gids:
    dir_name = f'{gid} - {sanitized}'
    dir_path = os.path.join(download_path, dir_name)
    if os.path.exists(dir_path):
        files = os.listdir(dir_path)
        c.execute('SELECT path FROM image WHERE gid=? AND serialNo=0', (gid,))
        row = c.fetchone()
        db_path_str = row[0] if row else None
        print(f'  gid={gid} ({reason}): DB路径={os.path.basename(db_path_str) if db_path_str else None}, 磁盘文件={[f for f in files if f.startswith("0.")]}')
    else:
        print(f'  gid={gid} ({reason}): 目录不存在')

# Delete these galleries
import shutil
deleted = 0
for gid, sanitized, reason in bad_gids:
    # Delete from DB
    c.execute('DELETE FROM image WHERE gid=?', (gid,))
    img_count = c.rowcount
    c.execute('DELETE FROM gallery_downloaded_v2 WHERE gid=?', (gid,))
    gal_count = c.rowcount

    # Delete disk directory
    dir_name = f'{gid} - {sanitized}'
    dir_path = os.path.join(download_path, dir_name)
    if os.path.exists(dir_path):
        shutil.rmtree(dir_path, ignore_errors=True)

    deleted += 1

conn.commit()
print(f'\n已删除 {deleted} 个错误画廊')

# Verify
c.execute('SELECT COUNT(*) FROM gallery_downloaded_v2')
print(f'DB剩余画廊数: {c.fetchone()[0]}')
disk_count = sum(1 for d in os.listdir(download_path) if os.path.isdir(os.path.join(download_path, d)))
print(f'磁盘剩余目录数: {disk_count}')

conn.close()
