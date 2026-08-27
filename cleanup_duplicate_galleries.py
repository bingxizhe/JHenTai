"""
清理 JHenTai 下载目录中因 sanitizedTitle 算法变更产生的重复目录。

背景：
  旧算法 legacyGalleryTitle 截断到 85 字符，新算法 computeSanitizedGalleryTitle
  截断到 200 字节。同一 gid 可能有两个目录（旧截断标题 + 新完整标题）。

逻辑：
  对每个有重复目录的 gid，保留文件数更多的目录（含图片更完整），
  删除文件数较少的冗余目录。文件数相同时保留目录名更长的（新算法保留更多标题）。

用法：
  python cleanup_duplicate_galleries.py          # 预览（不删除）
  python cleanup_duplicate_galleries.py --run     # 实际执行删除
"""

import os
import re
import sys
import collections

DOWNLOAD_PATH = r'G:\jhentai'
GID_PATTERN = re.compile(r'^(\d+) - ')


def scan_duplicate_dirs():
    """扫描下载目录，返回 {gid: [dir_names]} 中有重复的 gid。"""
    all_dirs = [d for d in os.listdir(DOWNLOAD_PATH)
                if os.path.isdir(os.path.join(DOWNLOAD_PATH, d))]

    gid_dirs = collections.defaultdict(list)
    for d in all_dirs:
        m = GID_PATTERN.match(d)
        if not m:
            continue
        gid = int(m.group(1))
        gid_dirs[gid].append(d)

    return {gid: dlist for gid, dlist in gid_dirs.items() if len(dlist) > 1}


def file_count(dir_name):
    """返回目录内文件+子目录数量。"""
    full = os.path.join(DOWNLOAD_PATH, dir_name)
    return len(os.listdir(full))


def pick_dir_to_delete(dir_names):
    """返回应删除的目录名。保留文件数多的；文件数相同则保留目录名更长的。"""
    if len(dir_names) != 2:
        raise ValueError(f"Expected 2 dirs, got {len(dir_names)}")

    d1, d2 = dir_names
    c1, c2 = file_count(d1), file_count(d2)

    if c1 > c2:
        return d2  # d2 文件少，删 d2
    elif c2 > c1:
        return d1  # d1 文件少，删 d1
    else:
        # 文件数相同，保留目录名更长的（新算法截断更长 = 更完整标题）
        return d1 if len(d1) < len(d2) else d2


def main():
    do_run = '--run' in sys.argv

    duplicates = scan_duplicate_dirs()
    print(f"下载目录: {DOWNLOAD_PATH}")
    print(f"发现 {len(duplicates)} 个重复 gid")
    print(f"模式: {'实际删除' if do_run else '预览（加 --run 执行删除）'}")
    print()

    total_deleted = 0
    total_freed = 0

    for gid in sorted(duplicates.keys()):
        dir_names = duplicates[gid]
        to_delete = pick_dir_to_delete(dir_names)
        to_keep = [d for d in dir_names if d != to_delete][0]

        full_path = os.path.join(DOWNLOAD_PATH, to_delete)
        size = sum(
            os.path.getsize(os.path.join(full_path, f))
            for f in os.listdir(full_path)
            if os.path.isfile(os.path.join(full_path, f))
        )

        print(f"gid={gid}")
        print(f"  保留: {to_keep} ({file_count(to_keep)} 文件)")
        print(f"  删除: {to_delete} ({file_count(to_delete)} 文件, {size / 1024 / 1024:.1f} MB)")

        if do_run:
            import shutil
            shutil.rmtree(full_path)

        total_deleted += 1
        total_freed += size

    print()
    print(f"总计: 删除 {total_deleted} 个冗余目录, 释放 {total_freed / 1024 / 1024:.1f} MB")

    if not do_run:
        print("\n这是预览模式。加 --run 参数执行实际删除：")
        print(f"  python {os.path.basename(__file__)} --run")


if __name__ == '__main__':
    main()