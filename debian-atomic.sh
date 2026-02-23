#!/bin/bash
# ==============================================================================
# 🚀 DEBIAN ATOMIC "FORTRESS" INSTALLER (A/B, UKI, MOK, HOMED, ZRAM)
# ==============================================================================
set -euo pipefail

DISK="/dev/nvme0n1" # Ajustar según tu hardware
HOSTNAME="debian-atomic"
DEBIAN_VERSION="testing"
FSFLAGS="compress=zstd:3,noatime,autodefrag"

echo "🛡️ Iniciando construcción de la arquitectura atómica..."

# 1. PARTICIONADO DINÁMICO (systemd-repart)
mkdir -p repart.d
cat <<EOF > repart.d/01_efi.conf
[Partition]
Type=esp
SizeMinBytes=1G
Format=vfat
EOF

cat <<EOF > repart.d/02_root_a.conf
[Partition]
Type=root
Label=Debian_A
SizeMinBytes=15G
Format=btrfs
EOF

cat <<EOF > repart.d/03_root_b.conf
[Partition]
Type=root
Label=Debian_B
SizeMinBytes=15G
Format=btrfs
EOF

cat <<EOF > repart.d/04_persistence.conf
[Partition]
Type=linux-generic
Label=Persistence
Format=btrfs
EOF

systemd-repart --sector-size=512 --empty=allow --definitions=repart.d --dry-run=no $DISK

# Identificar particiones
EFI_PART=$(lsblk -no PATH $DISK | sed -n '2p')
ROOT_A=$(lsblk -no PATH $DISK | sed -n '3p')
PERSIST_PART=$(lsblk -no PATH $DISK | sed -n '5p')

# 2. SUBVOLÚMENES Y PERSISTENCIA
mount $ROOT_A /mnt && btrfs subvolume create /mnt/@ && umount /mnt
mount $PERSIST_PART /mnt
btrfs subvolume create /mnt/@etc
btrfs subvolume create /mnt/@var
btrfs subvolume create /mnt/@home
umount /mnt

# 3. DESPLIEGUE BASE (Bootstrap)
TARGET="/target"
mkdir -p $TARGET
mount -o $FSFLAGS,subvol=@ $ROOT_A $TARGET
debootstrap $DEBIAN_VERSION $TARGET http://deb.debian.org/debian

# Montajes persistentes
mount -o $FSFLAGS,subvol=@etc $PERSIST_PART $TARGET/etc
mount -o $FSFLAGS,subvol=@var $PERSIST_PART $TARGET/var
mount -o $FSFLAGS,subvol=@home $PERSIST_PART $TARGET/home

# 4. INSTALACIÓN DE PAQUETES NATIVOS (Solo Wayland, Sin X11)
mount -t proc none $TARGET/proc
mount --rbind /sys $TARGET/sys
mount --rbind /dev $TARGET/dev
mount --rbind /run $TARGET/run

