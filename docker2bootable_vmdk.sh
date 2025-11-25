#!/bin/bash

# 将Docker镜像转换为可启动的VMDK虚拟机
# Docker镜像的内容会直接成为虚拟机的文件系统
# 使用方法: ./docker2bootable_vmdk.sh <镜像名称>:<标签> [输出VMDK名称] [磁盘大小GB]
# 或: ./docker2bootable_vmdk.sh <已导出的tar文件> [输出VMDK名称] [磁盘大小GB]

set -e

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 检查参数
if [ $# -lt 1 ]; then
    echo -e "${RED}错误: 请提供Docker镜像名称或tar文件路径${NC}"
    echo ""
    echo "使用方法:"
    echo "  $0 <镜像名称>:<标签> [输出VMDK名称] [磁盘大小GB]"
    echo "  $0 <docker_image.tar> [输出VMDK名称] [磁盘大小GB]"
    echo ""
    echo "示例:"
    echo "  $0 ar9481:v2 ar9481_v2.vmdk 30"
    echo "  $0 ar9481_v2.tar ar9481_v2.vmdk 30"
    echo ""
    echo "注意: 需要安装 qemu-utils, Docker"
    exit 1
fi

INPUT="$1"
OUTPUT_VMDK="${2:-}"
DISK_SIZE_GB="${3:-30}"

# 检查必需工具
if ! command -v qemu-img > /dev/null 2>&1; then
    echo -e "${RED}错误: 未安装 qemu-img 工具${NC}"
    echo "安装: sudo apt-get install qemu-utils"
    exit 1
fi

if ! command -v docker > /dev/null 2>&1; then
    echo -e "${RED}错误: 未安装 Docker${NC}"
    echo "安装: curl -fsSL https://get.docker.com | sh"
    exit 1
fi

# 创建临时工作目录
WORK_DIR=$(mktemp -d -t docker2bootable.XXXXXX)
echo -e "${GREEN}工作目录: ${WORK_DIR}${NC}"

# 清理函数
cleanup() {
    echo -e "${YELLOW}清理临时文件...${NC}"
    if [ -n "$CONTAINER_ID" ]; then
        docker rm -f "$CONTAINER_ID" 2>/dev/null || true
    fi
    if [ -n "$LOOP_DEV" ] && [ -e "$LOOP_DEV" ]; then
        if mountpoint -q "$MOUNT_POINT" 2>/dev/null; then
            sudo umount "$MOUNT_POINT" 2>/dev/null || true
        fi
        sudo losetup -d "$LOOP_DEV" 2>/dev/null || true
    fi
    if [ -d "$WORK_DIR" ]; then
        sudo rm -rf "$WORK_DIR"
    fi
}
trap cleanup EXIT

# 处理输入
if [[ "$INPUT" == *":"* ]] || ([[ "$INPUT" != *".tar"* ]] && [[ ! -f "$INPUT" ]]); then
    # 是镜像名称
    IMAGE_NAME="$INPUT"
    
    if ! docker images --format "{{.Repository}}:{{.Tag}}" | grep -q "^${IMAGE_NAME}$"; then
        echo -e "${RED}错误: Docker镜像不存在: ${IMAGE_NAME}${NC}"
        exit 1
    fi
    
    SAFE_NAME=$(echo "$IMAGE_NAME" | tr '/:' '_')
    if [ -z "$OUTPUT_VMDK" ]; then
        OUTPUT_VMDK="${SAFE_NAME}.vmdk"
    fi
    
    echo -e "${GREEN}═══════════════════════════════════════${NC}"
    echo -e "${GREEN}  Docker镜像转可启动VMDK${NC}"
    echo -e "${GREEN}═══════════════════════════════════════${NC}"
    echo -e "${BLUE}镜像名称: ${IMAGE_NAME}${NC}"
    echo -e "${BLUE}输出文件: ${OUTPUT_VMDK}${NC}"
    echo -e "${BLUE}磁盘大小: ${DISK_SIZE_GB}GB${NC}"
    echo ""
    
    # 步骤1: 运行容器并导出文件系统
    echo -e "${YELLOW}步骤1: 从Docker镜像提取文件系统...${NC}"
    
    # 创建临时容器
    CONTAINER_ID=$(docker create "$IMAGE_NAME" /bin/sh)
    echo -e "${GREEN}✓ 容器创建成功: ${CONTAINER_ID:0:12}${NC}"
    
    # 导出容器文件系统
    EXTRACT_DIR="${WORK_DIR}/rootfs"
    mkdir -p "$EXTRACT_DIR"
    docker export "$CONTAINER_ID" | sudo tar -xC "$EXTRACT_DIR"
    docker rm "$CONTAINER_ID"
    CONTAINER_ID=""
    
    echo -e "${GREEN}✓ 文件系统提取完成${NC}"
    
elif [ -f "$INPUT" ]; then
    # 是tar文件
    TAR_FILE="$INPUT"
    
    if [ -z "$OUTPUT_VMDK" ]; then
        OUTPUT_VMDK="$(basename "$TAR_FILE" .tar).vmdk"
    fi
    
    echo -e "${GREEN}═══════════════════════════════════════${NC}"
    echo -e "${GREEN}  Docker镜像tar转可启动VMDK${NC}"
    echo -e "${GREEN}═══════════════════════════════════════${NC}"
    echo -e "${BLUE}输入文件: ${TAR_FILE}${NC}"
    echo -e "${BLUE}输出文件: ${OUTPUT_VMDK}${NC}"
    echo -e "${BLUE}磁盘大小: ${DISK_SIZE_GB}GB${NC}"
    echo ""
    
    # 步骤1: 从tar文件加载镜像并提取文件系统
    echo -e "${YELLOW}步骤1: 从tar文件提取文件系统...${NC}"
    
    # 加载镜像
    LOADED_IMAGE=$(docker load -i "$TAR_FILE" | grep "Loaded image" | awk '{print $3}' || docker load -i "$TAR_FILE" | tail -1 | awk '{print $NF}')
    
    if [ -z "$LOADED_IMAGE" ]; then
        # 尝试另一种方式
        LOADED_IMAGE=$(docker load -i "$TAR_FILE" 2>&1 | grep -E "Loaded|Loading" | tail -1 | sed 's/.*: //' || echo "")
    fi
    
    if [ -z "$LOADED_IMAGE" ]; then
        echo -e "${YELLOW}无法自动检测镜像名称，使用临时名称...${NC}"
        LOADED_IMAGE="temp_image:latest"
        docker tag $(docker images -q | head -1) "$LOADED_IMAGE" 2>/dev/null || true
    fi
    
    echo -e "${GREEN}✓ 镜像加载: ${LOADED_IMAGE}${NC}"
    
    # 创建临时容器并导出
    CONTAINER_ID=$(docker create "$LOADED_IMAGE" /bin/sh)
    EXTRACT_DIR="${WORK_DIR}/rootfs"
    mkdir -p "$EXTRACT_DIR"
    docker export "$CONTAINER_ID" | sudo tar -xC "$EXTRACT_DIR"
    docker rm "$CONTAINER_ID"
    CONTAINER_ID=""
    
    echo -e "${GREEN}✓ 文件系统提取完成${NC}"
else
    echo -e "${RED}错误: 输入无效${NC}"
    exit 1
fi

# 步骤2: 创建虚拟磁盘
echo -e "${YELLOW}步骤2: 创建虚拟磁盘 (${DISK_SIZE_GB}GB)...${NC}"
RAW_DISK="${WORK_DIR}/disk.raw"
qemu-img create -f raw "$RAW_DISK" "${DISK_SIZE_GB}G"
echo -e "${GREEN}✓ 磁盘创建成功${NC}"

# 步骤3: 创建分区和文件系统
echo -e "${YELLOW}步骤3: 创建分区和文件系统...${NC}"
LOOP_DEV=$(sudo losetup -f)
sudo losetup "$LOOP_DEV" "$RAW_DISK"

if command -v parted > /dev/null 2>&1; then
    sudo parted -s "$LOOP_DEV" mklabel msdos
    sudo parted -s "$LOOP_DEV" mkpart primary ext4 1MiB 100%
    sudo partprobe "$LOOP_DEV"
    sleep 2
    PART_DEV="${LOOP_DEV}p1"
    [ ! -e "$PART_DEV" ] && PART_DEV="${LOOP_DEV}1"
    sudo mkfs.ext4 -F -L "docker-root" "$PART_DEV"
    MOUNT_POINT="${WORK_DIR}/mount"
    mkdir -p "$MOUNT_POINT"
    sudo mount "$PART_DEV" "$MOUNT_POINT"
else
    sudo mkfs.ext4 -F -L "docker-root" "$LOOP_DEV"
    MOUNT_POINT="${WORK_DIR}/mount"
    mkdir -p "$MOUNT_POINT"
    sudo mount "$LOOP_DEV" "$MOUNT_POINT"
fi

echo -e "${GREEN}✓ 文件系统创建成功${NC}"

# 步骤4: 复制文件系统到虚拟磁盘
echo -e "${YELLOW}步骤4: 复制文件系统到虚拟磁盘（这可能需要一些时间）...${NC}"

# 使用rsync或cp复制
if command -v rsync > /dev/null 2>&1; then
    sudo rsync -aAXv "$EXTRACT_DIR/" "$MOUNT_POINT/"
else
    sudo cp -a "$EXTRACT_DIR"/* "$MOUNT_POINT/" 2>/dev/null || true
    sudo cp -a "$EXTRACT_DIR"/.[^.]* "$MOUNT_POINT/" 2>/dev/null || true
fi

# 创建必要的目录
sudo mkdir -p "$MOUNT_POINT"/{dev,proc,sys,tmp,run,mnt,media}
sudo chmod 1777 "$MOUNT_POINT/tmp"

echo -e "${GREEN}✓ 文件系统复制完成${NC}"

# 步骤5: 配置系统启动
echo -e "${YELLOW}步骤5: 配置系统启动...${NC}"

# 创建fstab
sudo tee "$MOUNT_POINT/etc/fstab" > /dev/null << 'FSTAB_EOF'
# /etc/fstab: static file system information
#
# <file system> <mount point>   <type>  <options>       <dump>  <pass>
proc            /proc           proc    defaults          0       0
sysfs           /sys            sysfs   defaults          0       0
devtmpfs        /dev            devtmpfs defaults         0       0
tmpfs           /tmp            tmpfs   defaults          0       0
FSTAB_EOF

# 创建inittab或systemd配置（如果存在）
if [ -d "$MOUNT_POINT/etc/systemd" ]; then
    # systemd系统
    sudo mkdir -p "$MOUNT_POINT/etc/systemd/system/getty.target.wants"
    sudo tee "$MOUNT_POINT/etc/systemd/system/getty@tty1.service" > /dev/null << 'GETTY_EOF'
[Unit]
Description=Getty on tty1
After=systemd-user-sessions.service

[Service]
ExecStart=/sbin/agetty --autologin root --noclear %I $TERM
Type=idle

[Install]
WantedBy=multi-user.target
GETTY_EOF
    sudo ln -sf /etc/systemd/system/getty@tty1.service "$MOUNT_POINT/etc/systemd/system/getty.target.wants/getty@tty1.service" 2>/dev/null || true
fi

# 创建启动脚本
sudo tee "$MOUNT_POINT/etc/profile.d/docker-vm.sh" > /dev/null << 'PROFILE_EOF'
#!/bin/bash
# Docker虚拟机欢迎信息

echo ""
echo "=========================================="
echo "Docker虚拟机已启动"
echo "=========================================="
echo ""
echo "这是一个从Docker镜像创建的可启动虚拟机"
echo "所有Docker镜像中的内容都可以直接使用"
echo ""
echo "当前目录: $(pwd)"
echo "系统信息:"
uname -a 2>/dev/null || echo "无法获取系统信息"
echo ""
PROFILE_EOF

sudo chmod +x "$MOUNT_POINT/etc/profile.d/docker-vm.sh"

# 创建.bashrc或.profile
if [ ! -f "$MOUNT_POINT/root/.bashrc" ]; then
    sudo tee "$MOUNT_POINT/root/.bashrc" > /dev/null << 'BASHRC_EOF'
# ~/.bashrc
[ -f /etc/profile.d/docker-vm.sh ] && source /etc/profile.d/docker-vm.sh
BASHRC_EOF
fi

# 卸载
sudo umount "$MOUNT_POINT"
sudo losetup -d "$LOOP_DEV"

# 步骤6: 转换为VMDK
echo -e "${YELLOW}步骤6: 转换为VMDK格式...${NC}"
if qemu-img convert -f raw -O vmdk "$RAW_DISK" "$OUTPUT_VMDK"; then
    VMDK_SIZE=$(du -h "$OUTPUT_VMDK" | cut -f1)
    echo -e "${GREEN}✓ VMDK转换成功: ${VMDK_SIZE}${NC}"
else
    echo -e "${RED}✗ VMDK转换失败${NC}"
    exit 1
fi

# 显示结果
echo ""
echo -e "${GREEN}═══════════════════════════════════════${NC}"
echo -e "${GREEN}  ✓ 创建完成!${NC}"
echo -e "${GREEN}═══════════════════════════════════════${NC}"
echo -e "${BLUE}VMDK文件: ${OUTPUT_VMDK}${NC}"
echo -e "${BLUE}文件大小: ${VMDK_SIZE}${NC}"
echo ""
echo -e "${YELLOW}在VMware中使用:${NC}"
echo "1. 打开VMware Workstation/Player"
echo "2. 创建新虚拟机"
echo "3. 选择'使用现有虚拟磁盘'"
echo "4. 选择VMDK文件: ${OUTPUT_VMDK}"
echo "5. 启动虚拟机即可直接使用！"
echo ""
echo -e "${BLUE}注意: 这是一个完整的可启动系统，包含Docker镜像的所有内容${NC}"
echo -e "${BLUE}用户可以直接使用，就像使用一台普通的主机一样${NC}"
