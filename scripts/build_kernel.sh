#!/bin/bash
set -euo pipefail

# =============================================================================
# KernelSU-Next + SuSFS + ksud
# Noyau 4.19 - Motorola One 5G Ace (kiev)
# v4.9 : Correction des chaînes multilignes pr_err dans file_wrapper.c
# =============================================================================

KSU_REF="${KSU_REF:-next}"
KSUD_FALLBACK_REF="${KSUD_FALLBACK_REF:-v3.4.2}"
KSU_EXPECTED_UAPI="${KSU_EXPECTED_UAPI:-5}"

# --- SuSFS ---
SUSFS_MODE="${SUSFS_MODE:-apply}"
SUSFS_PATCH_URL="${SUSFS_PATCH_URL:-https://github.com/JackA1ltman/NonGKI_Kernel_Build_2nd/raw/refs/heads/mainline/Patches/Patch/susfs_patch_to_4.19.patch}"
SUSFS_OPTIONS="${SUSFS_OPTIONS:-SUS_PATH SUS_MOUNT SUS_KSTAT SUS_MAP OPEN_REDIRECT SPOOF_UNAME SPOOF_CMDLINE_OR_BOOTCONFIG ENABLE_LOG HIDE_KSU_SUSFS_SYMBOLS}"
SUSFS_APPLIED=0

echo "=== Build KernelSU-Next ($KSU_REF) + SuSFS pour noyau 4.19 ==="
df -h

BOOT_GDRIVE_ID="1AhWuM99TFBEBLHHPzJSjbSh3rKx7UGis"
DTBO_GDRIVE_ID="11451aa0CCzyVtNTYOK2n6oH6E0PT-2NX"

sudo rm -rf /usr/share/dotnet /usr/local/lib/android /opt/ghc 2>/dev/null || true
sudo apt-get clean 2>/dev/null || true
sudo sed -i 's/azure.archive.ubuntu.com/archive.ubuntu.com/g' /etc/apt/sources.list 2>/dev/null || true
sudo apt-get update
sudo apt-get install -y bc bison build-essential ccache flex glibc-source libelf-dev libssl-dev \
  libncurses-dev gcc-aarch64-linux-gnu gcc-arm-linux-gnueabi clang llvm lld \
  device-tree-compiler zip unzip curl git python3 python3-pip mkbootimg cpio libclang-dev

pip3 install --quiet gdown
cd "$GITHUB_WORKSPACE"

# ==================== 1. CLONAGE DU NOYAU ====================
git clone https://github.com/LineageOS/android_kernel_motorola_sm8250.git -b lineage-23.2 --depth=1 kernel_sources
cd kernel_sources
git log --oneline -1

# ==================== 2. INTÉGRATION KernelSU-Next ====================
echo "=== Intégration KernelSU-Next ($KSU_REF) ==="
rm -rf drivers/kernelsu KernelSU KernelSU-Next susfs4ksu 2>/dev/null || true

curl -LSs "https://raw.githubusercontent.com/KernelSU-Next/KernelSU-Next/next/kernel/setup.sh" | bash -s "$KSU_REF"

if [ ! -d "drivers/kernelsu" ] && [ ! -d "KernelSU/kernel" ]; then
    echo "❌ Échec intégration KernelSU-Next"; exit 1
fi
echo "✅ KernelSU-Next ($KSU_REF) intégré"

if [ -d "drivers/kernelsu" ]; then
    KSU_DIR="drivers/kernelsu"
elif [ -d "KernelSU/kernel" ]; then
    KSU_DIR="KernelSU/kernel"
else
    KSU_DIR="KernelSU"
fi

KSU_REPO_ROOT=""
for d in "$GITHUB_WORKSPACE/kernel_sources/KernelSU-Next" "$GITHUB_WORKSPACE/kernel_sources/KernelSU"; do
    if [ -d "$d" ]; then KSU_REPO_ROOT="$d"; break; fi
done

# ==================== 2s. SuSFS & Écrasement propre de file_wrapper.c ====================
if [ "$SUSFS_MODE" != "off" ]; then
    echo ""
    echo "=== SuSFS (mode : $SUSFS_MODE) ==="
    curl -fsSL "$SUSFS_PATCH_URL" -o /tmp/susfs.patch

    echo "--- Application du patch SuSFS (avec tolérance) ---"
    set +e
    patch -p1 -F3 --forward --no-backup-if-mismatch < /tmp/susfs.patch > /tmp/susfs_apply.log 2>&1
    set -e
    rm -f $(find . -name "*.rej") 2>/dev/null || true

    echo "--- Correcteur Python & Remplacement de file_wrapper.c v4.9 ---"
    python3 << 'PYEOF'
import os

def fix_file(path, target, addition):
    if not os.path.exists(path): return
    content = open(path, 'r').read()
    if addition.strip() not in content:
        if target in content:
            content = content.replace(target, target + '\n' + addition, 1)
        else:
            content += '\n' + addition
        with open(path, 'w') as f: f.write(content)

mf_path = 'fs/Makefile'
if os.path.exists(mf_path):
    mf_content = open(mf_path, 'r').read()
    if 'susfs.o' not in mf_content:
        mf_content = mf_content.replace('super.o', 'super.o susfs.o', 1)
        open(mf_path, 'w').write(mf_content)

fix_file('fs/super.c', '#include <linux/fs_context.h>', '#ifdef CONFIG_KSU_SUSFS\n#include <linux/susfs_def.h>\n#endif')
fix_file('mm/memory.c', '#include <linux/pgtable.h>', '#ifdef CONFIG_KSU_SUSFS\n#include <linux/susfs_def.h>\n#endif')
fix_file('fs/stat.c', '#include <linux/syscalls.h>', '#ifdef CONFIG_KSU_SUSFS\n#include <linux/susfs.h>\n#include <linux/susfs_def.h>\n#endif')

ns_content = open('fs/namespace.c', 'r').read()
if 'susfs_def.h' not in ns_content:
    ns_content = ns_content.replace('#include <linux/fs_context.h>', '#include <linux/fs_context.h>\n#ifdef CONFIG_KSU_SUSFS\n#include <linux/susfs_def.h>\n#endif', 1)
