#!/bin/bash
set -o pipefail
export LANG="en_US.UTF-8"
export PATH=$PATH:/usr/sbin/
current_dir=$(dirname $0)
cd ${current_dir} || exit 1
readonly UPLOAD_URL="http://192.168.21.142:8000/inventory/uploadMachineInfo"
#readonly UPLOAD_URL="http://172.16.32.109:8500/inventory/uploadMachineInfo"
function gather_cpu_info () {
    local physical_cpu_count=$(cat /proc/cpuinfo | grep "physical id" | sort | uniq | wc -l)
    echo "physical_cpu_count: ${physical_cpu_count}" > machine.log
    local logic_cpu_cores=$(cat /proc/cpuinfo | grep "processor" | wc -l)
    echo "logic_cpu_cores: ${logic_cpu_cores}" >> machine.log
    local cpu_core=$(cat /proc/cpuinfo | grep "cpu cores" | uniq | awk -F : '{print $NF}')
    echo "cpu_core: ${cpu_core}" >> machine.log
    if ((logic_cpu_cores == physical_cpu_count*cpu_core)); then
        echo "HT disabled" >> machine.log
    else
        echo "HT enabled" >> machine.log
    fi
    local cpu_name=$(cat /proc/cpuinfo | grep name | awk -F: '{print $NF}'| uniq)
    if [ $(echo ${cpu_name} | grep -c "GHz") -gt 0 ]; then
        local trimed_cpu_name=${cpu_name%@*}
        local cpu_frequency=${cpu_name#*@}
    else
        local trimed_cpu_name=${cpu_name}
    fi
    echo "cpu_name: ${trimed_cpu_name}" >> machine.log
    if [ -z ${cpu_frequency} ]; then
        cpu_frequency=$(cat /proc/cpuinfo | grep MHz | uniq | awk -F : '{printf("%.2f\n", $NF/1000)}')
    fi
    cpu_frequency=${cpu_frequency%GHz}
    echo "cpu_frequency: ${cpu_frequency} GHz" >> machine.log
    echo '    "physical_cpu_count":' ${physical_cpu_count}',' >> machine_info
    echo '    "cpu_core":' ${cpu_core}',' >> machine_info
    echo '    "logic_cpu_cores":' ${logic_cpu_cores}',' >> machine_info
    echo '    "cpu_name":' '"'${trimed_cpu_name}'",' >> machine_info
    echo '    "cpu_frequency":' ${cpu_frequency}',' >> machine_info
}

function gather_os_info () {
    local product_name=$(dmidecode -s system-product-name)
    echo "product_name: ${product_name}" >> machine.log
    local os_name=$(cat /etc/redhat-release)
    echo "os_name: ${os_name}" >> machine.log
    local kernal=$(uname -r)
    echo "kernal: ${kernal}" >> machine.log
    echo '    "product_name":' '"'${product_name}'",' >> machine_info
    echo '    "os":' '"'${os_name}'",' >> machine_info
    echo '    "kernal":' '"'${kernal}'",' >> machine_info
}

function gather_nic_info () {
    type lspci &> /dev/null
    if [ $? -ne 0 ]; then
        yum install -y pciutils
    fi
    echo '    "nic": [' >> machine_info
    local counter=0
    local nic_list=""
    for nic in $(cat /proc/net/dev | grep ^team | awk -F : '{print $1}' | sort); do
        local ip=$(ifconfig ${nic} | grep inet | grep -v inet6 | awk '{print $2}')
        for i in $(nmcli con show | grep "${nic}-port1" | awk '{print $NF}' | sort); do
            nic_list="${nic_list} ${i}:${ip}"
        done
    done
    for nic in $(cat /proc/net/dev | grep -Ev ^veth\|^docker\|^flannel\|^team\|Inter\|face\|lo | awk -F : '{print $1}' | sort); do
        local nic_name=$(lspci | grep "^$(ethtool -i ${nic} | awk -F":" '/bus-info/{print $(NF-1)":"$NF}')" | awk -F : '{print $NF}')
        echo "nic name: ${nic_name}" >> machine.log
        local ip=$(ifconfig ${nic} | grep inet | grep -v inet6 | awk '{print $2}')
        if [ -z "${ip}" ] && [ -n "${nic_list}" ]; then
            local ip=$(echo ${nic_list} | awk '{for(i=1;i<=NF;i++){if(index($i,"'${nic}'")>0){print substr($i,index($i,":")+1,length($i)-1)}}}')
        fi
        echo "ip: ${ip}" >> machine.log
        local capability=$(ethtool ${nic} | grep -B1 "Supported pause frame use" | grep -v "Supported pause frame use" | awk '{print substr($NF,1,index($NF,"baseT/Full")-1)}')
        if [ -z "${capability}" ]; then
            capability=0
        fi
        echo "capability: ${capability} Mb/s" >> machine.log
        if [ ${counter} -gt 0 ]; then
            echo '        },' >> machine_info
        fi
        echo '        {' >> machine_info
        echo '            "name":' '"'${nic_name}'",' >> machine_info
        echo '            "ip":' '"'${ip}'",' >> machine_info
        echo '            "capability":' ${capability} >> machine_info
        counter=$((counter+1))
    done
    echo '        }' >> machine_info
    echo '    ],' >> machine_info
}

function gather_storage_info () {
    echo '    "storage": [' >> machine_info
    local counter=0
    fdisk -l | grep -E "Disk /dev/sd"\|"Disk /dev/vd" | awk '{print $2$3}' | while read line; do
        local storage_label=$(echo ${line} | awk -F : '{print $1}')
        local volumn=$(echo ${line} | awk -F : '{printf("%d", (substr($2,1,index($2,".")-1)%10==0)?$2:$2+1)}')
        local rotational=$(cat /sys/block/${storage_label#/dev/}/queue/rotational)
        if [ ${rotational} -eq 0 ]; then
            local media="SDD"
        else
            local media="HDD"
        fi
        echo "storage_label: ${storage_label}" >> machine.log
        echo "volumn: ${volumn} GB" >> machine.log
        echo "media: ${media}" >> machine.log
        if [ ${counter} -gt 0 ]; then
            echo '        },' >> machine_info
        fi
        echo '        {' >> machine_info
        echo '            "volumn":' ${volumn}',' >> machine_info
        echo '            "media":' ${rotational} >> machine_info
        counter=$((counter+1))
    done
    echo '        }' >> machine_info
    echo '    ],' >> machine_info
}

function gather_memory_info () {
    echo '    "memory": [' >> machine_info
    local counter=0
    dmidecode -t memory | grep -A5 "Memory Device" | grep Size | grep -v "No Module Installed" | awk -F : '{print $2}' | while read line; do
        if [ $(echo ${line} | grep -c GB) -gt 0 ]; then
            local size=${line%GB}
        else
            local size=$(echo ${line} | awk '{printf("%d", substr($0,1,length($0)-2)/1024)}')
        fi
        echo "size: ${size} GB" >> machine.log
        if [ ${counter} -gt 0 ]; then
            echo '        },' >> machine_info
        fi
        echo '        {' >> machine_info
        echo '            "size":' ${size} >> machine_info
        counter=$((counter+1))
    done
    echo '        }' >> machine_info
    echo '    ]' >> machine_info
}

function falcon () {
    ts=$(date +%s)
    curl -X POST -d "[{\"metric\": \"CMDB\", \"endpoint\": \"$(hostname)\", \"timestamp\": ${ts},\"step\": 60,\"value\": $1,\"counterType\": \"GAUGE\",\"tags\": \"project=gaea,status=$2\"}]" http://127.0.0.1:1988/v1/push
}

function upload () {
    local updated=1
    if [ -f machine_info.bak ]; then
        diff machine_info machine_info.bak &> /dev/null
        updated=$?
    fi
    if [ ${updated} -eq 1 ]; then
        local ret_val=$(curl -s -m 180 -w %{http_code} -H "Content-Type: application/json" -X POST -d "$(cat machine_info)" "${UPLOAD_URL}" -o /dev/null)
        echo "upload return code: ${ret_val}"
        if [ ${ret_val} -eq 200 ]; then
            echo "upload successfully" >> machine.log
            falcon 0 "success"
        else
            echo "upload failed" >> machine.log
            falcon 1 "failed"
            return 1
        fi
    else
        echo "no update found" >> machine.log
        falcon 0 "uptodate"
    fi
}

function main() {
    if [ -f machine_info ]; then
        mv machine_info machine_info.bak
    fi
    echo '{' > machine_info
    echo hostname: $(hostname) >> machine.log
    echo '    "hostname":' '"'$(hostname)'",' >> machine_info
    gather_cpu_info
    gather_os_info
    gather_nic_info
    gather_storage_info
    gather_memory_info
    echo '}' >> machine_info
    upload
    if [ $? -ne 0 ]; then
        rm -f machine_info machine_info.bak
    fi
}

main
