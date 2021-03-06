#!/bin/bash
export LANG="en_US.UTF-8"
export PATH=$PATH:/usr/sbin/
current_dir=$(dirname $0)
cd ${current_dir} || exit 1

readonly UPLOAD_URL="http://192.168.21.142:8000/api/machine/"

function gather_cpu_info () {
    local physical_cpu_count=$(cat /proc/cpuinfo | grep "physical id" | sort | uniq | wc -l)
    echo "physical_cpu_count: ${physical_cpu_count}"
    local logic_cpu_cores=$(cat /proc/cpuinfo | grep "processor" | wc -l)
    echo "logic_cpu_cores: ${logic_cpu_cores}"
    local cpu_core=$(cat /proc/cpuinfo | grep "cpu cores" | uniq | awk -F : '{print $NF}')
    echo "cpu_core: ${cpu_core}"
    if ((logic_cpu_cores == physical_cpu_count*cpu_core)); then
        echo "HT disabled"
    else
        echo "HT enabled"
    fi
    local cpu_name=$(cat /proc/cpuinfo | grep name | awk -F: '{print $NF}'| uniq)
    if [ $(echo ${cpu_name} | grep -c "GHz") -gt 0 ]; then
        local trimed_cpu_name=${cpu_name%@*}
        local cpu_frequency=${cpu_name#*@}
    else
        local trimed_cpu_name=${cpu_name}
    fi
    echo "cpu_name: ${trimed_cpu_name}"
    if [ -z ${cpu_frequency} ]; then
        cpu_frequency=$(cat /proc/cpuinfo | grep MHz | uniq | awk -F : '{printf("%.2f\n", $NF/1000)}')
    fi
    cpu_frequency=${cpu_frequency%GHz}
    echo "cpu_frequency: ${cpu_frequency} GHz"
    echo '    "physical_cpu_count":' ${physical_cpu_count}',' >> machine_info
    echo '    "cpu_core":' ${cpu_core}',' >> machine_info
    echo '    "logic_cpu_cores":' ${logic_cpu_cores}',' >> machine_info
    echo '    "cpu_name":' '"'${trimed_cpu_name}'",' >> machine_info
    echo '    "cpu_frequency":' ${cpu_frequency}',' >> machine_info
}

function gather_os_info () {
    type dmidecode &> /dev/null
    if [ $? -ne 0 ]; then
        yum install -y dmidecode
        if [ $? -ne 0 ]; then
            echo "install dmidecode failed"
            return 1
        fi
    fi
    local manufacturer=$(dmidecode -s system-manufacturer)
    echo "manufacturer: ${manufacturer}"
    local product_name=$(dmidecode -s system-product-name)
    echo "product_name: ${product_name}"
    local serial=$(dmidecode -s system-serial-number)
    echo "system serial number: ${serial}"
    local uuid=$(dmidecode -s system-uuid)
    echo "system uuid: ${uuid}"
    if [ -f /etc/redhat-release ]; then
        local os_name=$(cat /etc/redhat-release)
    else
        local os_name=$(grep PRETTY_NAME /etc/os-release | awk -F = '{print substr($2,2,length($2)-2)}')
    fi
    local kernel=$(uname -r)
    echo "kernel: ${kernel}"
    echo '    "manufacturer":' '"'${manufacturer}'",' >> machine_info
    echo '    "product_name":' '"'${product_name}'",' >> machine_info
    echo '    "serial":' '"'${serial}'",' >> machine_info
    echo '    "uuid":' '"'${uuid}'",' >> machine_info
    echo '    "os":' '"'${os_name}'",' >> machine_info
    echo '    "kernel":' '"'${kernel}'",' >> machine_info
}

function gather_nic_info () {
    type lspci &> /dev/null
    if [ $? -ne 0 ]; then
        yum install -y pciutils
        if [ $? -ne 0 ]; then
            echo "install pciutils failed"
            return 1
        fi
    fi
    echo '    "nic": [' >> machine_info
    local counter=0
    for nic in $(cat /proc/net/dev | grep -E ^\(\\s\)*e | awk -F : '{print $1}' | sort); do
        local nic_name=$(lspci | grep "^$(ethtool -i ${nic} | awk -F":" '/bus-info/{print $(NF-1)":"$NF}')" | awk -F : '{print $NF}')
        echo "nic name: ${nic_name}"
        if [ -z "${nic_name}" ]; then
            continue
        fi
        if [ $(ethtool ${nic} | grep -c "Supported link modes:   Not reported") -gt 0 ]; then
            local capability=$(ethtool ${nic} | grep -B1 "Advertised pause frame use" | grep -v "Advertised pause frame use" | awk '{print substr($NF,1,index($NF,"baseT/Full")-1)}')
        else
            local capability=$(ethtool ${nic} | grep -B1 "Supported pause frame use" | grep -v "Supported pause frame use" | awk '{print substr($NF,1,index($NF,"baseT/Full")-1)}')
        fi
        if [ -z "${capability}" ]; then
            capability=100
        fi
        echo "capability: ${capability} Mb/s"
        if [ ${counter} -gt 0 ]; then
            echo '        },' >> machine_info
        fi
        echo '        {' >> machine_info
        echo '            "name":' '"'${nic_name}'",' >> machine_info
        echo '            "capability":' ${capability} >> machine_info
        counter=$((counter+1))
    done
    if [ ${counter} -gt 0 ]; then
        echo '        }' >> machine_info
    fi
    echo '    ],' >> machine_info
}

function gather_ip_info () {
    echo '    "ip": [' >> machine_info
    local counter=0
    for ip_address in $(ip -f inet addr | grep inet | grep -Ev '127.0.0.1'\|'flannel'\|'docker'\|'virbr'\|'lo:'\|'br-' | awk '{if(index($2,"addr:")>0){print substr($2,6,index($2,"/")-6)}else{print substr($2,1,index($2,"/")-1)}}' | sort | uniq); do
        echo "ip address: ${ip_address}"
        if [ ${counter} -gt 0 ]; then
            echo '        },' >> machine_info
        fi
        echo '        {' >> machine_info
        echo '            "address":' '"'${ip_address}'"' >> machine_info
        counter=$((counter+1))
    done
    if [ ${counter} -gt 0 ]; then
        echo '        }' >> machine_info
    fi
    echo '    ],' >> machine_info
}

function gather_storage_info () {
    echo '    "storage": [' >> machine_info
    local counter=0
    for line in $(fdisk -l | grep -E "Disk /dev/sd"\|"Disk /dev/vd" | awk '{print $2$3}'); do
        local storage_label=$(echo ${line} | awk -F : '{print $1}')
        local volume=$(echo ${line} | awk -F : '{printf("%d", (substr($2,1,index($2,".")-1)%10==0)?$2:$2+1)}')
        local rotational=$(cat /sys/block/${storage_label#/dev/}/queue/rotational)
        if [ ${rotational} -eq 0 ]; then
            local media="SDD"
        else
            local media="HDD"
        fi
        echo "storage_label: ${storage_label}"
        echo "volume: ${volume} GB"
        echo "media: ${media}"
        if [ ${counter} -gt 0 ]; then
            echo '        },' >> machine_info
        fi
        echo '        {' >> machine_info
        echo '            "volume":' ${volume}',' >> machine_info
        echo '            "media":' ${rotational} >> machine_info
        counter=$((counter+1))
    done
    if [ ${counter} -gt 0 ]; then
        echo '        }' >> machine_info
    fi
    echo '    ],' >> machine_info
}

function gather_memory_info () {
    echo '    "memory": [' >> machine_info
    local counter=0
    for line in $(dmidecode -t memory | grep -A5 "Memory Device" | grep Size | grep -v "No Module Installed" | awk -F : '{print $2}' | awk '{print $1$2}'); do
        if [ $(echo ${line} | grep -c GB) -gt 0 ]; then
            local size=${line%GB}
        else
            local size=$(echo ${line} | awk '{printf("%d", substr($0,1,length($0)-2)/1024)}')
        fi
        echo "size: ${size} GB"
        if [ ${counter} -gt 0 ]; then
            echo '        },' >> machine_info
        fi
        echo '        {' >> machine_info
        echo '            "size":' ${size} >> machine_info
        counter=$((counter+1))
    done
    if [ ${counter} -gt 0 ]; then
        echo '        }' >> machine_info
    fi
    echo '    ]' >> machine_info
}


function upload () {
    local updated=1
    if [ -f machine_info.bak ]; then
        diff machine_info machine_info.bak &> /dev/null
        updated=$?
    fi
    if [ ${updated} -eq 1 ]; then
        local ret_val=$(curl -s -m 180 -w %{http_code} -H "Content-Type: application/json" -H "Authorization: Token 61c8af7afd24853995cf679f5f84258d87204aa1" -X POST -d "$(cat machine_info)" "${UPLOAD_URL}" -o /dev/null)
        echo "upload return code: ${ret_val}"
        if [ ${ret_val} -eq 200 ]; then
            echo "upload successfully"
        else
            echo "upload failed"
            return 1
        fi
    else
        echo "no update found"
    fi
}

function main() {
    #local old_hostname=$(hostname)
    if [ -f machine_info ]; then
        #old_hostname=$(sed -n '/"hostname/p' machine_info | awk '{print substr($2,2,index($2,",")-3)}')
        mv machine_info machine_info.bak
    fi
    echo '{' > machine_info
    echo hostname: $(hostname)
    echo '    "hostname":' '"'$(hostname)'",' >> machine_info
    #if [ $(hostname) != "${old_hostname}" ]; then
    #    echo '    "old_hostname":' '"'${old_hostname}'",' >> machine_info
    #fi
    gather_cpu_info
    gather_os_info
    local ret_val=$?
    if [ ${ret_val} -ne 0 ]; then
        return ${ret_val}
    fi
    gather_nic_info
    local ret_val=$?
    if [ ${ret_val} -ne 0 ]; then
        return ${ret_val}
    fi
    gather_ip_info
    gather_storage_info
    gather_memory_info
    echo '}' >> machine_info
    upload
    if [ $? -ne 0 ]; then
        rm -f machine_info machine_info.bak
        return 1
    fi
}

main