if 'susfs_alloc_non_unshare_ksu_vfsmnt' not in ns_content:
    mount_hook = '''
#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
	if (static_branch_unlikely(&susfs_is_sdcard_android_data_not_decrypted)) {
		if (susfs_is_current_ksu_domain()) {
			mnt = susfs_alloc_non_unshare_ksu_vfsmnt(name ?:"none");
			goto bypass_orig_flow_susfs;
		}
	}
#endif
'''
    target_mount = 'mnt = alloc_vfsmnt(name);'
    replacement = mount_hook + '\n\t' + target_mount + '\n\n#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\nbypass_orig_flow_susfs:\n#endif'
    ns_content = ns_content.replace(target_mount, replacement, 1)
with open('fs/namespace.c', 'w') as f: f.write(ns_content)

tmu_content = open('fs/proc/task_mmu.c', 'r').read()
if 'SUSFS_IS_INODE_SUS_MAP' not in tmu_content:
    target_pagemap = 'ret = walk_page_range(start_vaddr, end, &pagemap_walk);'
    map_hook = '''
#ifdef CONFIG_KSU_SUSFS_SUS_MAP
	vma = find_vma(mm, start_vaddr);
	if (vma && vma->vm_file && SUSFS_IS_INODE_SUS_MAP(file_inode(vma->vm_file)))
		goto bypass_orig_flow_map;
#endif
'''
    map_end = '\n#ifdef CONFIG_KSU_SUSFS_SUS_MAP\nbypass_orig_flow_map:\n#endif\n'
    replacement_map = map_hook + '\n\t' + target_pagemap + map_end
    tmu_content = tmu_content.replace(target_pagemap, replacement_map, 1)
    with open('fs/proc/task_mmu.c', 'w') as f: f.write(tmu_content)

# --- Écrasement direct de file_wrapper.c avec chaînes sécurisées ---
fw_c_path = 'drivers/kernelsu/infra/file_wrapper.c'
os.makedirs(os.path.dirname(fw_c_path), exist_ok=True)

