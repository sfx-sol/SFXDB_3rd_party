#!/bin/bash
#------------------------------------------------------------------------------
# Copyright (c) 2015-2018, ScaleFlux, Inc.
#------------------------------------------------------------------------------

usage=$'Usage: ./sfxfwdownload.sh -f|--force -y|--yes -a|--all -h|--help -c|--activate -u|--uncheck -i|--inquire-act <device_name, e.g. /dev/sfd0n1> [<name_of_image_file>] [<search_diretory_for_image_file>]\n\t-f|--force: download image file without checking OPN\n\t-y|--yes: use yes as default answer\n\t-a|-all: all devices on the systemr\n\t-u|--uncheck: Skip checking DMI information and download firmware without power cycle [NOTE: this option may not work with some systems.]\n\t-h|--help: display this message'

if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root"
    exit 1
fi

sd=`dirname $0`
fd=`basename $0`

if ! [ -e $sd/sfx_functions ]; then
    echo "need $sd/sfx_functions to run $fd"
    exit 1
fi

source $sd/sfx_functions
img=""
img_size=""
img_known=n
img_abs=n
img_cnt=0
force=n
ans_default=y

if [[ $# -eq 0 ]]; then
    echo "$usage"; exit 1
fi
script=$0
if [[ ${script:0:1} = / ]]; then
    scriptdir=`dirname $script`
else
    scriptdir=.
fi

all=n
devices=""
searchdir=.
activate=n
inquire_act=n
uncheck_device=n

get_devices() {
    if [[ $devices = "" ]]; then
        devices=`ls /dev/sfd*n1 | tr '\n' ' '`
        if [[ $devices = "" ]]; then
            echo "no sfd device is available"
            exit 1
        else
            if [[ ${devices: -1} =  ' ' ]]; then
                devices=${devices%?}
                # echo "DEBUG: devices \"$devices\""
            fi
        fi
        # echo "DEBUG -a devices: $devices"
    else
        echo "device_name is given as argument, cannot do -a"
        exit 1
    fi
}

process_args() {
    # echo "DEBUG enter process_args \"$1\""
    if [[ -e "$1" ]]; then
        if [[ -b "$1" ]]; then
            if [[ $all = 'y' ]]; then
                echo "-a|-all is specified, cannot specify another device name"
                exit 1
            else
                onedev=$1
                if [[ ${onedev:0:8} != "/dev/sfd" ]] \
                   || [[ ${onedev: -2} != "n1" ]]; then
                    echo "$onedev: bad device name"
                    exit 1
                else
                    if [[ $devices = "" ]]; then
                        devices=$onedev
                    else
                        devices="$devices $onedev"
                    fi
                fi
            fi
        fi
        if [[ -f "$1" ]]; then
            img=$1
            imgbase=`basename $img`
            # assuming <opn>_<version>.bin
            if [[ "${imgbase: -4}" != ".bin" ]]; then
                echo "$img: bad image, not a *.bin file"
                exit 1
            else
                # echo "$img: Known"
                img_known=y
                img_cnt=1
                if [[ ${img:0:1} = / ]]; then
                    # echo "$img: absolute path"
                    img_abs=y
                    searchdir=""
                fi
            fi
        fi
        if [[ -d "$1" ]]; then
           if ! [ "$(ls -A $1)" ]; then
               echo "$1: is empty, use current directory"
               searchdir=.
           else
               searchdir=$1
           fi
        fi
    else
        echo "$1: not exist, Unknown argument"
        echo "$usage"; exit 1
    fi
}

while [[ $# -gt 0 ]]; do
    case $1 in
        -f|--force) force=y;;
        -y|--yes) ans_default=y;;
        -a|-all) get_devices; all=y;;
        -h|--help) echo "$usage"; exit 0;;
        -c|--activate) activate=y;;
        -i|--inquire-act) inquire_act=y; ans_default=n;;
        -u|--uncheck) uncheck_device=y;;
        *) process_args "$1";;
    esac
    shift
done

if [[ $devices = "" ]]; then
    echo "$usage"; exit 1
fi

