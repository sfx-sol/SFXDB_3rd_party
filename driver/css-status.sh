#!/bin/bash

#Usage: ./css-status.sh
#
# get css cards basic information - finding loaded css devices

if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root"
    exit 1
fi

declare -i devnum
devnum=999
if [[ "$1" != "" ]]; then
    if [[ "$1" =~ "/dev/sfd" ]]; then
        devnum=`echo $1 | sed 's/\/dev\/sfd//g'| sed  's/n1//g'`
    else
        check_devnum=`echo $1 | sed 's/[0-9]//g'`
        if [[ $check_devnum != "" ]]; then
            echo "The parameter must be card number [0-9] or /dev/sfd[0-9]n1"
            exit 1
        else
            devnum=$1
        fi
    fi
fi
sd=`dirname $0`
fd=`basename $0`
# echo "sd $sd fd $fd"
if ! [ -e $sd/sfx_functions ]; then
    echo "need $sd/sfx_functions to run $fd"
    exit 1
fi
source $sd/sfx_functions
sfd_load=0
no_sfxsfd=0
smartlog=""
smartlog0xc2=""
adminPassthruLog=""
identifyLog=""
statsfile="/proc/sfx/stats"
checkDevice=`ls /dev | grep sfd`
error_cards=0
sfx_num=0
pcie_warn_list="UncorrErr+ FatalErr+ EqualizationPhase3- DLP+ SDES+ TLP+ FCP+ CmpltTO+ CmpltAbrt+ UnxCmplt+ RxOF+ MalfTLP+ ECRC+ UnsupReq+ ACSViol+"

sfx_devices=""

function get_device(){
    check_sfx=`ls /dev | grep sfx`
    if [[ $check_sfx != "" ]]; then
        sfx_devices=`ls -v /dev/sfx[0-9]*`
        sfx_num=`ls /dev/sfx[0-9]* | sed -n '$='`
    fi
    check_sfd=`ls /dev | grep sfd`
    if [[ $check_sfd != "" ]]; then
        sfd_devices=`ls -v /dev/sfd[0-9]*n1`
        sfd_num=`ls /dev/sfd[0-9]*n1 | sed -n '$='`
    fi
    n=`lspci -d cc53: | sed -n '$='`
}


get_device

if [[ $n == "" ]]; then
    echo ""
    echo ">>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>"
    echo "No Computational Storage Subsystem card found or the card status is NOT correct. Please contact Admin for help."
    echo ">>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>"
    exit 1
fi

if [[ $checkDevice == "" ]]; then
    if [[ ! -e $statsfile ]]; then
        echo "No /dev/sfd* device found"
        echo "No sfxdriver load"
        exit 0
    fi
fi
if [[ -e $statsfile ]]; then
    statscontent=`sudo cat $statsfile`
fi
export PATH=$PATH:$(pwd)

# check nvme-cli installed
nvmepath=""
get_cmd_path nvme nvmepath
if [[ $? -eq 0 ]]; then
    get_cmd_path sfx_nvme nvmepath
    if [[ $? -eq 0 ]]; then
        echo "nvme command not found, please install nvme-cli"
        echo "For example, sudo yum install nvme-cli"
        exit 1
    fi
fi

stringSwitch() {
    output=$1
    j=6
    string=""
    for ((z = 1; z <= 4; z++)); do
        string=$string${output:$j:2}
        j=$j-2
    done
    let string=16#$string
    return $string
}

check_capacitor_status() {
    local nvme_val=$1
    local bit4_on=$(($nvme_val & $((1 << 4))))
    if [[ $bit4_on -ne 0 ]]; then
        capacitorBankStaus="Bad"
    else
        capacitorBankStaus="Good"
    fi
}


sfx_messages="/var/log/sfx_messages"
get_version_row_num=`cat $sfx_messages |grep -n -a SW_VERSION |tail -n 1 | cut -d ":" -f1`
if [[ $get_version_row_num != "" ]]; then
    sfx_messages_err=`cat $sfx_messages | tail -n +${get_version_row_num} | grep -E "\[ERR|FTL ass"`