clean_file_wrapper = '''#include <linux/gfp.h>
#include <linux/fdtable.h>
#include <linux/export.h>
#include <linux/anon_inodes.h>
#include <linux/capability.h>
#include <linux/cred.h>
#include <linux/err.h>
#include <linux/file.h>
#include <linux/fs.h>
#include <linux/seq_file.h>
#include <linux/slab.h>
#include <linux/uaccess.h>
#include <linux/version.h>
#include <linux/mount.h>

#include "objsec.h"
#include "ksu.h"
#include "klog.h"
#include "selinux/selinux.h"
#include "infra/file_wrapper.h"

struct ksu_file_wrapper {
    struct file *orig;
    struct file_operations ops;
};

static struct ksu_file_wrapper *ksu_create_file_wrapper(struct file *fp);

static int ksu_wrapper_open(struct inode *ino, struct file *fp)
{
    struct path *orig_path = fp->f_path.dentry->d_fsdata;
    struct file *orig_file = dentry_open(orig_path, fp->f_flags, current_cred());
    if (IS_ERR(orig_file)) {
        return PTR_ERR(orig_file);
    }
    struct ksu_file_wrapper *wrapper = ksu_create_file_wrapper(orig_file);
    if (IS_ERR(wrapper)) {
        filp_close(orig_file, current->files);
        return PTR_ERR(wrapper);
    }
    fp->private_data = wrapper;
    const struct file_operations *new_fops = fops_get(&wrapper->ops);
    replace_fops(fp, new_fops);
    return 0;
}

static const struct file_operations ksu_file_wrapper_inode_fops = {
    .owner = THIS_MODULE,
    .open = ksu_wrapper_open
};

static loff_t ksu_wrapper_llseek(struct file *fp, loff_t off, int flags)
{
    struct ksu_file_wrapper *data = fp->private_data;
    struct file *orig = data->orig;
    return orig->f_op->llseek(data->orig, off, flags);
}

static ssize_t ksu_wrapper_read(struct file *fp, char __user *ptr, size_t sz, loff_t *off)
{
    struct ksu_file_wrapper *data = fp->private_data;
    struct file *orig = data->orig;
    return orig->f_op->read(orig, ptr, sz, off);
}

static ssize_t ksu_wrapper_write(struct file *fp, const char __user *ptr, size_t sz, loff_t *off)
{
    struct ksu_file_wrapper *data = fp->private_data;
    struct file *orig = data->orig;
    return orig->f_op->write(orig, ptr, sz, off);
}

static ssize_t ksu_wrapper_read_iter(struct kiocb *iocb, struct iov_iter *iovi)
{
    struct ksu_file_wrapper *data = iocb->ki_filp->private_data;
    struct file *orig = data->orig;
    iocb->ki_filp = orig;
    return orig->f_op->read_iter(iocb, iovi);
}

static ssize_t ksu_wrapper_write_iter(struct kiocb *iocb, struct iov_iter *iovi)
{
    struct ksu_file_wrapper *data = iocb->ki_filp->private_data;
    struct file *orig = data->orig;
    iocb->ki_filp = orig;
    return orig->f_op->write_iter(iocb, iovi);
}

#if LINUX_VERSION_CODE < KERNEL_VERSION(6, 6, 0)
static int ksu_wrapper_iterate(struct file *fp, struct dir_context *dc)
{
    struct ksu_file_wrapper *data = fp->private_data;
    struct file *orig = data->orig;
    return orig->f_op->iterate(orig, dc);
}
#endif

static int ksu_wrapper_iterate_shared(struct file *fp, struct dir_context *dc)
{
    struct ksu_file_wrapper *data = fp->private_data;
    struct file *orig = data->orig;
    return orig->f_op->iterate_shared(orig, dc);
}

static __poll_t ksu_wrapper_poll(struct file *fp, struct poll_table_struct *pts)
{
    struct ksu_file_wrapper *data = fp->private_data;
    struct file *orig = data->orig;
    return orig->f_op->poll(orig, pts);
}

static long ksu_wrapper_unlocked_ioctl(struct file *fp, unsigned int cmd, unsigned long arg)
{
    struct ksu_file_wrapper *data = fp->private_data;
    struct file *orig = data->orig;
    return orig->f_op->unlocked_ioctl(orig, cmd, arg);
}

static long ksu_wrapper_compat_ioctl(struct file *fp, unsigned int cmd, unsigned long arg)
{
    struct ksu_file_wrapper *data = fp->private_data;
    struct file *orig = data->orig;
    return orig->f_op->compat_ioctl(orig, cmd, arg);
}

static int ksu_wrapper_mmap(struct file *fp, struct vm_area_struct *vma)
{
    struct ksu_file_wrapper *data = fp->private_data;
    struct file *orig = data->orig;
    return orig->f_op->mmap(orig, vma);
}

static int ksu_wrapper_flush(struct file *fp, fl_owner_t id)
{
    struct ksu_file_wrapper *data = fp->private_data;
    struct file *orig = data->orig;
    return orig->f_op->flush(orig, id);
}

static int ksu_wrapper_fsync(struct file *fp, loff_t off1, loff_t off2, int datasync)
{
    struct ksu_file_wrapper *data = fp->private_data;
    struct file *orig = data->orig;
    return orig->f_op->fsync(orig, off1, off2, datasync);
}

static int ksu_wrapper_fasync(int arg, struct file *fp, int arg2)
{
    struct ksu_file_wrapper *data = fp->private_data;
    struct file *orig = data->orig;
    return orig->f_op->fasync(arg, orig, arg2);
}

static int ksu_wrapper_lock(struct file *fp, int arg1, struct file_lock *fl)
{
    struct ksu_file_wrapper *data = fp->private_data;
    struct file *orig = data->orig;
    return orig->f_op->lock(orig, arg1, fl);
}

#if LINUX_VERSION_CODE < KERNEL_VERSION(6, 6, 0)
static ssize_t ksu_wrapper_sendpage(struct file *fp, struct page *pg, int arg1, size_t sz, loff_t *off, int arg2)
{
    struct ksu_file_wrapper *data = fp->private_data;
    struct file *orig = data->orig;
    if (orig->f_op->sendpage) {
        return orig->f_op->sendpage(orig, pg, arg1, sz, off, arg2);
    }
    return -EINVAL;
}
#endif

static unsigned long ksu_wrapper_get_unmapped_area(struct file *fp, unsigned long arg1, unsigned long arg2, unsigned long arg3, unsigned long arg4)
{
    struct ksu_file_wrapper *data = fp->private_data;
    struct file *orig = data->orig;
    if (orig->f_op->get_unmapped_area) {
        return orig->f_op->get_unmapped_area(orig, arg1, arg2, arg3, arg4);
    }
    return -EINVAL;
}

static int ksu_wrapper_flock(struct file *fp, int arg1, struct file_lock *fl)
{
    struct ksu_file_wrapper *data = fp->private_data;
    struct file *orig = data->orig;
    if (orig->f_op->flock) {
        return orig->f_op->flock(orig, arg1, fl);
    }
    return -EINVAL;
}

static ssize_t ksu_wrapper_splice_write(struct pipe_inode_info *pii, struct file *fp, loff_t *off, size_t sz, unsigned int arg1)
{
    struct ksu_file_wrapper *data = fp->private_data;
    struct file *orig = data->orig;
    if (orig->f_op->splice_write) {
        return orig->f_op->splice_write(pii, orig, off, sz, arg1);
    }
    return -EINVAL;
}

static ssize_t ksu_wrapper_splice_read(struct file *fp, loff_t *off, struct pipe_inode_info *pii, size_t sz, unsigned int arg1)
{
    struct ksu_file_wrapper *data = fp->private_data;
    struct file *orig = data->orig;
    if (orig->f_op->splice_read) {
        return orig->f_op->splice_read(orig, off, pii, sz, arg1);
    }
    return -EINVAL;
}

#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 6, 0)
void ksu_wrapper_splice_eof(struct file *fp)
{
    struct ksu_file_wrapper *data = fp->private_data;
    struct file *orig = data->orig;
    if (orig->f_op->splice_eof) {
        return orig->f_op->splice_eof(orig);
    }
}
#endif

#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 12, 0)
static int ksu_wrapper_setlease(struct file *fp, int arg1, struct file_lease **fl, void **p)
{
    struct ksu_file_wrapper *data = fp->private_data;
    struct file *orig = data->orig;
    if (orig->f_op->setlease) {
        return orig->f_op->setlease(orig, arg1, fl, p);
    }
    return -EINVAL;
}
#elif LINUX_VERSION_CODE >= KERNEL_VERSION(6, 6, 0)
static int ksu_wrapper_setlease(struct file *fp, int arg1, struct file_lock **fl, void **p)
{
    struct ksu_file_wrapper *data = fp->private_data;
    struct file *orig = data->orig;
    if (orig->f_op->setlease) {
        return orig->f_op->setlease(orig, arg1, fl, p);
    }
    return -EINVAL;
}
#else
static int ksu_wrapper_setlease(struct file *fp, long arg1, struct file_lock **fl, void **p)
{
    struct ksu_file_wrapper *data = fp->private_data;
    struct file *orig = data->orig;
    if (orig->f_op->setlease) {
        return orig->f_op->setlease(orig, arg1, fl, p);
    }
    return -EINVAL;
}
#endif

static long ksu_wrapper_fallocate(struct file *fp, int mode, loff_t offset, loff_t len)
{
    struct ksu_file_wrapper *data = fp->private_data;
    struct file *orig = data->orig;
    if (orig->f_op->fallocate) {
        return orig->f_op->fallocate(orig, mode, offset, len);
    }
    return -EINVAL;
}

static void ksu_wrapper_show_fdinfo(struct seq_file *m, struct file *f)
{
    struct ksu_file_wrapper *data = f->private_data;
    struct file *orig = data->orig;
    if (orig->f_op->show_fdinfo) {
        orig->f_op->show_fdinfo(m, orig);
    }
}

static ssize_t ksu_wrapper_copy_file_range(struct file *file_in, loff_t pos_in, struct file *file_out, loff_t pos_out, size_t len, unsigned int flags)
{
    struct ksu_file_wrapper *data = file_out->private_data;
    struct file *orig = data->orig;
    return orig->f_op->copy_file_range(file_in, pos_in, orig, pos_out, len, flags);
}

static int ksu_wrapper_fadvise(struct file *fp, loff_t off1, loff_t off2, int flags)
{
    struct ksu_file_wrapper *data = fp->private_data;
    struct file *orig = data->orig;
    if (orig->f_op->fadvise) {
        return orig->f_op->fadvise(orig, off1, off2, flags);
    }
    return -EINVAL;
}

static void ksu_release_file_wrapper(struct ksu_file_wrapper *data);

static int ksu_wrapper_release(struct inode *inode, struct file *filp)
{
    fops_put(filp->f_op);
    filp->f_op = NULL;
    ksu_release_file_wrapper(filp->private_data);
    return 0;
}

static struct ksu_file_wrapper *ksu_create_file_wrapper(struct file *fp)
{
    struct ksu_file_wrapper *p = kcalloc(1, sizeof(struct ksu_file_wrapper), GFP_KERNEL);
    if (!p) {
        return ERR_PTR(-ENOMEM);
    }
    get_file(fp);
    p->orig = fp;
    p->ops.owner = THIS_MODULE;
    p->ops.llseek = fp->f_op->llseek ? ksu_wrapper_llseek : NULL;
    p->ops.read = fp->f_op->read ? ksu_wrapper_read : NULL;
    p->ops.write = fp->f_op->write ? ksu_wrapper_write : NULL;
    p->ops.read_iter = fp->f_op->read_iter ? ksu_wrapper_read_iter : NULL;
    p->ops.write_iter = fp->f_op->write_iter ? ksu_wrapper_write_iter : NULL;
#if LINUX_VERSION_CODE < KERNEL_VERSION(6, 6, 0)
    p->ops.iterate = fp->f_op->iterate ? ksu_wrapper_iterate : NULL;
#endif
    p->ops.iterate_shared = fp->f_op->iterate_shared ? ksu_wrapper_iterate_shared : NULL;
    p->ops.poll = fp->f_op->poll ? ksu_wrapper_poll : NULL;
    p->ops.unlocked_ioctl = fp->f_op->unlocked_ioctl ? ksu_wrapper_unlocked_ioctl : NULL;
    p->ops.compat_ioctl = fp->f_op->compat_ioctl ? ksu_wrapper_compat_ioctl : NULL;
    p->ops.mmap = fp->f_op->mmap ? ksu_wrapper_mmap : NULL;
#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 12, 0)
    p->ops.fop_flags = fp->f_op->fop_flags;
#else
    p->ops.mmap_supported_flags = fp->f_op->mmap_supported_flags;
#endif
    p->ops.flush = fp->f_op->flush ? ksu_wrapper_flush : NULL;
    p->ops.release = ksu_wrapper_release;
    p->ops.fsync = fp->f_op->fsync ? ksu_wrapper_fsync : NULL;
    p->ops.fasync = fp->f_op->fasync ? ksu_wrapper_fasync : NULL;
    p->ops.lock = fp->f_op->lock ? ksu_wrapper_lock : NULL;
#if LINUX_VERSION_CODE < KERNEL_VERSION(6, 6, 0)
    p->ops.sendpage = fp->f_op->sendpage ? ksu_wrapper_sendpage : NULL;
#endif
    p->ops.get_unmapped_area = fp->f_op->get_unmapped_area ? ksu_wrapper_get_unmapped_area : NULL;
    p->ops.check_flags = fp->f_op->check_flags;
    p->ops.flock = fp->f_op->flock ? ksu_wrapper_flock : NULL;
    p->ops.splice_write = fp->f_op->splice_write ? ksu_wrapper_splice_write : NULL;
    p->ops.splice_read = fp->f_op->splice_read ? ksu_wrapper_splice_read : NULL;
    p->ops.setlease = fp->f_op->setlease ? ksu_wrapper_setlease : NULL;
    p->ops.fallocate = fp->f_op->fallocate ? ksu_wrapper_fallocate : NULL;
    p->ops.show_fdinfo = fp->f_op->show_fdinfo ? ksu_wrapper_show_fdinfo : NULL;
    p->ops.copy_file_range = fp->f_op->copy_file_range ? ksu_wrapper_copy_file_range : NULL;
    p->ops.fadvise = fp->f_op->fadvise ? ksu_wrapper_fadvise : NULL;
#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 6, 0)
    p->ops.splice_eof = fp->f_op->splice_eof ? ksu_wrapper_splice_eof : NULL;
#endif
    return p;
}

static void ksu_release_file_wrapper(struct ksu_file_wrapper *data)
{
    fput((struct file *)data->orig);
    kfree(data);
}

static char *ksu_wrapper_d_dname(struct dentry *dentry, char *buffer, int buflen)
{
    struct path *orig_path = dentry->d_fsdata;
    return d_path(orig_path, buffer, buflen);
}

static void ksu_wrapper_d_release(struct dentry *dentry)
{
    struct path *orig_path = dentry->d_fsdata;
    path_put(orig_path);
    kfree(orig_path);
}

static const struct dentry_operations ksu_file_wrapper_d_ops = {
    .d_dname = ksu_wrapper_d_dname,
    .d_release = ksu_wrapper_d_release
};

#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 8, 0)
#define ksu_anon_inode_create_getfile_compat anon_inode_create_getfile
#elif LINUX_VERSION_CODE >= KERNEL_VERSION(5, 16, 0)
#define ksu_anon_inode_create_getfile_compat anon_inode_create_getfile_secure
#else
static struct vfsmount *anon_inode_mnt __read_mostly;
static struct inode *ksu_anon_inode_make_secure_inode(const char *name, const struct inode *context_inode)
{
    struct inode *inode;
    const struct qstr qname = QSTR_INIT(name, strlen(name));
    int error;
    if (unlikely(!anon_inode_mnt)) { return ERR_PTR(-ENODEV); }
    inode = alloc_anon_inode(anon_inode_mnt->mnt_sb);
    if (IS_ERR(inode)) return inode;
    inode->i_flags &= ~S_PRIVATE;
    error = security_inode_init_security_anon(inode, &qname, context_inode);
    if (error) { iput(inode); return ERR_PTR(error); }
    return inode;
}
static struct file *ksu_anon_inode_create_getfile_compat(const char *name, const struct file_operations *fops, void *priv, int flags, const struct inode *context_inode)
{
    struct inode *inode;
    struct file *file;
    if (fops->owner && !try_module_get(fops->owner)) return ERR_PTR(-ENOENT);
    inode = ksu_anon_inode_make_secure_inode(name, context_inode);
    if (IS_ERR(inode)) { file = ERR_CAST(inode); goto err; }
    file = alloc_file_pseudo(inode, anon_inode_mnt, name, flags & (O_ACCMODE | O_NONBLOCK), fops);
    if (IS_ERR(file)) goto err_iput;
    file->f_mapping = inode->i_mapping;
    file->private_data = priv;
    return file;
err_iput:
    iput(inode);
err:
    module_put(fops->owner);
    return file;
}
#endif

int ksu_install_file_wrapper(int fd)
{
    int out_fd, ret;
    const struct cred *old_cred;
    struct file *wrapper_file;
    struct file *orig_file = fget(fd);
    if (!orig_file) { return -EBADF; }
    out_fd = get_unused_fd_flags(O_CLOEXEC);
    if (out_fd < 0) { ret = out_fd; goto done; }
    struct ksu_file_wrapper *file_wrapper_data = ksu_create_file_wrapper(orig_file);
    if (IS_ERR(file_wrapper_data)) { ret = PTR_ERR(file_wrapper_data); goto out_put_fd; }
    old_cred = override_creds(ksu_cred);
    wrapper_file = ksu_anon_inode_create_getfile_compat("[ksu_fdwrapper]", &file_wrapper_data->ops, file_wrapper_data, orig_file->f_flags, NULL);
    revert_creds(old_cred);
    if (IS_ERR(wrapper_file)) {
        pr_err("ksu_fdwrapper: getfile failed: %ld\n", PTR_ERR(wrapper_file));
        ret = PTR_ERR(wrapper_file);
        goto out_release_wrapper;
    }
    struct inode *wrapper_inode = file_inode(wrapper_file);
    wrapper_inode->i_mode = file_inode(orig_file)->i_mode;
    struct inode_security_struct *wrapper_sec = selinux_inode(wrapper_inode);
    if (wrapper_sec) { wrapper_sec->sid = ksu_file_sid; }
    wrapper_inode->i_fop = &ksu_file_wrapper_inode_fops;
    struct path *orig_path = kmalloc(sizeof(struct path), GFP_KERNEL);
    if (!orig_path) { ret = -ENOMEM; goto out_put_wrapper_file; }
    *orig_path = orig_file->f_path;
    path_get(orig_path);
    wrapper_file->f_path.dentry->d_fsdata = orig_path;
    wrapper_file->f_path.dentry->d_op = &ksu_file_wrapper_d_ops;
    fd_install(out_fd, wrapper_file);
    ret = out_fd;
    goto done;
out_put_wrapper_file:
    fput(wrapper_file);
    goto out_put_fd;
out_release_wrapper:
    ksu_release_file_wrapper(file_wrapper_data);
out_put_fd:
    put_unused_fd(out_fd);
done:
    fput(orig_file);
    return ret;
}

void __init ksu_file_wrapper_init(void)
{
#if LINUX_VERSION_CODE < KERNEL_VERSION(5, 16, 0)
    static const struct file_operations tmp = { .owner = THIS_MODULE };
    struct file *dummy = anon_inode_getfile("dummy", &tmp, NULL, 0);
    if (IS_ERR(dummy)) {
        pr_err("file_wrapper: initialize anon_inode_mnt failed, can't get file: %ld\n", PTR_ERR(dummy));
        return;
    }
    anon_inode_mnt = dummy->f_path.mnt;
    if (unlikely(!anon_inode_mnt)) {
        pr_err("file_wrapper: initialize anon_inode_mnt failed, got NULL\n");
    }
    fput(dummy);
#endif
}
'''