# Dentro del chroot $TARGET antes del apt update:
chroot $TARGET /bin/bash <<EOF
  # 1. Instalar dependencias para añadir repositorios
  apt update
  apt install -y curl ca-certificates gnupg

  # 2. Añadir la llave GPG de Waydroid
  curl -fsSL https://repo.waydroid.net/waydroid.gpg > /usr/share/keyrings/waydroid.gpg

  # 3. Añadir el repositorio oficial (usando trixie/sid)
  echo "deb [signed-by=/usr/share/keyrings/waydroid.gpg] https://repo.waydroid.net/ $(lsb_release -sc) main" > /etc/apt/sources.list.d/waydroid.list

  # 4. Ahora sí, instalar todo
  export DEBIAN_FRONTEND=noninteractive

  # 1. EL NÚCLEO (Sin esto no hay nada)
  # Instalamos el kernel y los headers para que Waydroid/Drivers funcionen
  apt update
  apt install -y linux-image-amd64 linux-headers-amd64

  # 2. SOPORTE DE HARDWARE (Firmware crítico)
  # Metemos los blobs necesarios para que cargue el WiFi, la GPU y la CPU
  apt install -y --no-install-recommends \
    intel-microcode amd64-microcode \
    firmware-linux-nonfree firmware-misc-nonfree \
    firmware-realtek firmware-iwlwifi firmware-amd-graphics \
    mesa-vulkan-drivers mesa-va-drivers

  # 3. INFRAESTRUCTURA ATÓMICA Y SEGURIDAD
  # Herramientas para UKI, Btrfs y gestión de energía/swap
  apt install -y \
    systemd-boot systemd-ukify sbsigntool \
    dracut btrfs-progs systemd-zram-generator \
    systemd-homed cryptsetup tpm2-tools

  # 4. ENTORNO PLASMA 6 (Wayland puro)
  # Instalamos lo mínimo para que arranque el escritorio sin meter basura de X11
  apt install -y --no-install-recommends \
    plasma-workspace-wayland kwin-wayland plasma-desktop \
    xdg-desktop-portal-kde pipewire-audio pipewire-alsa \
    dolphin konsole qt6-wayland network-manager plasma-nm

  # 5. CONTENEDORES Y ANDROID
  # (Asumiendo que el repo de Waydroid se añadió antes)
  apt install -y podman distrobox waydroid flatpak
EOF

# 5. SEGURIDAD FÍSICA: LLAVES MOK Y SECURE BOOT
mkdir -p $TARGET/etc/kernel/mok
openssl req -new -x509 -newkey rsa:2048 -nodes -days 3650 \
    -subj "/CN=Debian Atomic MOK/" \
    -keyout $TARGET/etc/kernel/mok/mok.key \
    -out $TARGET/etc/kernel/mok/mok.crt

# 5.1 Registrar la llave en la NVRAM para Secure Boot
echo "-------------------------------------------------------"
echo " CONFIGURANDO CONTRASEÑA MOK (NECESARIA AL REINICIAR)"
echo "-------------------------------------------------------"
# Convertimos el crt a formato DER (que es el que prefiere mokutil/shim)
openssl x509 -in $TARGET/etc/kernel/mok/mok.crt -out $TARGET/etc/kernel/mok/mok.der -outform DER

# Lanzamos el import (Te pedirá la clave por consola)
chroot $TARGET mokutil --import /etc/kernel/mok/mok.der

# 6. SWAP CIFRADO ALEATORIO (Efímero)
chroot $TARGET bash -c "
  truncate -s 0 /var/swapfile
  chattr +C /var/swapfile
  fallocate -l 4G /var/swapfile
  chmod 600 /var/swapfile
  mkswap /var/swapfile
"
cat <<EOF > $TARGET/etc/crypttab
swap_crypt /var/swapfile /dev/urandom swap,cipher=aes-xts-plain64,size=256
EOF

# 7. CONFIGURACIÓN ZRAM Y KERNEL
cat <<EOF > $TARGET/etc/systemd/zram-generator.conf
[zram0]
zram-size = min(ram / 2, 8192)
compression-algorithm = zstd
swap-priority = 100
EOF

cat <<EOF > $TARGET/etc/sysctl.d/99-atomic-opts.conf
vm.swappiness = 180
vm.page-cluster = 0
EOF

# 8. GENERACIÓN DEL UKI (Unified Kernel Image) FIRMADO
CMDLINE="rw quiet splash root=$ROOT_A rootflags=subvol=@ psi=1 preempt=full binder.devices=binder,vndbinder,hwbinder devtmpfs.mount=1"
# Dentro del chroot, antes de generar el UKI:
echo 'add_dracutmodules+=" systemd btrfs "' > /etc/dracut.conf.d/10-atomic.conf

mkdir -p $TARGET/boot/efi
mount $EFI_PART $TARGET/boot/efi
chroot $TARGET bootctl install --esp-path=/boot/efi

chroot $TARGET /usr/lib/systemd/systemd-ukify build \
    --linux=/boot/vmlinuz* --initrd=/boot/initrd.img* \
    --cmdline="$CMDLINE" \
    --secureboot-private-key=/etc/kernel/mok/mok.key \
    --secureboot-certificate=/etc/kernel/mok/mok.crt \
    --output=/boot/efi/EFI/Linux/debian-root_a.efi