else
    sfx_messages_err=`cat $sfx_messages | grep -E "\[ERR|FTL ass"`
fi

check_sfx_messages_err() {
    card_err="ERR0-$1-"
    if [[ $sfx_messages_err =~ $card_err ]]; then
        CheckLog=1
    fi
}

for sfx_name in $sfx_devices; do

    card_num=`echo $sfx_name | sed 's/\/dev\/sfx//g'`
    gold_img=n
    comp_only=n
    if [[ $devnum -ne 999 ]]; then
        if [[ $devnum -ne $card_num ]]; then
            continue
        fi
    fi
    # echo display "/dev/sfd"$[$i-1]"n1"
    # echo display "/dev/sfd"$(($i-1))"n1"
    # echo display "/sys/class/misc/sfx$(($i-1))/device/goldimg"
    sfd_name="/dev/sfd"$card_num"n1"
    #check log
    CheckLog=0
    get_nvme_log_successful=0
    get_bus_info=0
    CriticalWarningStatus=""
    capacitorBankStaus=""
    check_sfx_messages_err $card_num

    if [[ -e $sfx_name ]]; then
        #----------------------------------------------------------------------
        # Please note that the two fields in the ./device/probcnt kernel file are currently
        # in "naked" hexadecimal format, that is, they have 8 hexa-digits WITHOUT the leading
        # '0x' hexa-decimal indicator - so these two numbers should be handled accordingly.
        # Here is the code that produces the two fields:
        # File: drivers/src/sfx_driver.c
        #
        # static ssize_t sfx_probecnt_show(struct device *dev, struct device_attribute *attr, char *buf)
        # {
        #     struct pci_dev *pdev = to_pci_dev(dev);
        #     struct sfx_dev *sdev = pci_get_drvdata(pdev);
        #     return sfx_sprintf(buf, "%08x %08x\n", sdev->probe_cnt, sdev->probe_cnt_limit);
        # }
        #----------------------------------------------------------------------
        probecnt=`cat /sys/class/misc/sfx${card_num}/device/probecnt | awk '{print $1}'`
        probelimit=`cat /sys/class/misc/sfx${card_num}/device/probecnt | awk '{print $2}'`
        if [[ $probecnt != "ffffffff" && $probecnt != "fffffffe" && $probecnt != "fffffffd" ]]; then
            if [[ 0x$probecnt -gt 0x$probelimit ]]; then
                echo "#>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>"
                echo "The card $sfx_name is in SAFE mode."
                echo "#>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>"
                continue
            fi
        else
            if [[ $probecnt = "fffffffe" || $probecnt = "fffffffd" ]]; then
                echo "Note: Invalid data in NOR of $sfx_name, probecnt $probecnt probelimit $probelimit"
                echo "Please contact Admin."
            fi
        fi
    else
        #echo "ERROR: card $(($i-1)) does not exist, skip it."
        no_sfxsfd=1 #both sfx and sfd not loaded
        error_cards=$(($error_cards+1))
        continue
    fi
    if [[ -e "/sys/class/misc/sfx${card_num}/device/goldimg" ]]; then
        # echo "Gold image"
        gold_img=y
    fi
    #Get identify log using nvme get-log command
    bus_info_file="/sys/block/sfd${card_num}n1/bus_info"
    if [[ -e $bus_info_file ]]; then
        bus_info=`cat $bus_info_file 2>&1`
        if [[ $? -ne 0 ]]; then
            get_bus_info=1
        else
            lspci_info=`lspci -vvv -d cc53: -s ${bus_info}`
            if [[ $? -ne 0 ]]; then
                get_bus_info=1
            fi
            lspci_info_link=`echo "$lspci_info" | grep 'LnkSta:'`
            lspci_info_device=`echo "$lspci_info" | grep -E "UESta:|DevSta:"`
        fi
    fi
    identifyLog=`$nvmepath get-log $sfd_name --log-id=0xcc --log-len=512 2>&1`
    if [[ $? -ne 0 ]]; then
        if [[ -e $statsfile ]]; then
            get_nvme_log_successful=1
        else
            echo ""
            echo "#>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>"
            echo "The status of card $sfd_name is NOT correct. Please contact Admin for help."
            echo "#>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>"
            continue
        fi
    else
        #Get manufacturer
        Manufacturer=`echo "$identifyLog" | sed -n 3p | cut -c 59-71 | sed 's/\.//g'`
        Manufacturer+=`echo "$identifyLog" | sed -n 4p | cut -c 56-71 | sed 's/\.//g'`

        #Get Model
        Model=`echo "$identifyLog" | sed -n 5p | cut -c 64-66`" "
        Model+=`echo "$identifyLog" | sed -n 5p | cut -c 68-71`" "
        Model+=`echo "$identifyLog" | sed -n 6p | cut -c 56-62 | sed 's/\.//g'`

        #Get FPGA BitStream
        fpgaBitStream=`echo "$identifyLog" | sed -n 11p|cut -c 56-71 | sed 's/\.//g'`

        #Get PCIe Vendor ID
        PCIeVendorID=`echo "$identifyLog" | sed -n 3p | cut -c 10-11`
        PCIeVendorID+=`echo "$identifyLog" | sed -n 3p | cut -c 7-8`

        #Get PCIe Subsystem Vendor ID
        PCIeSubsystemVendorID=`echo "$identifyLog" | sed -n 3p | cut -c 16-17`
        PCIeSubsystemVendorID+=`echo "$identifyLog" | sed -n 3p | cut -c 13-14`

        #Get Serial Number
        SerialNumber=`echo "$identifyLog" | sed -n 7p | cut -c 56-71 |  sed 's/\.//g'`
        SerialNumber+=`echo "$identifyLog" | sed -n 8p | cut -c 56-71 |  sed 's/\.//g'`

        #Get OPN
        OPN=`echo "$identifyLog" | sed -n 9p | cut -c 56-71 | sed 's/\.//g'`
        OPN+=`echo "$identifyLog" | sed -n 10p | cut -c 56-71 | sed 's/\.//g'`

        #check Compression-only
        if [[ ${OPN:6:1} = "Z" ]]; then
            # echo "Compression-Only card"
            comp_only=y
        fi

        #Get Software Revision
        SoftwareRevision=`echo "$identifyLog" | sed -n 12p | cut -c 64-71`
        SoftwareRevision+=`echo "$identifyLog" | sed -n 13p | cut -c 56-60 | sed 's/\.//g'`

        #Get driver type information
        if [[ ${#OPN} -lt 12 || (${OPN:0:3} != "CSS" && ${OPN:0:3} != "CSD") ]]; then
            DriveType="Incorrect OPN"
        else
            case ${OPN:3:1} in
                P) DriveType="AIC-T+";;
                U) [[ ${OPN:4:1} = "3" ]] && DriveType="U.2-TPDB" || DriveType="U.2-T+";;
                *) DriveType="Incorrect OPN";
            esac
        fi

        if [[ $gold_img = 'n' && $comp_only = 'n' ]]; then
            #Get Disk Capacity
            DiskCapacity=`sudo blockdev --getsize64 $sfd_name`
            if [[ $DiskCapacity != "" ]]; then
                DiskCapacity=$[$DiskCapacity/1000/1000/1000]
            fi

            smartlog=`$nvmepath smart-log $sfd_name`
            #Get Temperature
            Temperature=`echo "$smartlog" | grep temperature | awk '{print $3}'`

            #Get Percentage Used
            PercentageUsed=`echo "$smartlog" | grep "percentage_used" | awk '{print $3}'`

            #Get Data Units Read
            DataUnitsRead=`echo "$smartlog" | grep "data_units_read" | awk '{print $3}'| sed 's/\,//g'`
            if [[ $DataUnitsRead != "" ]]; then
                DataUnitsRead=$[$DataUnitsRead*512*1000/1024/1024/1024]
            fi

            #Get Data Units Written
            DataUnitsWritten=`echo "$smartlog" | grep "data_units_written" | awk '{print $3}'|sed 's/\,//g'`
            if [[ $DataUnitsWritten != "" ]]; then
                DataUnitsWritten=$[$DataUnitsWritten*512*1000/1024/1024/1024]
            fi

            smartlog0xc2=`$nvmepath get-log $sfd_name --log-id=0xc2 --log-len=512`
            #Get PCIe RX Correct Error Count
            PCIeRXCorrectErrorCount=`echo "$smartlog0xc2" | sed -n 3p | cut -c 31-41 | sed 's/ //g'`
            stringSwitch $PCIeRXCorrectErrorCount
            PCIeRXCorrectErrorCount=$string

            #Get PCIe RX Uncorrect Error Count
            PCIeRXUncorrectErrorCount=`echo "$smartlog0xc2" | sed -n 3p | cut -c 43-54 | sed 's/ //g'`
            stringSwitch $PCIeRXUncorrectErrorCount
            PCIeRXUncorrectErrorCount=$string

            #Get Power Consumption
            PowerConsumption=`echo "$smartlog0xc2" | sed -n 4p | cut -c 43-54 | sed 's/ //g'`
	    stringSwitch $PowerConsumption
	    PowerConsumption=$string
	    if [[ $PowerConsumption -gt 50 ]] ; then
                PowerConsumption="Invalid"
	    fi


            #Get Temperature Throttling State
            TemperatureThrottling=`echo "$smartlog0xc2" | sed -n 4p | cut -c 31-41 | sed 's/ //g'`
            stringSwitch $TemperatureThrottling
            TemperatureThrottling=$string
            if [[ $(($TemperatureThrottling%2)) == 0 ]] ; then
                TemperatureThrottlingState="OFF"
            else
                TemperatureThrottlingState="ON"
                CriticalWarningStatus="Throttling State On"
            fi

            #backup capacitor status
            CriticalWarning0x02=`echo "$smartlog" | grep 'critical_warning' |  awk '{print $3}'`
            check_capacitor_status $CriticalWarning0x02
            if [[ $capacitorBankStaus == "Bad" ]]; then
                if [[ $TemperatureThrottlingState == "ON" ]]; then
                    CriticalWarningStatus+="/"
                fi
                CriticalWarningStatus+="Backup Capacitor Status Bad"
            fi

            #Get SFX Critical Warning
            CriticalWarning0xc2=`echo "$smartlog0xc2" | sed -n 5p | cut -c 19-20 | sed 's/ //g'`
            pf_data_loss=$(($CriticalWarning0xc2 & $((1 << 0))))
            if [[ $pf_data_loss != 0 ]] ; then
                if [[ $CriticalWarningStatus != "" ]] ; then
                    CriticalWarningStatus+="/"
                fi
                CriticalWarningStatus+="PF Data Loss, Freeze Mode"
            fi

            if [[ $CriticalWarningStatus == "" ]]; then
                CriticalWarningStatus="0"
            fi
            #Get Device  ReadOnly
            ReadOnly=`lsblk | grep ${sfd_name}##*/} | awk '{print $5}' | head -1`

            #Get multi-stream and atomic write status
            MultiStream=""
            AtomicWrite=""
            sfx_feature_stat_path="/sys/block/sfd${card_num}n1/sfx_smart_features/sfx_feature_stat"
            if [[ -e $sfx_feature_stat_path ]]; then
                sfx_feature_stat=`cat $sfx_feature_stat_path`
                if [[ $sfx_feature_stat =~ "Multi-Stream mode is on" ]]; then
                    MultiStream="ON"
                else
                    MultiStream="OFF"
                fi
                if [[ $sfx_feature_stat =~ "Atomic-Write mode is on" ]]; then
                    AtomicWrite="ON"
                else
                    AtomicWrite="OFF"
                fi
            fi
            PCIe_Link_Status=""
            if [[ $lspci_info_link =~ "Speed 8GT/s" ]]; then
                PCIe_Link_Status="Gen3 x4"
            elif [[ $lspci_info_link =~ "Speed 5GT/s" ]]; then
                PCIe_Link_Status="Gen2 x4"
            elif [[ $lspci_info_link =~ "Speed 2.5GT/s" ]]; then
                PCIe_Link_Status="Gen1 x4"
            fi
            PCIe_Device_Status="Good"
            if [[ $get_bus_info -ne 0 ]]; then
                PCIe_Device_Status="Unstable"
            else
                UncorrErr=0
                FatalErr=0
                othersErr=0
                for warn in $pcie_warn_list
                do
                    pci_warn_status=`echo "${lspci_info_device}" | grep '${warn}'`
                    if [[ $pci_warn_status != "" ]]; then
                        if [[ $warn = "UncorrErr+" ]]; then
                            UncorrErr=1
                        elif [[ $warn = "FatalErr+" ]]; then
                            FatalErr=1
                        else
                            othersErr=1
                        fi
                    fi
                    if [[ $othersErr -eq 1 ]]; then
                        PCIe_Device_Status="Warning"
                        break
                    fi
                    if  [[ $UncorrErr -eq 1 ]] && [[ $FatalErr -eq 1 ]]; then
                        PCIe_Device_Status="Warning"
                        break
                    fi
                done
            fi
        fi

        FPGAConfigurationSoftError=`sfx_sem_read_log /dev/sfx${card_num} | grep '!!!' | sed -e 's/.*\!\!\!//g'`
        tmpstr=($FPGAConfigurationSoftError)
        FPGAConfigurationSoftError_status=${tmpstr[@]^}

        echo ""
        if [[ $gold_img = 'y' ]]; then
            # echo "#>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>"
            # echo "The card sfx$(($i-1)) is loaded with gold image."
            # echo "#>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>"
            # echo "card sfx$(($i-1))"
            echo "Found Gold image card: $sfd_name"
        elif [[ $comp_only = 'y' ]]; then
            echo "Found Compression only card: $sfd_name"
        else
            echo "Found Computational Storage Subsystem card: $sfd_name"
        fi
        printf "%-35s%-35s\n" "PCIe Vendor ID:" "0x$PCIeVendorID"
        printf "%-35s%-35s\n" "PCIe Subsystem Vendor ID:" "0x${PCIeSubsystemVendorID}"
        printf "%-35s%-35s\n" "Manufacturer:" "${Manufacturer}"
        if [[ $DriveType == "U.2-TPDB" ]]; then
            Model="AF5UP34HTCSF3T2A"
        fi
        printf "%-35s%-35s\n" "Model:" "${Model}"
        printf "%-35s%-35s\n" "Serial Number:" "${SerialNumber}"
        printf "%-35s%-35s\n" "OPN:" "${OPN}"
        printf "%-35s%-35s\n" "FPGA BitStream:"  "${fpgaBitStream}"
        printf "%-35s%-35s\n" "Drive Type:" "${DriveType}"
        printf "%-35s%-35s\n" "Software Revision:" "${SoftwareRevision}"
        if [[ $gold_img = 'n' && $comp_only = 'n' ]]; then
            printf "%-35s%-35s\n" "Temperature:" "${Temperature} C"
            printf "%-35s%-35s\n" "Power Consumption:" "${PowerConsumption} W"
            printf "%-35s%-35s\n" "Disk Capacity:" "${DiskCapacity} GB"
            if [[ $ReadOnly -eq 1 ]]; then
                ReadOnly='on'
                printf "%-35s%-35s\n" "ReadOnly:" "${ReadOnly}"
            fi
            if [[ $MultiStream != "" ]]; then
                printf "%-35s%-35s\n" "Multi-Stream mode:" "${MultiStream}"
            fi
            if [[ $AtomicWrite != "" ]]; then
                printf "%-35s%-35s\n" "Atomic Write mode:" "${AtomicWrite}"
            fi
            printf "%-35s%-35s\n"  "Percentage Used:" "${PercentageUsed}"
            printf "%-35s%-35s\n" "Data Read:" "$DataUnitsRead GiB"
            printf "%-35s%-35s\n" "Data Written:" "$DataUnitsWritten GiB"
            printf "%-35s%-35s\n" "Correctable Error Cnt:" "$PCIeRXCorrectErrorCount"
            printf "%-35s%-35s\n" "Uncorrectable Error Cnt:" "$PCIeRXUncorrectErrorCount"
            printf "%-35s%-35s\n" "Check Log:" "$CheckLog"
            if [[ $PCIe_Link_Status != "" ]]; then
                printf "%-35s%-35s\n" "PCIe Link Status:" "${PCIe_Link_Status}"
            fi
            printf "%-35s%-35s\n" "PCIe Device Status:" "$PCIe_Device_Status"
            printf "%-35s%-35s\n" "Critical Warning:" "$CriticalWarningStatus"
            printf "%-35s%-35s\n" "FPGA Configuration Soft Error:" "$FPGAConfigurationSoftError_status"
        fi
    fi

    if [[ $get_nvme_log_successful -eq 1 ]]; then
        number="$card_num"
        checkDeviceInfoExsit=`echo "${statscontent}" | grep "dev\[${number}\]"`
        checksfdload=`ls /dev | grep sfd${card_num}n1`
        if [[ $checkDeviceInfoExsit != "" ]]; then
            echo ""
            if [[ $checksfdload == "" ]]; then
                echo "Found Computational Storage Subsystem card(s) on machine but sfd* is NOT loaded"
            elif [[ $get_bus_info -ne 0 ]]; then ##sfv exist but bd_dev not load or broken
                echo "Found Computational Storage Subsystem card(s) on machine but sfd* not ready"
            elif [[ $get_nvme_log_successful -eq 1 ]]; then
                echo "Found Computational Storage Subsystem card(s) on machine but nvme log for sfd* is NOT correct"
            fi
            sfxloadcontent=`echo "${statscontent}" | grep -E "dev\[${number}\]|OPN|Serial number" | grep -A 2 "dev\[${number}\]"`
            OPN=`echo "${sfxloadcontent}"| grep "OPN" | sed 's/OPN\://g'`
            SerialNumber=`echo "${sfxloadcontent}" | grep "Serial number:.*" | grep -o ':.* ' | grep -o '[[:alnum:]]*'`
            echo "card sfx${card_num}"
            printf "%-35s%-35s\n" "Serial Number:" "$SerialNumber"
            printf "%-35s%-35s\n" "OPN:" "$OPN"
            printf "%-35s%-35s\n" "Check Log:" "$CheckLog"
            if [[ $gold_img = 'y' ]]; then
                printf "%-35s%-35s\n" "Gold Image:" "ON"
            fi
        else
            no_sfxsfd=1 #card(s) both sfx and sfd not loaded
        fi
    fi
    if [[ $devnum -ne 999 ]]; then
        if [[ $devnum -eq $card_num ]]; then
            break
        fi
    fi
done

if [[ $sfx_num -eq 0 ]] && [[ $sfd_num -gt 0 ]]; then
    echo ""
    echo "Found Computational Storage Subsystem card(s) on machine but only sfv load and sfd* not ready"
    exit
fi
if [[ $n -gt $sfx_num ]]; then
    echo ""
    echo "#>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>"
    echo "Also found $((n-sfx_num)) Computational Storage Subsystem card(s) on machine but sfx* and sfd* is NOT loaded"
    echo "#>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>"
    echo ""
fi