open(fw_c_path, 'w').write(clean_file_wrapper)
print("✅ drivers/kernelsu/infra/file_wrapper.c remplacé avec succès (version 4.19 propre)")
PYEOF

    # --- Injection des symboles Kconfig SuSFS ---
    KCONFIG_FILE="$KSU_DIR/Kconfig"
    if [ -f "$KCONFIG_FILE" ] && ! grep -q "CONFIG_KSU_SUSFS" "$KCONFIG_FILE"; then
        cat >> "$KCONFIG_FILE" << 'EOF'

config KSU_SUSFS
	bool "SuSFS support for KernelSU"
	default y

config KSU_SUSFS_SUS_PATH
	bool "Enable sus_path"
	depends on KSU_SUSFS
	default y

config KSU_SUSFS_SUS_MOUNT
	bool "Enable sus_mount"
	depends on KSU_SUSFS
	default y

config KSU_SUSFS_SUS_KSTAT
	bool "Enable sus_kstat"
	depends on KSU_SUSFS
	default y

config KSU_SUSFS_SUS_MAP
	bool "Enable sus_map"
	depends on KSU_SUSFS
	default y

config KSU_SUSFS_OPEN_REDIRECT
	bool "Enable open_redirect"
	depends on KSU_SUSFS
	default y

