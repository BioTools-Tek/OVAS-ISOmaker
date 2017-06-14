#!/bin/bash
#

command=$1
[ "$command" = "" ] && echo -e "\n\t`basename $0` (install|update)\n" && exit -1


trap "kill 0" SIGINT  # kill all subprocesses

customiso=./customiso/
chroot=$customiso/arch/x86_64/squashfs-root/
vanilla_iso=./arch*.iso

chroot_cmd="sudo arch-chroot $chroot"

iso_label=OVAS_201706  # don't change this


function download_if_empty {

    if ! [ -e $vanilla_iso ]; then   
        if ! [ -e $chroot/etc/mkinitcpio.conf ] ; then
            # manual download till I can get the globbing to work
            wget http://mirror.23media.de/archlinux/iso/latest/archlinux-2017.06.01-x86_64.iso
            vanilla_iso=./*.iso
        fi
    fi
}


function init_mount_unpack {

    echo ""
    if [ "`mount | grep /mnt/archiso | wc -l`" = "0" ]; then
        echo "[Mounting iso]"
        sudo mkdir /mnt/archiso
        sudo mount -t iso9660 -o loop $vanilla_iso /mnt/archiso
        
    else
        echo "[Already mounted]"
    fi

    sleep 2
    echo ""

    if ! [ -e $chroot/etc/mkinitcpio.conf ]; then
        echo ""
        echo "[Copying contents]"        
        sudo cp -unpr /mnt/archiso $customiso
        sleep 1

        echo ""
        echo "[Unsquashing FS]"
        cd $customiso/arch/x86_64/
        sudo unsquashfs airootfs.sfs
        cd -

        sleep 1
        echo ""
        echo "[Running chroot commands]"
        sleep 1

        $chroot_cmd pacman-key --init
        $chroot_cmd pacman-key --populate archlinux
        $chroot_cmd pacman -Syu --force archiso linux --noconfirm
        sleep 1
        echo ""
        echo "[Replacing HOOKS]"
        $chroot_cmd sed -ibak 's/^HOOKS=.*$/HOOKS=\"base udev memdisk archiso_shutdown archiso archiso_loop_mnt archiso_pxe_common archiso_pxe_nbd archiso_pxe_http archiso_pxe_nfs archiso_kms block pcmcia filesystems keyboard\"/' /etc/mkinitcpio.conf       
        #$chroot_cmd "LANG=C pacman -Sl | awk '/\[installed\]$/ {print $1 \"/\" $2 \"-\" $3}' > /pkglist.txt;"
    else
        echo "[Already populated]"
    fi
}


function updateBootOpts {
    $chroot_cmd mkinitcpio -p linux
    $chroot_cmd pacman -Scc --noconfirm

    sleep 1
    echo ""
    echo "[Copying over boot images]"

    sudo cp $chroot/boot/vmlinuz-linux $customiso/arch/x86_64/vmlinuz
    sudo cp $chroot/boot/initramfs-linux.img $customiso/arch/x86_64/archiso.img

    sleep 1
    echo ""
}


function updateSquash {
    algo=${1:xz}

    backup_root=./backup_root

    #if ! [ -e $customiso/arch/x86_64/squashfs-root/ ];then
    #    echo " - squashfs-root does not exist"
    #    if [ -e $backup_root ]; then
    #        echo " - Moving backup into place"
    #        sudo mv -v $backup_root $customiso/arch/x86_64/squashfs-root/
    #    else
    #        echo " - Nothing to squash, terminating"
    #        exit -1
    #    fi
    #fi
    
    echo ""
    echo "[Updating Squash image ($algo)]"
    cd $customiso/arch/x86_64/
   
    sudo rm airootfs.sfs
    sudo mksquashfs squashfs-root airootfs.sfs -comp $algo
    sudo sh -c "md5sum airootfs.sfs > airootfs.md5"

    cd -
    echo ""
}



function copy_static_files {
    echo ""
    echo "[Updating Static Files]"
    static_dir=static_confs/

    sudo rsync -av $static_dir/* $chroot
    
    #resolve_links.cmd
    echo "[Resolving symlinks for stated directories]"
    for dir in `find $static_dir -name resolve_links.cmd -exec dirname {} \;`; do
        #echo "$dir"
        #continue
        # Remove symlinks (if any)
        nodd=$chroot/`echo $dir | sed "s|$static_dir||"`
        echo " - Cleaning $nodd of symlinks"
        symedfiles=`sudo find $nodd/ -maxdepth 1  -type l`

        echo " - Copying over real files"
        for file in $symedfiles; do
            actualpath=$(readlink -f $file)
            rsync -avP $actualpath $nodd/
        done
    done
}

function set_starts {
    echo ""
    echo "[Setting systemctl starts]"
    $chroot_cmd systemctl enable sshd         # enable internally for debugging
    $chroot_cmd systemctl enable httpd

    $chroot_cmd systemctl enable  dhcpcd       # slow, enable on demand
    $chroot_cmd systemctl disable pacman-init  # not needed for one time use
    
}

function set_permissions {
    echo "[Setting Accounts and Permissions]"
    echo " - Creating accounts"
    $chroot_cmd useradd http
    $chroot_cmd usermod -d /home/http/ http
    $chroot_cmd usermod -a -G http http
    $chroot_cmd usermod -a -G wheel http

    echo " - Setting passwords"
    $chroot_cmd sh -c "echo 'http:http' | chpasswd"
    $chroot_cmd sh -c "echo 'root:root' | chpasswd"

    echo " - Setting permissions"
    $chroot_cmd chown http:http /nomansland -R
    $chroot_cmd chown http:http /extra -R
    $chroot_cmd chown root:root /home/
    $chroot_cmd chown http:http /home/http/ -R
    $chroot_cmd chmod u+wrx /home/http/ -R
    $chroot_cmd chmod a+wrx /nomansland -R
    $chroot_cmd chmod a+wrx /extra -R    
    $chroot_cmd chown root:root /etc -R
    $chroot_cmd chmod u+wrx /nomansland -R

    echo " - Setting default shells"
    $chroot_cmd chsh -s /bin/bash http
    $chroot_cmd chsh -s /bin/bash root    
}

function install_packages {
    pack_list_in=package_list_install.txt
    #pack_list_rm=package_list_remove.txt
    #sudo cp -v ./assets/$pack_list_rm $chroot/$pack_list_rm
    sudo cp -v ./assets/$pack_list_in $chroot/$pack_list_in
    #xf86="`pacman -Ssq xf86`"
    #xorg="`pacman -Ssq xorg`"

    #sudo sh -c "echo $xf86 $xorg >> $chroot/$pack_list_in"

    $chroot_cmd sh -c "cat $pack_list_in | pacman -S --needed --noconfirm -"

    
    $chroot_cmd sh -c 'pacman -S --needed --noconfirm `pacman -Ssq xf86`'
    $chroot_cmd sh -c 'pacman -S --needed --noconfirm `pacman -Ssq xorg`'
    #$chroot_cmd sh -c "cat $pack_list_rm | pacman -R --noconfirm -"
}


function install_boot_opts {

    syslx_root=$customiso/arch/boot/syslinux
    
    echo "[Configuring Bootloader]"
    echo " - Setting splash"
    convert assets/splash.xcf -flatten /tmp/splash.png
    sudo cp -v /tmp/splash.png $syslx_root/
    
    echo " - Setting menu text"
    sudo sed -i 's/MENU TITLE .*/MENU TITLE Welcome to the OVAS pipeline/' $syslx_root/archiso_head.cfg
    sudo sh -c "echo \"\
INCLUDE boot/syslinux/archiso_head.cfg

LABEL arch64
TEXT HELP
Boots the OVAS live medium.
Provides a self-contained environment to perform variant analysis.
ENDTEXT
MENU LABEL Run OVAS
LINUX boot/x86_64/vmlinuz
INITRD boot/intel_ucode.img,boot/x86_64/archiso.img
APPEND archisobasedir=arch archisolabel=${iso_label} cow_spacesize=10G

LABEL poweroff
MENU LABEL Power Off
COM32 boot/syslinux/poweroff.c32

\" > $syslx_root/archiso_sys.cfg"
   
}