hasgoldimg=n
for device in $devices; do
    coredevice=`echo $device | sed -e 's/sfd\([0-9]*\)*/sfx\1/' -e 's/\(.*\)n[0-9]*/\1/'`
    # echo "DEBUG coredevice $coredevice"
    core=`basename $coredevice`
    # echo "DEBUG coredevice $coredevice core $core"
    if [[ -e /sys/class/misc/${core}/device/goldimg ]]; then
        if [[ $ans_default = "n" ]]; then
            echo -n "$coredevice is loaded with gold image, still downloading? (y/n) "
            read answer
            if [[ $answer = 'n' ]]; then
                devices=${devices//$device/}
            fi
        fi
        echo "$coredevice is loaded with gold image"
        hasgoldimg=y
    fi
done

if [[ $devices = "" ]]; then
    echo "No card to download"
    exit 0
fi
if [[ $hasgoldimg = "y" ]]; then
    activate=n
    echo "Some card has gold image. There is no support of \"Hot HW image update\" for this download"
fi

# if -c|--activate is specified, checking mount in advance
# else power cycle is required after download, so don't care
willexit=n
if [[ $activate = 'y' ]]; then
    for device in $devices; do
        mnts=`findmnt -n $device | awk '{print $1}' |xargs echo -n`
        if [[ -n "$mnts" ]]; then
            echo "WARN: $device is mounted on \"$mnts\" with -c|--activate specified"
            willexit=y
        fi
    done
fi
if [[ $willexit = 'y' ]]; then
    echo "When -c|--activate specified, you need to manually umount all mounted sfx drives and run this script again."
    exit 1
fi

cat /etc/*-release | grep -qi -E 'ubuntu|debian' 2>/dev/null
if [[ $? -eq 0 ]]; then
    os=ubuntu
else
    os=centos
fi

# we've known force-or-not, device and img, check existene of nvme.
nvmepath=""
get_cmd_path sfx_nvme nvmepath
if [[ $? -eq 0 ]]; then
    get_cmd_path nvme nvmepath
    if [[ $? -eq 0 ]]; then
        echo "nvme command not found, please 'yum install nvme-cli' and run this script again"
        exit 2
    fi
fi
# echo "scriptdir $scriptdir searchdir $searchdir nvmepath $nvmepath"

echo "Download image for $devices, using $nvmepath"

# check version of software
pids=()
devs=()
devs_u2=()
#------------------------------------------------------------------------------
# IMPORTANT NOTE:
# After the 2.2.x release, the software version string format has been redefined.
# As a result, the embedded 32-bit SW version number format is now this:
#     Major SW Ver: bits: 29..31 ( 3 bits) value: 0..7      less than (1 << 3)
#     Minor SW Ver: bits: 25..28 ( 4 bits) value: 0..15     less than (1 << 4)
#     SW Patch Ver: bits: 18..24 ( 7 bits) value: 0..127    less than (1 << 7)
#     SVN Revision: bits:  0..17 (18 bits) value: 0..262143 less than (1 << 18)
#------------------------------------------------------------------------------
bitpos_arr=(29 25 18)
# FW Download only supported from software vesion 1.2.4 and on.
old_swvid=$(((1 << ${bitpos_arr[0]}) + (2 << ${bitpos_arr[1]}) + (4 << ${bitpos_arr[2]})))

imgvid=""
sw_ver_str=""
swvid=""
prepare() {
    device=$1
    sw_ver_str=(`$nvmepath get-log $device -i 0xcc -l 256 -b 2>/dev/null |xxd -s 152 -l 16 2>/dev/null | grep -o '[0-9]*\.[0-9]*\.[0-9]*' 2>/dev/null | head -1`)
    if [[ "$sw_ver_str" = "" ]]; then
        # old software, look for it from rpm
        if [[ "$os" = "centos" ]]; then
            sw_ver_str=`rpm -qa | grep sfx_bd_dev | awk -F '-' '{print $(NF-1)}'`
        fi
        if [[ "$os" = "ubuntu" ]]; then
            sw_ver_str=`dpkg -l | grep sfxdriver | awk '{print $3}' | awk -F '-' '{print $1}'`
        fi
        if [[ "$sw_ver_str" = "" ]]; then
            echo "Unknown software version; please update and rebuild your software, or install a pacakge with known version."
            exit 3
        fi
    fi
    sw_ver_arr=(`echo $sw_ver_str | grep -oE '[0-9]+'`)
    swvid=$(((${sw_ver_arr[0]} << ${bitpos_arr[0]}) + (${sw_ver_arr[1]} << ${bitpos_arr[1]}) + (${sw_ver_arr[2]} << ${bitpos_arr[2]})))

    if [[ $force = "n" ]]; then
        # match opn
        opn=`$nvmepath get-log $device -i 0xcc -l 128 -b 2>/dev/null | xxd -s 104 -l 12 2>/dev/null | awk '{print $NF}' 2>/dev/null`
        cnt=$(echo $opn | grep -c '^CSS')
        wide=$(echo -n $opn | wc -c)
        if [[ -z "$opn" || $cnt -ne 1 || $wide -lt 12 ]]; then
            echo "Found invalid OPN=$opn of device=$device; no FW download performed on $device"
            continue
        fi
        opnsz=${opn:7:3}
        opnff=${opn:3:2}
        if [[ 1$opnsz -le 1020 ]]; then
            # echo "DEBUG $opnsz <= 020"
            opn=${opn/$opnsz/016}
        elif [[ 1$opnsz -le 1040 ]]; then
            # echo "DEBUG $opnsz > 020 & <= 040"
            opn=${opn/$opnsz/032}
        elif [[ 1$opnsz -le 1080 ]]; then
            # echo "DEBUG $opnsz > 040 & <= 080"
            opn=${opn/$opnsz/064}
        fi
        # echo "DEBUG opn=$opn"
        if [[ $img_known = "n" ]]; then
            # echo "DEBUG searchdir $searchdir opn $opn"
            img_cnt=`ls ${searchdir}/${opn}*.bin 2>/dev/null | wc -l`
            if [[ $img_cnt -eq 0 ]]; then
                echo "No image file with opn \"$opn\" in $searchdir to use, skip $device"
                continue
            fi
            if [[ $img_cnt -gt 1 ]]; then
                echo "$img_cnt files contain opn \"${opn}*.bin\", will take the first one"
            fi
            img_list=`ls ${searchdir}/${opn}*.bin 2>/dev/null`
            if [[ $img_list = "" ]]; then
                echo "No image file with opn \"$opn\" in $searchdir , skip $device"
                continue
            fi
            # echo "img_list $img_list"
            img=`echo -n $img_list | awk '{print $1}'`
            # img_first=`echo -n $img_list | awk '{print $1}'`
            # img=`basename $img_first`
            # echo "img $img"
        else
            if [[ ${imgbase/$opn} = $imgbase ]]; then
                echo "$img: bad image, no opn $opn"
                exit 3
            fi
        fi
    else
        if [[ $img_known = "n" ]]; then
            echo "ERROR: !checking on OPN bug no image file specified"
            exit 3
        fi
    fi
    img_size_orig=$(stat -c%s "$img")
    # echo "DEBUG img $img img_size_orig $img_size_orig"
    img_size=$(( (($img_size_orig / 4096) + 1) * 4096 ))
    # echo "DEBUG round up img_size $img_size"

    imgvid=`echo $img | sed -n -e 's/.*_\([0-9].*\).bin/\1/p'`
    if [[ "$imgvid" = "" ]]; then
        echo "$img: unknown version"
        exit 4
    fi
    imgvid=$(echo $imgvid | sed 's/^0*//')
}