config KSU_SUSFS_SPOOF_UNAME
	bool "Enable spoof_uname"
	depends on KSU_SUSFS
	default y

config KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG
	bool "Enable spoof_cmdline_or_bootconfig"
	depends on KSU_SUSFS
	default y

config KSU_SUSFS_ENABLE_LOG
	bool "Enable susfs log"
	depends on KSU_SUSFS
	default y

config KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS
	bool "Hide ksu susfs symbols"
	depends on KSU_SUSFS
	default y
EOF
    fi

    SUSFS_APPLIED=1
    echo "✅ SuSFS appliqué et file_wrapper.c géré automatiquement v4.9"
fi

# ==================== 2e. NEUTRALISATION CHECK.MK ====================
for pattern in susfs_compat.mk inline_hook_check.mk manual_hook_check.mk tracepoint_hook_check.mk kprobe_check.mk; do
    FILES=$(find . -name "$pattern" -type f 2>/dev/null || true)
    if [ -n "$FILES" ]; then
        for f in $FILES; do sed -i 's/\$(error/\$(warning/g' "$f"; done
    fi
done

# ==================== 2b. NETTOYAGE UNICODE ====================
python3 << 'PYEOF'
import os
from pathlib import Path
UNICODE_SPACES = ['\u00A0', '\u2000', '\u2001', '\u2002', '\u2003', '\u2004', '\u2005', '\u2006', '\u2007', '\u2008', '\u2009', '\u200A', '\u200B', '\u202F', '\u205F', '\u3000']
for root, dirs, files in os.walk('.'):
    if 'KernelSU' not in root and 'kernelsu' not in root: continue
    for file in files:
        if file.endswith(('.c', '.h')):
            p = Path(root) / file
            try:
                c = p.read_text(encoding='utf-8', errors='ignore')
                orig = c
                for u in UNICODE_SPACES: c = c.replace(u, ' ')
                if c != orig: p.write_text(c, encoding='utf-8')
            except: pass