function createISO {
    back=./chroot_backup
    sudo mv -v $chroot $back   #  temporarily move chroot out of custom

    echo "[Creating ISO]"
    mkdir out
    output_iso=out/ovas-`date +%Y%m%d`.2.iso
    [ -e $output_iso ] && rm $output_iso

    [ "$output_iso" = "" ] && echo "No iso filename given!" && exit -1
    
    make_xoriso $output_iso # OR
    #make_geniso $output_iso

    # move chroot back
    sleep 1
    sudo mv -v $back $chroot
}



function make_xoriso {
    output_iso=$1
    isolinux=`readlink -f $customiso/isolinux`
    
    sudo xorriso\
	 -as mkisofs -iso-level 3 -full-iso9660-filenames\
         -volid "${iso_label}"\
	 -eltorito-boot isolinux/isolinux.bin -eltorito-catalog isolinux/boot.cat\
	 -no-emul-boot -boot-load-size 4 -boot-info-table\
         -isohybrid-mbr $isolinux/isohdpfx.bin\
         -output $output_iso $customiso
}

function make_geniso {
    output_iso=$1

    sudo genisoimage -l -r -J -V "${iso_label}"\
         -b isolinux/isolinux.bin\
         -no-emul-boot -boot-load-size 4 -boot-info-table\
         -c isolinux/boot.cat -o $output_iso $customiso

    echo " - Making USB bootable"
    sudo isohybrid $output_iso
}


### main functions ###
function update {
    install_packages
    install_boot_opts
    set_starts
    updateBootOpts    # update twice
    updateSquash lzo
    createISO
}

## Main order ##
function install {
    download_if_empty
    init_mount_unpack
    updateBootOpts
    install_packages
    copy_static_files
    set_permissions
    set_starts
    install_boot_opts
    updateBootOpts    # update twice
    updateSquash lz4
    createISO
}


$command