# 9. FSTAB (Solo lectura para la raíz)
cat <<EOF > $TARGET/etc/fstab
LABEL=Debian_A / btrfs ro,subvol=@,$FSFLAGS 0 1
$PERSIST_PART /etc btrfs rw,subvol=@etc,$FSFLAGS 0 0
$PERSIST_PART /var btrfs rw,subvol=@var,$FSFLAGS 0 0
$PERSIST_PART /home btrfs rw,subvol=@home,$FSFLAGS 0 0
$EFI_PART /boot/efi vfat defaults 0 2
/dev/mapper/swap_crypt none swap defaults,pri=10 0 0
EOF

# 10. CONFIGURACIÓN DE HOMED (Expulsión de llave)
cat <<EOF > $TARGET/etc/systemd/homed.conf
[Home]
SuspendMode=suspend
EOF

# 11. SCRIPT DE CONTROL ATÓMICO (Gestión A/B)
# [Insertar aquí el script atomic-control detallado anteriormente]

cat <<EOF > $TARGET/usr/local/bin/atomic-control
#!/bin/bash
# atomic-control: Interfaz para gestionar el sistema inmutable

set -e

# 1. Identificar slots
CURRENT_ROOT=$(findmnt -n -o SOURCE / | cut -d'[' -f2 | tr -d ']')
[[ "$CURRENT_ROOT" == "@root_a" ]] && NEXT_ROOT="@root_b" || NEXT_ROOT="@root_a"
NEXT_PART=$(lsblk -no PATH -L "Debian_$(echo $NEXT_ROOT | cut -d'_' -f2 | tr '[:lower:]' '[:upper:]')")

usage() {
    echo "Uso: atomic-control [upgrade | install <paquete> | rollback]"
    exit 1
}

if [[ $# -lt 1 ]]; then usage; fi

case $1 in
    upgrade|install)
        ACTION=$1
        PKG=$2

        echo "🛠️ Preparando mutación en $NEXT_ROOT..."

        # Montar el slot inactivo
        mkdir -p /mnt/next
        mount $NEXT_PART /mnt/next

        # Sincronizar el estado actual al siguiente (Clonación rápida Btrfs)
        btrfs subvolume delete /mnt/next/@ 2>/dev/null || true
        btrfs subvolume snapshot / /mnt/next/@
        btrfs property set -ts /mnt/next/@ ro false

        echo "📦 Ejecutando cambios..."
        if [[ "$ACTION" == "upgrade" ]]; then
            CMD="apt update && apt full-upgrade -y"
        else
            CMD="apt update && apt install -y $PKG"
        fi

        # Ejecutar en el contenedor
        systemd-nspawn -D /mnt/next/@ --bind=/etc --bind=/var --bind=/boot/efi /bin/bash -c "$CMD && apt autoremove -y"

        # Re-generar UKI
        echo "🔐 Sellando nueva imagen y generando UKI..."
        chroot /mnt/next/@ /usr/lib/systemd/systemd-ukify build \
            --linux=/boot/vmlinuz* \
            --initrd=/boot/initrd.img* \
            --cmdline="rw quiet splash root=$NEXT_PART rootflags=subvol=@ psi=1" \
            --output="/boot/efi/EFI/Linux/debian-$(echo $NEXT_ROOT).efi"

        btrfs property set -ts /mnt/next/@ ro true
        umount /mnt/next

        echo "✨ Éxito. Reinicia para aplicar los cambios en $NEXT_ROOT."
        ;;

    rollback)
        echo "⏪ Cambiando el UKI por defecto al slot anterior..."
        # Aquí simplemente podrías usar bootctl para cambiar el default
        echo "Usa 'bootctl set-default debian-$(echo $NEXT_ROOT).efi' para volver atrás."
        ;;
    *)
        usage
        ;;
esac
EOF
chmod +x $TARGET/usr/local/bin/atomic-control

echo "✅ Instalación finalizada. Reinicia y enrola el MOK en la pantalla azul."