# echo "DEBUG: fw_download \"$devices\""
# fw_download $devices
for device in $devices; do
    # echo "===== download device $device"
    prepare $device
    if [[ $imgvid -lt 3031 ]]; then
        echo "FW image $img, version $imgvid is old (< 3031), please check with ScaleFlux support team for installation."
    else
        # Please note that the internal/development sw will have sv ver 0.0.0, thus swvid=0
        if [[ $swvid -gt 0 && $swvid -lt $old_swvid ]]; then
            echo "Current software version $sw_ver_str does not support installation of this image, version $imgvid."
        else
            ans=""
            if [[ "$ans_default" = "n" ]]; then
                echo -n "Download $img on $device? (y/n) "
                read ans
            fi
            if [[ "$ans" = "y" || "$ans_default" = "y" ]]; then
                ($nvmepath fw-download $device -f $img -x $img_size) &
                echo "Download $img on $device starts, it will take 10 minutes..."
                pids+=($!)
                devs+=($device)
                if [[ $opnff = "U2" ]]; then
                    devs_u2+=($device)
                fi
            fi
        fi
    fi
done

# i=0
# for pid in ${pids[@]}; do
#     echo "DEBUG pid=$pid device ${devs[$i]} device_u2 ${devs_u2[$i]}"
#     (( i++ ))
# done

echo "You may use 'dmesg' to view the progress of download."

coredev=""
coredev_list=""
coredev_list_u2=""

