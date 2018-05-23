#!/bin/bash
current_dir=$(dirname $0)
cd ${current_dir} || exit 1
hostname=$(hostname)
timestamp=$(date +%s)
post_data=""

function push_to_falcon() {
    local ret_code=$(curl -s -m 180 -w %{http_code} -X POST -d "$1" http://127.0.0.1:1988/v1/push -o /dev/null)
    if [ ${ret_code} -eq 200 ]; then
        echo "push to falcon successfully"
        return 0
    else
        echo "push to falcon failed"
        return 1
    fi
}

function disk_check() {
    /opt/MegaRAID/MegaCli/MegaCli64 -PDList -aALL > megacli_pd_info
    while read line; do
        #echo ${line}
        if [ $(echo ${line} | grep -c "Enclosure Device ID") -gt 0 ]; then
            local enclosure_id=$(echo ${line} | awk '{print $NF}')
        elif [ $(echo ${line} | grep -c "Slot Number") -gt 0 ]; then
            local slot_num=$(echo ${line} | awk '{print $NF}')
        elif [ $(echo ${line} | grep -c "Media Error Count") -gt 0 ]; then
            local meida_error_count=$(echo ${line} | awk -F : '{print $NF}')
            local metric_data='{"endpoint": "'${hostname}'", "metric": "sys.disk.lsiraid.pd.Media_Error_Count", "timestamp": '${timestamp}', "step": 60, "value": '${meida_error_count}', "counterType": "GAUGE", "tags": "name=storage,PD='${enclosure_id}:${slot_num}'"},'
            echo ${metric_data}
            post_data=${metric_data} 
        elif [ $(echo ${line} | grep -c "Other Error Count") -gt 0 ]; then
            local other_error_count=$(echo ${line} | awk -F : '{print $NF}')
            local metric_data='{"endpoint": "'${hostname}'", "metric": "sys.disk.lsiraid.pd.Other_Error_Count", "timestamp": '${timestamp}', "step": 60, "value": '${other_error_count}', "counterType": "GAUGE", "tags": "name=storage,PD='${enclosure_id}:${slot_num}'"},'
            echo ${metric_data}
            post_data=${post_data}' '${metric_data} 
        elif [ $(echo ${line} | grep -c "Predictive Failure Count") -gt 0 ]; then
            local predictive_failure_count=$(echo ${line} | awk -F : '{print $NF}')
            local metric_data=${metric_data}' {"endpoint": "'${hostname}'", "metric": "sys.disk.lsiraid.pd.Predictive_Failure_Count", "timestamp": '${timestamp}', "step": 60, "value": '${predictive_failure_count}', "counterType": "GAUGE", "tags": "name=storage,PD='${enclosure_id}:${slot_num}'"},'
            echo ${metric_data}
            post_data=${post_data}' '${metric_data} 
        elif [ $(echo ${line} | grep -c "Firmware state") -gt 0 ]; then
            local firmware_state=$(echo ${line} | grep -vc "Online")
            local metric_data='{"endpoint": "'${hostname}'", "metric": "sys.disk.lsiraid.pd.Firmware_state", "timestamp": '${timestamp}', "step": 60, "value": '${firmware_state}', "counterType": "GAUGE", "tags": "name=storage,PD='${enclosure_id}:${slot_num}'"},'
            echo ${metric_data}
            post_data=${post_data}' '${metric_data} 
        elif [ $(echo ${line} | grep -c "Drive Temperature") -gt 0 ]; then
            local drive_temperature=$(echo ${line} | awk -F : '{print $NF}' | awk '{print substr($1,1,length($1)-1)}')
            local metric_data='{"endpoint": "'${hostname}'", "metric": "sys.disk.lsiraid.pd.Drive_Temperature", "timestamp": '${timestamp}', "step": 60, "value": '${drive_temperature}', "counterType": "GAUGE", "tags": "name=storage,PD='${enclosure_id}:${slot_num}'"},'
            echo ${metric_data}
            post_data=${post_data}' '${metric_data} 
        else
            continue
        fi
    done < megacli_pd_info
    /opt/MegaRAID/MegaCli/MegaCli64 -LDInfo -Lall -aALL > megacli_ld_info
    while read line; do
        #echo ${line}
        if [ $(echo ${line} | grep -c "Virtual Drive") -gt 0 ]; then
            local virtual_drive_id=$(echo ${line} | awk '{print $3}')
        elif [ $(echo ${line} | grep -c "State") -gt 0 ]; then
            local state=$(echo ${line} | grep -vc "Optimal")
            local metric_data='{"endpoint": "'${hostname}'", "metric": "sys.disk.lsiraid.vd.state", "timestamp": '${timestamp}', "step": 60, "value": '${state}', "counterType": "GAUGE", "tags": "name=storage,VD='${virtual_drive_id}'"},'
            echo ${metric_data}
            post_data=${post_data}' '${metric_data} 
        elif [ $(echo ${line} | grep -c "Disk Cache Policy") -gt 0 ]; then
            local cache_policy=$(echo ${line} | grep -vc "Disk's Default")
            local metric_data='{"endpoint": "'${hostname}'", "metric": "sys.disk.lsiraid.vd.cache_policy", "timestamp": '${timestamp}', "step": 60, "value": '${cache_policy}', "counterType": "GAUGE", "tags": "name=storage,VD='${virtual_drive_id}'"},'
            echo ${metric_data}
            post_data=${post_data}' '${metric_data} 
        else
            continue
        fi
    done < megacli_ld_info
}

# map status of sensor to value 
# 0: OK, 1: Warning, 2: Critical, 3: Unknown
function get_value() {
    local status="$1"
    if [ "${status}" = "ok" ] || [ "${status}" = 'ns' ] || [ "${status}" = 'ready' ]; then
        echo 0
    elif [ "${status}" = "warn" ] || [ "${status}" = 'warning' ] || [ "${status}" = 'non-critical' ]; then
        echo 1
    elif [ "${status}" = "crit" ] || [ "${status}" = 'critical' ]; then
        echo 2
    else 
        echo 3
    fi
}

# get sensor state by ipmitool
function sensor_check() {
    ipmitool sdr > ipmitool_sensor_info
    while read line; do
        local sensor=$(echo ${line} | awk -F \| '{print $1}' | awk 'sub(/[ \t\r\n]+$/, "", $0)' | tr ' ''/' '_')
        local status=$(echo ${line} | awk '{print $NF}')
        if [ $(echo ${line} | grep -c "Fan") -gt 0 ]; then
            local fan_status=$(get_value "${status}")
            local metric_data='{"endpoint": "'${hostname}'", "metric": "sys.ipmi.sensor.status", "timestamp": '${timestamp}', "step": 60, "value": '${fan_error}', "counterType": "GAUGE", "tags": "sensor=Fan,name='${sensor}'"},'
            echo ${metric_data}
            post_data=${post_data}' '${metric_data}
        elif [ $(echo ${line} | grep -Ec "CPU"\|"P* Status") -gt 0 ]; then
            local cpu_status=$(get_value "${status}")
            local metric_data='{"endpoint": "'${hostname}'", "metric": "sys.ipmi.sensor.status", "timestamp": '${timestamp}', "step": 60, "value": '${cpu_status}', "counterType": "GAUGE", "tags": "sensor=CPU,name='${sensor}'"},'
            echo ${metric_data}
            post_data=${post_data}' '${metric_data}
        elif [ $(echo ${line} | grep -c "Temp") -gt 0 ]; then
            local temp=$(echo ${line} | awk -F \| '{print $2}' | awk '{print $1}')
            local metric_data='{"endpoint": "'${hostname}'", "metric": "sys.ipmi.sensor.temp", "timestamp": '${timestamp}', "step": 60, "value": '${temp}', "counterType": "GAUGE", "tags": "name='${sensor}'"},'
            echo ${metric_data}
            post_data=${post_data}' '${metric_data}
            local temp_sensor_status=$(get_value "${status}")
            if [ ${temp_sensor_status} -ne 0 ]; then
                local metric_data='{"endpoint": "'${hostname}'", "metric": "sys.ipmi.sensor.status", "timestamp": '${timestamp}', "step": 60, "value": '${temp_sensor_status}', "counterType": "GAUGE", "tags": "sensor=temp_sensor,name='${sensor}'"},'
                echo ${metric_data}
                post_data=${post_data}' '${metric_data} 
            fi
        elif [ $(echo ${line} | grep -Ec "Mem"\|"DIMM") -gt 0 ]; then
            local memory_status=$(get_value "${status}")
            local metric_data='{"endpoint": "'${hostname}'", "metric": "sys.ipmi.sensor.status", "timestamp": '${timestamp}', "step": 60, "value": '${memory_status}', "counterType": "GAUGE", "tags": "sensor=Mem,name='${sensor}'"}'
            echo ${metric_data}
            post_data=${post_data}' '${metric_data}
        else
            local other_sensor=$(get_value "${status}")
            if [ ${other_sensor} -ne 0 ]; then
                local metric_data='{"endpoint": "'${hostname}'", "metric": "sys.ipmi.sensor.status", "timestamp": '${timestamp}', "step": 60, "value": '${other_sensor}', "counterType": "GAUGE", "tags": "sensor=other_sensor,name='${sensor}'"},'
                echo ${metric_data}
                post_data=${post_data}' '${metric_data} 
            fi
        fi
    done < ipmitool_sensor_info
}

function main() {
    disk_check
    sensor_check
    post_data='['${post_data}']'
    echo ${post_data}
    push_to_falcon "${post_data}"
    return $?
}

main