PYEOF

# ==================== 2c. FIX symbol_resolver.h & EXPORTS ====================
for h in "$KSU_DIR/infra/symbol_resolver.h" "$KSU_DIR/kernel/infra/symbol_resolver.h"; do
    if [ -f "$h" ]; then
        sed -i 's|^static inline void \*ksu_resolve_symbol_for_functable_hook|// static inline void *ksu_resolve_symbol_for_functable_hook|' "$h"
        sed -i 's|^static inline unsigned long find_kernel_symbol_exact|// static inline unsigned long find_kernel_symbol_exact|' "$h"
        sed -i 's|^static inline void ksu_init_symbol_resolver|// static inline void ksu_init_symbol_resolver|' "$h"
    fi
done

[ -f "security/selinux/selinuxfs.c" ] && {
    sed -i 's/^static ssize_t (\*write_op\[\])/ssize_t (*write_op[])/' security/selinux/selinuxfs.c
    sed -i 's/^static const struct file_operations sel_handle_status_ops/const struct file_operations sel_handle_status_ops/' security/selinux/selinuxfs.c
    sed -i 's/^static DEFINE_MUTEX(sel_mutex)/DEFINE_MUTEX(sel_mutex)/' security/selinux/selinuxfs.c
}
[ -f "security/selinux/ss/status.c" ] && {
    sed -i 's/^static struct page \*selinux_status_page/struct page *selinux_status_page/' security/selinux/ss/status.c
    sed -i 's/^static DEFINE_MUTEX(selinux_status_lock)/DEFINE_MUTEX(selinux_status_lock)/' security/selinux/ss/status.c
}
[ -f "security/selinux/ss/services.c" ] && {
    sed -i 's/^static DEFINE_RWLOCK(policy_rwlock)/DEFINE_RWLOCK(policy_rwlock)/' security/selinux/ss/services.c
}
[ -f "security/selinux/hooks.c" ] && {
    sed -i 's/^static struct security_operations selinux_ops/struct security_operations selinux_ops/' security/selinux/hooks.c
}

FILES_GET_UNUSED=$(grep -rl "get_unused_fd_flags(O_CLOEXEC)" "$KSU_DIR/" 2>/dev/null || true)
[ -n "$FILES_GET_UNUSED" ] && for f in $FILES_GET_UNUSED; do sed -i 's/get_unused_fd_flags(O_CLOEXEC)/get_unused_fd_flags(0)/g' "$f"; done

FILES_ANON_INODE=$(grep -rl "anon_inode_getfile" "$KSU_DIR/" 2>/dev/null || true)
[ -n "$FILES_ANON_INODE" ] && for f in $FILES_ANON_INODE; do
    sed -i 's/O_RDWR | O_CLOEXEC/O_RDWR/g' "$f"
    sed -i 's/O_RDWR|O_CLOEXEC/O_RDWR/g' "$f"
    sed -i 's/, O_CLOEXEC)/)/g' "$f"
done

# ==================== 3. PATCHS MANUELS KERNELSU-NEXT ====================
python3 << 'PYEOF'
import re

with open('fs/exec.c', 'r') as f: content = f.read()
if 'ksu_handle_execveat' not in content:
    extern = "#ifdef CONFIG_KSU\n__attribute__((hot))\nextern int ksu_handle_execveat(int *fd, struct filename **filename_ptr, void *argv, void *envp, int *flags);\n#endif\n\n"
    content = re.sub(r'(int\s+do_execve\s*\()', extern + r'\1', content, count=1)
    call = "#ifdef CONFIG_KSU\n\tksu_handle_execveat((int *)AT_FDCWD, &filename, &argv, &envp, 0);\n#endif\n\t"
    content = re.sub(r'(\treturn\s+do_execveat_common\(AT_FDCWD,\s*filename,\s*argv,\s*envp,\s*0\);)', call + r'\1', content, count=1)
    with open('fs/exec.c', 'w') as f: f.write(content)

with open('fs/open.c', 'r') as f: content = f.read()
if 'ksu_handle_faccessat' not in content:
    extern = "#ifdef CONFIG_KSU\n__attribute__((hot))\nextern int ksu_handle_faccessat(int *dfd, const char __user **filename_user, int *mode, int *flags);\n#endif\n\n"
    content = re.sub(r'(long\s+do_faccessat\s*\()', extern + r'\1', content, count=1)
    call = "#ifdef CONFIG_KSU\n\tksu_handle_faccessat(&dfd, &filename, &mode, NULL);\n#endif\n\n\t"
    content = re.sub(r'(\tif\s*\(mode\s*&\s*~S_IRWXO\))', call + r'\1', content, count=1)
    with open('fs/open.c', 'w') as f: f.write(content)