if [[ ${#pids[@]} -eq 0 ]]; then
    echo "Empty pids[], done"
    exit 0
fi

i=0
for pid in ${pids[@]}; do
    # echo "DEBUG pid=$pid device ${devs[$i]}"
    wait $pid
    if [[ $? -ne 0 ]]; then
        echo "Download image for ${devs[$i]} failed, please check the image or retry this script."
    else
        add_to_u2=n
        echo "Image for ${devs[$i]} is downloaded successfully."
        # echo "DEBUG Checking if it's U2"
        for j in ${devs_u2[@]}; do
            if [[ ${devs[$i]} = $j ]]; then
                # echo "DEBUG Image for ${devs[$i]} is U2."
                add_to_u2=y
                break
            fi
        done
        coredev=`echo ${devs[$i]} | sed -e 's/sfd\([0-9]*\)*/sfx\1/' -e 's/\(.*\)n[0-9]*/\1/'`
        # echo "DEBUG coredev $coredev"
        if [[ "coredev_list" = "" ]]; then
            coredev_list="$coredev"
        else
            coredev_list="$coredev_list $coredev"
        fi
        if [[ $add_to_u2 = "y" ]]; then
            if [[ "coredev_list_u2" = "" ]]; then
                coredev_list_u2="$coredev"
            else
                coredev_list_u2="$coredev_list_u2 $coredev"
            fi
        fi
    fi
    ((i++))
done

echo "Download Done"

# coredev_list=`echo ${devs[0]} | sed -e 's/sfd\([0-9]*\)*/sfx\1/' -e 's/\(.*\)n[0-9]*/\1/'`
# coredev_list_u2=`echo ${devs_u2[0]} | sed -e 's/sfd\([0-9]*\)*/sfx\1/' -e 's/\(.*\)n[0-9]*/\1/'`
# echo "DEBUG coredev_list \"$coredev_list\" are programmed devices"
# echo "DEBUG coredev_list_u2 \"$coredev_list_u2\" are programmed U2 devices"

if [[ $coredev_list = "" ]]; then
    echo "All failed, exit"
    exit 3
fi

ans_act=""
inquire() {
    lans=$2
    echo -n "$1"
    read answer
    if [[ "$answer" != "y" ]]; then
        exit 0
    else
        eval $lans="$answer"
    fi
}

check_product() {
    manufacture=`dmidecode |grep -A1 "System Information" |grep Manufacturer: |awk '{print $2}'`
    product=`dmidecode |grep -A2 "System Information" |grep "Product Name:" |awk '{print $3}'`
    model=`dmidecode |grep -A2 "System Information" |grep "Product Name:" |awk '{print $4}'`
    if [[ $manufacture != "Dell" || $product != "PowerEdge" || $model != "R640" ]]; then
        echo "No support of firmware activation without reset for $manufacture-$product-$model"
        exit 1
    fi
}

bus_path_str_all=""
bus_path_str=""
get_sub_list() {
    hay=$1
    needle=$2
    result=$3
    result_val=""
    # bus_path_str_all=`lspci -D -d cc53: | awk '{print $1}' | tr '\n' ' '`
    # bus_path_str=""
    for i in $hay; do
        # dev_name is sfx0, sfx1, ...
        dev_name=`ls /sys/bus/pci/devices/$i/misc`
        for j in $needle; do
            if [[ "/dev/$dev_name" = $j ]]; then
                if [[ $result_val = "" ]]; then
                    result_val="$i"
                else
                    result_val="$result_val $i"
                fi
                break
            fi
        done
    done
    eval "$result"="'$result_val'"
}

pkginstalled=""
modprobeconfile=/etc/modprobe.d/sfx-modprobe.conf
insmod_argpath=""
insmod_blkftl=""
get_driverpath() {
    if [[ "$os" = "centos" ]]; then
        pkginstalled=`rpm -qa | grep sfx_bd_dev`
    fi
    if [[ "$os" = "ubuntu" ]]; then
        pkginstalled=`dpkg -l | grep sfxdriver`
    fi
    if [[ "$pkginstalled" = "" ]]; then
        if [[ -f ../software/output/sfxdriver.ko ]]; then
            insmod_argpath=../software/output/sfxdriver.ko
            insmod_blkftl=../software/output/sfx_bd_dev.ko
        else
            echo "Neither package installed nor ./sfxdriver.ko exist!"
            exit 2
        fi
        # echo "DEBUG insmod_argpath $insmod_argpath, insmod_blkftl $insmod_blkftl"
    else
        if [[ -e $modprobeconfile ]]; then
            insmod_argpath=`cat $modprobeconfile |grep sfxdriver.ko | sed 's|sfxdriver.ko.*$|sfxdriver.ko|' | awk '{print $2}'`
            insmod_blkftl=`cat $modprobeconfile | grep sfx_bd_dev.ko | sed -e 's|^.* insmod ||' -e 's|;.*$||'`
        fi
    fi
}

goldev_list=""
fw_activate() {
    goldev_list_local=$2
    goldev_list_val=""

    sleep 1
    # echo "INFO: Start processing devices @ $1"
    for i in $1; do
        if [[ $inquire_act = 'y' ]]; then
            inquire "Trigger $i? (y/n) " ans_act
        fi
        cfile=/sys/bus/pci/devices/$i/fwactmode
        if [[ -e $cfile ]]; then
            # echo "DEBUG Start triger device $i"
            echo 1 > $cfile
            sleep 3
        else
            echo "ERROR: $cfile doest not exist, cannot trigger activation"
        fi
    done

    if [[ $inquire_act = 'y' ]]; then
        inquire "Trigger done, continue wait for device /sys/bus/pci/devices/<bdf> ? (y/n) " ans_act
    fi

    for i in $1; do
        dev_file=/sys/bus/pci/devices/$i
        # echo "DEBUG: i $i, dev_file $dev_file"
        j=0
        while ! [[ -e "$dev_file" ]] && [[ $j -lt 10 ]]; do
            echo "INFO: Waiting for device $i"
            sleep 5
            ((j++))
        done
        if [[ $j -lt 10 ]]; then
            if [[ -e /sys/bus/pci/devices/$i/goldimg ]]; then
                echo "WARN: $i is gold image"
                goldev=`ls /sys/bus/pci/devices/$i/misc`
                goldev=`echo $goldev | tr 'x' 'd'`
                goldev=/dev/${goldev}n1
                if [[ $goldev_list_val = "" ]]; then
                    goldev_list_val="$goldev"
                else
                    goldev_list_val="$goldev_list_val $goldev"
                fi
            fi
        else
            echo "Waiting for device $i timeout"
            echo "Please power off, wait for 10 seconds, and power on the system after this script finishes."
        fi
    done
    eval "$goldev_list_local"="'$goldev_list_val'"
}

fw_verify() {
    sleep 1
    # echo "INFO: Start processing devices @ $1"
    for i in $1; do
        cfile=/sys/bus/pci/devices/$i/fwactstatus
        if [[ -e $cfile ]]; then
            reg_return_code=`cat $cfile`
            if [[ $reg_return_code != "00000000" ]]; then
                echo "ERROR: verification for $i failed: $reg_return_code!"
            else
                echo "INFO: $i is successfully verified."
            fi
        else
            echo "ERROR: $cfile doest not exist, cannot get reg_return"
        fi
    done
}

reprogram() {
    devices=$1

    coredev=""
    coredev_list_u2=""
    # re_program $devices
    for device in $devices; do
        img=""
        img_size=""
        img_cnt=0
        imgvid=""
        sw_ver_str=""
        swvid=""
        # echo "===== download device $device"
        prepare $device
        if [[ $imgvid -lt 3031 ]]; then
            echo "FW image $img, version $imgvid is old (< 3031), please check with ScaleFlux support team for installation."
        else
            # Please note that the internal/development sw will have sv ver 0.0.0, thus swvid=0
            if [[ $swvid -gt 0 && $swvid -lt $old_swvid ]]; then
                echo "Current software version $sw_ver_str does not support installation of this image, version $imgvid."
            else
                ans=""
                if [[ "$ans_default" = "n" ]]; then
                    echo -n "Re-Download $img on $device? (y/n) "
                    read ans
                fi
                if [[ "$ans" = "y" || "$ans_default" = "y" ]]; then
                    ($nvmepath fw-download $device -f $img -x $img_size)
                    echo "Re-Download $img for $device starts"
                    # pids+=($!)
                    coredev=`echo $device | sed -e 's/sfd\([0-9]*\)*/sfx\1/' -e 's/\(.*\)n[0-9]*/\1/'`
                    # devs+=($device)
                    if [[ $opnff = "U2" ]]; then
                        # devs_u2+=($device)
                        if [[ "coredev_list_u2" = "" ]]; then
                            coredev_list_u2="$coredev"
                        else
                            coredev_list_u2="$coredev_list_u2 $coredev"
                        fi
                        # echo "DEBUG coredev_list_u2 $coredev_list_u2"
                    else
                        echo "ERROR: Re-program NOT u.2 card"
                    fi
                fi
            fi
        fi
    done
}

if [[ $activate = 'n' ]]; then
    echo "Please power off, wait for 10 seconds, and power on the system."
    exit 0
else
    if [[ $uncheck_device = 'n' ]]; then
        check_product
    else
        echo "[debug] Device was not checked---------------------------"
    fi
    if [[ $inquire_act = 'y' ]]; then
        inquire "-c|--activate spcified, continue activation of firmware? (y/n) " ans_act
    fi

    dev_cnt=`lspci -D -d cc53: | wc -l`
    if [[ $dev_cnt = "" ]]; then
        echo "Card is not detected after download, exit"
        exit 4
    fi

    bus_path_str_all=`lspci -D -d cc53: | awk '{print $1}' | tr '\n' ' '`
    if [[ ${bus_path_str_all: -1} =  ' ' ]]; then
       bus_path_str_all=${bus_path_str_all%?}
       # echo "DEBUG: bus_path_str_all \"$bus_path_str_all\""
    fi

    if [[ "$coredev_list_u2" = "" ]]; then
        echo "Hot firmware update only supports U.2 card"
        echo "Please power off, wait for 10 seconds, and power on the system."
        exit 0
    fi
    # i=0
    # for j in ${coredev_list_u2[@]}; do
    #     echo "DEBUG: coredev_list_u2[$i] $j"
    #     (( i++ ))
    # done
    # i=0

    get_sub_list "$bus_path_str_all" "$coredev_list_u2" bus_path_str
    # echo "DEBUG hay: $bus_path_str_all, needle: $coredev_list_u2, result: $bus_path_str"

    get_driverpath
    if [[ "$pkginstalled" = "" ]]; then
        rmmod sfx_bd_dev
    else
        modprobe -r sfx_bd_dev
    fi
    if [[ $? -ne 0 ]]; then
        echo "Cannot remove sfx_bd_dev"
        exit 2
    fi

    if [[ "$pkginstalled" = "" ]]; then
        rmmod sfxdriver
    else
        modprobe -r sfxdriver
    fi
    if [[ $? -ne 0 ]]; then
        echo "Cannot remove sfxdriver"
        exit 2
    fi

    if [[ "$pkginstalled" = "" ]]; then
        insmod $insmod_argpath
    else
        modprobe sfxdriver
    fi
    if [[ $? -ne 0 ]]; then
        echo "Cannot insmod sfxdriver"
        exit 2
    fi

    if [[ $inquire_act = 'y' ]]; then
        inquire "Activate firmware? (y/n) " ans_act
    fi

    # echo "DEBUG: call fw_activate, bus_path_str \"$bus_path_str\" goldev_list: $goldev_list"
    fw_activate "$bus_path_str" goldev_list
    # echo "DEBUG: fw_activate, bus_path_str \"$bus_path_str\" goldev_list: $goldev_list"
    sleep 5

    if [[ $inquire_act = 'y' ]]; then
        inquire "Verify? (y/n) " ans_act
    fi

    fw_verify "$bus_path_str"

    if [[ $inquire_act = 'y' ]]; then
        inquire "firmware verify done, insmod blk ftl? (y/n) " ans_act
    fi

    # insmod $insmod_blkftl
    if [[ "$pkginstalled" = "" ]]; then
        # echo "DEBUG: !pkgintalled, insmod $insmod_blkftl"
        insmod $insmod_blkftl
        find_device /dev/sfd $dev_cnt 120 0 n1
    else
        # echo "DEBUG: pkgintalled, modprobe sfx_bd_dev"
        modprobe sfx_bd_dev
    fi

    if [[ "$goldev_list" != "" ]]; then
        echo "reprogram goldev_list $goldev_list"
        if [[ $inquire_act = 'y' ]]; then
            inquire "Re-program $goldev_list? (y/n) " ans_act
        fi

        reprogram "$goldev_list"
        echo "$goldev_list reprogrammed, Please power off, wait for 10 seconds, and power on the system."
        exit 999
    fi
fi

echo "All done"