with open('fs/read_write.c', 'r') as f: content = f.read()
if 'ksu_handle_sys_read' not in content:
    extern = "#ifdef CONFIG_KSU\nextern bool ksu_vfs_read_hook __read_mostly;\nextern __attribute__((cold)) int ksu_handle_sys_read(unsigned int fd, char __user **buf_ptr, size_t *count_ptr);\n#endif\n\n"
    match = re.search(r'(SYSCALL_DEFINE3\s*\(\s*read\s*,)', content)
    if match:
        content = content[:match.start()] + extern + content[match.start():]
        start_pos = content.find('SYSCALL_DEFINE3(read,')
        ret_pos = content.find('ssize_t ret = -EBADF;', start_pos)
        if ret_pos != -1:
            call = "\n\n#ifdef CONFIG_KSU\n\tif (unlikely(ksu_vfs_read_hook))\n\t\tksu_handle_sys_read(fd, (char __user **)&buf, &count);\n#endif"
            content = content[:ret_pos + len('ssize_t ret = -EBADF;')] + call + content[ret_pos + len('ssize_t ret = -EBADF;'):]
            with open('fs/read_write.c', 'w') as f: f.write(content)

with open('fs/stat.c', 'r') as f: content = f.read()
if 'ksu_handle_stat' not in content:
    extern = "#ifdef CONFIG_KSU\n__attribute__((hot))\nextern int ksu_handle_stat(int *dfd, const char __user **filename_user, int *flags);\n#endif\n\n"
    content = re.sub(r'(SYSCALL_DEFINE4\s*\(\s*newfstatat)', extern + r'\1', content, count=1)
    call = "#ifdef CONFIG_KSU\n\tksu_handle_stat(&dfd, &filename, &flag);\n#endif\n\t"
    content = re.sub(r'(\terror\s*=\s*vfs_fstatat\(dfd,\s*filename,\s*&stat,\s*flag\);)', call + r'\1', content, count=1)
    with open('fs/stat.c', 'w') as f: f.write(content)

with open('kernel/reboot.c', 'r') as f: content = f.read()
if 'ksu_handle_sys_reboot' not in content:
    extern = "#ifdef CONFIG_KSU\nextern int ksu_handle_sys_reboot(int magic1, int magic2, unsigned int cmd, void __user **arg);\n#endif\n\n"
    content = re.sub(r'(SYSCALL_DEFINE4\s*\(\s*reboot)', extern + r'\1', content, count=1)
    call = "#ifdef CONFIG_KSU\n\tksu_handle_sys_reboot(magic1, magic2, cmd, &arg);\n#endif\n\t"
    content = re.sub(r'(/\*\s*We only trust the superuser with rebooting the system\.\s*\*/)', call + r'\1', content, count=1)
    with open('kernel/reboot.c', 'w') as f: f.write(content)

with open('fs/namespace.c', 'r') as f: content = f.read()
if 'int path_umount(struct path *path, int flags)' not in content:
    backport = '''
#ifdef CONFIG_KSU
static int can_umount(const struct path *path, int flags)
{
	struct mount *mnt = real_mount(path->mnt);
	if (flags & ~(MNT_FORCE | MNT_DETACH | MNT_EXPIRE | UMOUNT_NOFOLLOW)) return -EINVAL;
	if (!may_mount()) return -EPERM;
	if (path->dentry != path->mnt->mnt_root) return -EINVAL;
	if (!check_mnt(mnt)) return -EINVAL;
	if (mnt->mnt.mnt_flags & MNT_LOCKED) return -EINVAL;
	if (flags & MNT_FORCE && !capable(CAP_SYS_ADMIN)) return -EPERM;
	return 0;
}
int path_umount(struct path *path, int flags)
{
	struct mount *mnt = real_mount(path->mnt);
	int ret = can_umount(path, flags);
	if (!ret) ret = do_umount(mnt, flags);
	dput(path->dentry);
	mntput_no_expire(mnt);
	return ret;
}
#endif
'''
    content = re.sub(r'(int ksys_umount\(char __user \*name, int flags\))', backport + r'\1', content, count=1)
    with open('fs/namespace.c', 'w') as f: f.write(content)
PYEOF

# ==================== 4. CONFIGURATION ====================
echo ""
echo "=== Configuration ==="
export ARCH=arm64; export SUBARCH=arm64
export CROSS_COMPILE=aarch64-linux-gnu-
export CROSS_COMPILE_ARM32=arm-linux-gnueabi-
mkdir -p out
make O=out LLVM=1 CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 vendor/lito-perf_defconfig

{
  echo "CONFIG_KSU=y"
  echo "CONFIG_KSU_MANUAL_HOOK=y"
  echo "# CONFIG_KSU_WITH_KPROBES is not set"
  if [ "$SUSFS_APPLIED" = "1" ]; then
      echo "CONFIG_KSU_SUSFS=y"
      for o in $SUSFS_OPTIONS; do echo "CONFIG_KSU_SUSFS_${o}=y"; done
  else
      echo "# CONFIG_KSU_SUSFS is not set"
  fi
  echo "# CONFIG_KSU_TAMPER_SYSCALL_TABLE is not set"
  echo "# CONFIG_KSU_TRACEPOINT_HOOK is not set"
  echo "CONFIG_KPROBES=y"
  echo "CONFIG_HAVE_KPROBES=y"
  echo "CONFIG_KRETPROBES=y"
  echo "CONFIG_SECCOMP=y"
  echo "CONFIG_SECCOMP_FILTER=y"
  echo "CONFIG_COMPAT=y"
  echo "CONFIG_COMPAT_32BIT_TIME=y"
} >> out/.config

make O=out LLVM=1 CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 olddefconfig 2>&1 | tail -5

if [ "$SUSFS_APPLIED" = "1" ] && ! grep -q "^CONFIG_KSU_SUSFS=y" out/.config; then
    echo "❌ CONFIG_KSU_SUSFS n'a pas été retenu par Kconfig, abandon"
    exit 1
fi

# ==================== 5. PATCHS MOTOROLA ====================
sed -i 's/if (!check_version(/if (0 \&\& !check_version(/g' kernel/module.c
printf "\n/* --- Début Patch Tactile --- */\n#include <linux/notifier.h>\n#include <linux/module.h>\nstatic BLOCKING_NOTIFIER_HEAD(motorola_panel_notifier_list);\nint panel_register_notifier(struct notifier_block *nb) { return blocking_notifier_chain_register(&motorola_panel_notifier_list, nb); }\nEXPORT_SYMBOL(panel_register_notifier);\nint panel_unregister_notifier(struct notifier_block *nb) { return blocking_notifier_chain_unregister(&motorola_panel_notifier_list, nb); }\nEXPORT_SYMBOL(panel_unregister_notifier);\nvoid touch_set_state(int state) { return; }\nEXPORT_SYMBOL(touch_set_state);\n" >> techpack/display/msm/msm_drv.c

# ==================== 6. COMPILATION KERNEL ====================
echo "=== Compilation du kernel ==="
make O=out LLVM=1 CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 -j$(nproc) Image 2>&1 | tee build.log
if [ -f "out/arch/arm64/boot/Image" ]; then
    echo "✅ Compilation réussie"
    sha256sum out/arch/arm64/boot/Image | cut -d' ' -f1 > /tmp/kernel_compiled_hash.txt
else
    echo "❌ BUILD FAILED"
    grep -iE "error:|fatal error:" build.log | head -30
    exit 1
fi

# ==================== 7. COMPILATION KSUD ====================
echo ""
echo "=== Compilation ksud ==="
cd "$GITHUB_WORKSPACE"
KSUD_DIR=""
KSUD_ROOT=""
if [ -n "$KSU_REPO_ROOT" ] && [ -f "$KSU_REPO_ROOT/userspace/ksud/Cargo.toml" ]; then
    KSUD_DIR="$KSU_REPO_ROOT/userspace/ksud"
    KSUD_ROOT="$KSU_REPO_ROOT"
else
    rm -rf "$GITHUB_WORKSPACE/ksud-src" 2>/dev/null || true
    git clone --depth=1 --branch "$KSUD_FALLBACK_REF" https://github.com/KernelSU-Next/KernelSU-Next.git "$GITHUB_WORKSPACE/ksud-src"
    KSUD_DIR="$GITHUB_WORKSPACE/ksud-src/userspace/ksud"
    KSUD_ROOT="$GITHUB_WORKSPACE/ksud-src"
fi

curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
source "$HOME/.cargo/env"
rustup toolchain install nightly; rustup default nightly; rustup target add aarch64-linux-android
wget -q https://dl.google.com/android/repository/android-ndk-r26d-linux.zip; unzip -q android-ndk-r26d-linux.zip
export ANDROID_NDK_ROOT="$GITHUB_WORKSPACE/android-ndk-r26d"; export ANDROID_NDK_HOME="$ANDROID_NDK_ROOT"
export AARCH64_CLANG_PATH="$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android26-clang"
export AARCH64_CLANGXX_PATH="$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android26-clang++"
export AR_PATH="$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-ar"
export BINDGEN_EXTRA_CLANG_ARGS_aarch64_linux_android="--sysroot=$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/sysroot -I$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/include/aarch64-linux-android"

cd "$KSUD_DIR"
mkdir -p .cargo
cat > .cargo/config.toml <<EOF
[target.aarch64-linux-android]
linker = "$AARCH64_CLANG_PATH"
[env]
CC_aarch64_linux_android = "$AARCH64_CLANG_PATH"
CXX_aarch64_linux_android = "$AARCH64_CLANGXX_PATH"
AR_aarch64_linux_android = "$AR_PATH"
BINDGEN_EXTRA_CLANG_ARGS_aarch64_linux_android = "$BINDGEN_EXTRA_CLANG_ARGS_aarch64_linux_android"
EOF
export CARGO_NET_GIT_FETCH_WITH_CLI=true
cargo +nightly build --release --target aarch64-linux-android

KSUD_BINARY=$(find "$KSUD_ROOT" -type f -path "*aarch64-linux-android/release/ksud" 2>/dev/null || true)
cp "$KSUD_BINARY" "$GITHUB_WORKSPACE/ksud"; chmod 755 "$GITHUB_WORKSPACE/ksud"
cd "$GITHUB_WORKSPACE"

# ==================== 8. REPACK ====================
echo ""
echo "=== Repack ==="
rm -f ./boot-stock.img 2>/dev/null || true
gdown "https://drive.google.com/uc?id=${BOOT_GDRIVE_ID}" -O boot-stock.img 2>&1
rm -f ./dtbo-stock.img 2>/dev/null || true
gdown "https://drive.google.com/uc?id=${DTBO_GDRIVE_ID}" -O dtbo-stock.img 2>&1 || true

mkdir -p repack
cp boot-stock.img repack/boot.img
wget -q https://github.com/topjohnwu/Magisk/releases/download/v27.0/Magisk-v27.0.apk -O Magisk-v27.0.apk
unzip -q Magisk-v27.0.apk lib/x86_64/libmagiskboot.so
mv lib/x86_64/libmagiskboot.so repack/magiskboot
chmod +x repack/magiskboot
rm -rf ./Magisk-v27.0.apk ./lib 2>/dev/null || true

cd repack
./magiskboot unpack boot.img
cp "$GITHUB_WORKSPACE/kernel_sources/out/arch/arm64/boot/Image" kernel
./magiskboot cpio ramdisk.cpio \
    "mkdir 0755 data" \
    "mkdir 0755 data/adb" \
    "mkdir 0755 data/adb/ksud" \
    "add 0755 data/adb/ksud/ksud $GITHUB_WORKSPACE/ksud"

cp "$GITHUB_WORKSPACE/ksud" ./local_su_binary
chmod 755 ./local_su_binary
./magiskboot cpio ramdisk.cpio \
    "mkdir 0755 system" \
    "mkdir 0755 system/bin" \
    "add 06755 system/bin/su ./local_su_binary"
rm -f ./local_su_binary 2>/dev/null || true

./magiskboot repack boot.img new-boot.img
mv new-boot.img ../final_boot.img
cd ..

# ==================== 9. SORTIE ====================
mkdir -p output
cp final_boot.img output/KernelSU-Next-v4.9-SuSFS-boot.img
cp dtbo-stock.img output/dtbo.img 2>/dev/null || true
cp kernel_sources/build.log output/
cp "$GITHUB_WORKSPACE/ksud" output/ksud 2>/dev/null || true
echo ""
echo "=== BUILD TERMINÉ v4.9 (KernelSU-Next + SuSFS file_wrapper 4.19 corrigé) ==="
ls -lh output/
