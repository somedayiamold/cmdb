#!/bin/bash
export LANG="en_US.UTF-8"
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
    # check disk by smartmontools
    type smartctl &> /dev/null
    if [ $? -ne 0 ]; then
        yum install -y smartmontools
        if [ $? -ne 0 ]; then
            local metric_data='{"endpoint": "'${hostname}'", "metric": "sys.disk.smartmontools", "timestamp": '${timestamp}', "step": 60, "value": 1, "counterType": "GAUGE", "tags": "name=smartmontools_installed"},'
            echo ${metric_data}
            post_data=${post_data}' '${metric_data}
        fi
    else
        local metric_data='{"endpoint": "'${hostname}'", "metric": "sys.disk.smartmontools", "timestamp": '${timestamp}', "step": 60, "value": 0, "counterType": "GAUGE", "tags": "name=smartmontools_installed"},'
        echo ${metric_data}
        post_data=${post_data}' '${metric_data}
        for line in $(fdisk -l | grep -E "Disk /dev/sd" | awk '{print $2}'); do
            local storage_label=$(echo ${line} | awk -F : '{print $1}')
            local device=${storage_label#/dev/}
            local smart_data=$(smartctl -H ${storage_label} | grep -E "SMART Health Status"\|"SMART overall-health self-assessment test result")
            if [ -z "${smart_data}" ]; then
                continue
            fi
            local temperature_metric=$(smartctl -A ${storage_label} | grep -E "Airflow_Temperature_Cel"\|"Temperature_Celsius" | awk '{print "{\"endpoint\": \"""'${hostname}'""\", \"metric\": \"sys.disk.smart.temp\", \"timestamp\": ""'${timestamp}'"", \"step\": 60, \"value\": "$10", \"counterType\": \"GAUGE\", \"tags\": \"name=smart,device=""'${device}'"",temp="$2"\"},"}' | awk '{printf("%s", $0)}')
            local temperature_metric=${temperature_metric}' '$(smartctl -A ${storage_label} | grep -E "Current Drive Temperature" | awk '{print "{\"endpoint\": \"""'${hostname}'""\", \"metric\": \"sys.disk.smart.temp\", \"timestamp\": ""'${timestamp}'"", \"step\": 60, \"value\": "$4", \"counterType\": \"GAUGE\", \"tags\": \"name=smart,device=""'${device}'"",temp=Current_Drive_Temperature\"},"}' | awk '{printf("%s", $0)}')
            echo ${temperature_metric}
            post_data=${post_data}' '${temperature_metric}
            local health=$(echo ${smart_data} | awk -F : '{print $2}')
            local disk_status=$(echo ${smart_data} | grep -Evc "OK"\|"PASSED")
            local metric_data='{"endpoint": "'${hostname}'", "metric": "sys.disk.smart.health", "timestamp": '${timestamp}', "step": 60, "value": '${disk_status}', "counterType": "GAUGE", "tags": "name=smart,device='${device}'"},'
            echo ${metric_data}
            post_data=${post_data}' '${metric_data}
        done
    fi

    # check if megacli installed
    if [ -f /opt/MegaRAID/MegaCli/MegaCli64 ]; then
        local metric_data='{"endpoint": "'${hostname}'", "metric": "sys.disk.megacli", "timestamp": '${timestamp}', "step": 60, "value": 0, "counterType": "GAUGE", "tags": "name=megacli_installed"},'
        echo ${metric_data}
        post_data=${post_data}' '${metric_data}
    else
        local metric_data='{"endpoint": "'${hostname}'", "metric": "sys.disk.megacli", "timestamp": '${timestamp}', "step": 60, "value": 1, "counterType": "GAUGE", "tags": "name=megacli_installed"},'
        echo ${metric_data}
        post_data=${post_data}' '${metric_data}
        return 1
    fi
    # check disk by megacli
    /opt/MegaRAID/MegaCli/MegaCli64 -AdpBbuCmd -GetBbuStatus -aAll > megacli_bbu_info
    local ret_code=$?
    while read line && [ ${ret_code} -eq 0 ]; do
        if [ $(echo ${line} | grep -c "Adapter:") -gt 0 ]; then
            local adapter=$(echo ${line} | grep Adapter | awk '{print $5}')
        elif [ $(echo ${line} | grep -c "Temperature:") -gt 0 ]; then
            local bbu_temperature=$(echo ${line} | awk '{print $2}')
            local metric_data='{"endpoint": "'${hostname}'", "metric": "sys.disk.lsiraid.bbu.Temperature", "timestamp": '${timestamp}', "step": 60, "value": '${bbu_temperature}', "counterType": "GAUGE", "tags": "name=raid,adapter='${adapter}',module=bbu"},'
            echo ${metric_data}
            post_data=${post_data}' '${metric_data}
        elif [ $(echo ${line} | grep -c "Battery State") -gt 0 ]; then
            local battery_state=$(echo ${line} | grep -vc "Optimal")
            local metric_data='{"endpoint": "'${hostname}'", "metric": "sys.disk.lsiraid.bbu.Battery_State", "timestamp": '${timestamp}', "step": 60, "value": '${battery_state}', "counterType": "GAUGE", "tags": "name=raid,adapter='${adapter}',module=bbu"},'
            echo ${metric_data}
            post_data=${post_data}' '${metric_data}
        elif [ $(echo ${line} | grep -v "Voltage:" | grep -c "Voltage") -gt 0 ]; then
            local voltage_status=$(echo ${line} | grep -vc "OK")
            local metric_data='{"endpoint": "'${hostname}'", "metric": "sys.disk.lsiraid.bbu.Voltage_Status", "timestamp": '${timestamp}', "step": 60, "value": '${voltage_status}', "counterType": "GAUGE", "tags": "name=raid,adapter='${adapter}',module=bbu"},'
            echo ${metric_data}
            post_data=${post_data}' '${metric_data}
        elif [ $(echo ${line} | grep -v "Temperature:" | grep -c "Temperature") -gt 0 ]; then
            local temperature_status=$(echo ${line} | grep -vc "OK")
            local metric_data='{"endpoint": "'${hostname}'", "metric": "sys.disk.lsiraid.bbu.Temprature_Status", "timestamp": '${timestamp}', "step": 60, "value": '${temperature_status}', "counterType": "GAUGE", "tags": "name=raid,adapter='${adapter}',module=bbu"},'
            echo ${metric_data}
            post_data=${post_data}' '${metric_data}
        elif [ $(echo ${line} | grep -c "Learn Cycle Status") -gt 0 ]; then
            local learn_cycle_status=$(echo ${line} | grep -vc "OK")
            local metric_data='{"endpoint": "'${hostname}'", "metric": "sys.disk.lsiraid.bbu.Learn_Cycle_Status", "timestamp": '${timestamp}', "step": 60, "value": '${learn_cycle_status}', "counterType": "GAUGE", "tags": "name=raid,adapter='${adapter}',module=bbu"},'
            echo ${metric_data}
            post_data=${post_data}' '${metric_data}
        elif [ $(echo ${line} | grep -c "Battery Replacement required") -gt 0 ]; then
            local battery_replacement_required=$(echo ${line} | grep -c "Yes")
            local metric_data='{"endpoint": "'${hostname}'", "metric": "sys.disk.lsiraid.bbu.Battery_Replacement_Required", "timestamp": '${timestamp}', "step": 60, "value": '${battery_replacement_required}', "counterType": "GAUGE", "tags": "name=raid,adapter='${adapter}',module=bbu"},'
            echo ${metric_data}
            post_data=${post_data}' '${metric_data}
        elif [ $(echo ${line} | grep -c "Remaining Capacity Low") -gt 0 ]; then
            local remaining_capacity_low=$(echo ${line} | grep -c "Yes")
            local metric_data='{"endpoint": "'${hostname}'", "metric": "sys.disk.lsiraid.bbu.Remaining_Capacity_Low", "timestamp": '${timestamp}', "step": 60, "value": '${remaining_capacity_low}', "counterType": "GAUGE", "tags": "name=raid,adapter='${adapter}',module=bbu"},'
            echo ${metric_data}
            post_data=${post_data}' '${metric_data}
         elif [ $(echo ${line} | grep -c "Relative State of Charge") -gt 0 ]; then
            local relative_state_of_charge=$(echo ${line} | awk '{print $5}')
            local metric_data='{"endpoint": "'${hostname}'", "metric": "sys.disk.lsiraid.bbu.Relative_State_Of_Charge", "timestamp": '${timestamp}', "step": 60, "value": '${relative_state_of_charge}', "counterType": "GAUGE", "tags": "name=raid,adapter='${adapter}',module=bbu"},'
            echo ${metric_data}
            post_data=${post_data}' '${metric_data}
        elif [ $(echo ${line} | grep -c "isSOHGood") -gt 0 ]; then
            local is_soh_good=$(echo ${line} | grep -vc 'Yes')
            local metric_data='{"endpoint": "'${hostname}'", "metric": "sys.disk.lsiraid.bbu.IsSOHGood", "timestamp": '${timestamp}', "step": 60, "value": '${is_soh_good}', "counterType": "GAUGE", "tags": "name=raid,adapter='${adapter}',module=bbu"},'
            echo ${metric_data}
            post_data=${post_data}' '${metric_data}
        else
            continue
        fi
    done < megacli_bbu_info

    /opt/MegaRAID/MegaCli/MegaCli64 -PDList -aALL > megacli_pd_info
    while read line; do
        #echo ${line}
        if [ $(echo ${line} | grep -c "Adapter") -gt 0 ]; then
            local adapter=$(echo ${line} | grep Adapter | awk '{print substr($2,index($2,"#")+1)}')
        elif [ $(echo ${line} | grep -c "Enclosure Device ID") -gt 0 ]; then
            local enclosure_id=$(echo ${line} | awk '{print $NF}')
        elif [ $(echo ${line} | grep -c "Slot Number") -gt 0 ]; then
            local slot_num=$(echo ${line} | awk '{print $NF}')
        elif [ $(echo ${line} | grep -c "Media Error Count") -gt 0 ]; then
            local meida_error_count=$(echo ${line} | awk -F : '{print $NF}')
            local metric_data='{"endpoint": "'${hostname}'", "metric": "sys.disk.lsiraid.pd.Media_Error_Count", "timestamp": '${timestamp}', "step": 60, "value": '${meida_error_count}', "counterType": "GAUGE", "tags": "name=raid,adapter='${adapter}',PD='${enclosure_id}:${slot_num}'"},'
            echo ${metric_data}
            post_data=${post_data}' '${metric_data}
        elif [ $(echo ${line} | grep -c "Other Error Count") -gt 0 ]; then
            local other_error_count=$(echo ${line} | awk -F : '{print $NF}')
            local metric_data='{"endpoint": "'${hostname}'", "metric": "sys.disk.lsiraid.pd.Other_Error_Count", "timestamp": '${timestamp}', "step": 60, "value": '${other_error_count}', "counterType": "GAUGE", "tags": "name=raid,adapter='${adapter}',PD='${enclosure_id}:${slot_num}'"},'
            echo ${metric_data}
            post_data=${post_data}' '${metric_data}
        elif [ $(echo ${line} | grep -c "Predictive Failure Count") -gt 0 ]; then
            local predictive_failure_count=$(echo ${line} | awk -F : '{print $NF}')
            local metric_data=${metric_data}' {"endpoint": "'${hostname}'", "metric": "sys.disk.lsiraid.pd.Predictive_Failure_Count", "timestamp": '${timestamp}', "step": 60, "value": '${predictive_failure_count}', "counterType": "GAUGE", "tags": "name=raid,adapter='${adapter}',PD='${enclosure_id}:${slot_num}'"},'
            echo ${metric_data}
            post_data=${post_data}' '${metric_data}
        elif [ $(echo ${line} | grep -c "Firmware state") -gt 0 ]; then
            if [ $(echo ${line} | grep -Ec "Online"\|"JBOD") -gt 0 ]; then
                local firmware_state=0
            elif [ $(echo ${line} | grep -Eic "Unconfigured\(bad\)"\|"Failed") -gt 0 ]; then
                local firmware_state=1
            elif [ $(echo ${line} | grep -c "Unconfigured(good)") -gt 0 ]; then
                local firmware_state=2
            elif [ $(echo ${line} | grep -c "Rebuilding") -gt 0 ]; then
                local firmware_state=3
            else
                local firmware_state=4
            fi
            local metric_data='{"endpoint": "'${hostname}'", "metric": "sys.disk.lsiraid.pd.Firmware_State", "timestamp": '${timestamp}', "step": 60, "value": '${firmware_state}', "counterType": "GAUGE", "tags": "name=raid,adapter='${adapter}',PD='${enclosure_id}:${slot_num}'"},'
            echo ${metric_data}
            post_data=${post_data}' '${metric_data}
        elif [ $(echo ${line} | grep -c "Media Type") -gt 0 ]; then
            local media_type=$(echo ${line} | awk -F : '{print $2}')
        elif [ $(echo ${line} | grep -c "Drive Temperature") -gt 0 ]; then
            if [ "${media_type}" = " Solid State Device" ]; then
                continue
            fi
            local drive_temperature=$(echo ${line} | awk -F : '{print $NF}' | awk '{print substr($1,1,length($1)-1)}')
            local metric_data='{"endpoint": "'${hostname}'", "metric": "sys.disk.lsiraid.pd.Drive_Temperature", "timestamp": '${timestamp}', "step": 60, "value": '${drive_temperature}', "counterType": "GAUGE", "tags": "name=raid,adapter='${adapter}',PD='${enclosure_id}:${slot_num}'"},'
            echo ${metric_data}
            post_data=${post_data}' '${metric_data}
        else
            continue
        fi
    done < megacli_pd_info

    /opt/MegaRAID/MegaCli/MegaCli64 -LDInfo -Lall -aALL > megacli_ld_info
    while read line; do
        #echo ${line}
        if [ $(echo ${line} | grep -c "Adapter") -gt 0 ]; then
            local adapter=$(echo ${line} | grep Adapter | awk '{print $2}')
        elif [ $(echo ${line} | grep -c "Virtual Drive") -gt 0 ]; then
            local virtual_drive_id=$(echo ${line} | awk '{print $3}')
        elif [ $(echo ${line} | grep -c "State") -gt 0 ]; then
            local state=$(echo ${line} | grep -vc "Optimal")
            local metric_data='{"endpoint": "'${hostname}'", "metric": "sys.disk.lsiraid.vd.state", "timestamp": '${timestamp}', "step": 60, "value": '${state}', "counterType": "GAUGE", "tags": "name=raid,adapter='${adapter}',VD='${virtual_drive_id}'"},'
            echo ${metric_data}
            post_data=${post_data}' '${metric_data}
        elif [ $(echo ${line} | grep -c "Default Cache Policy") -gt 0 ]; then
            local default_cache_policy=$(echo ${line} | awk -F : '{print $2}')
        elif [ $(echo ${line} | grep -c "Current Cache Policy") -gt 0 ]; then
            local current_cache_policy=$(echo ${line} | awk -F : '{print $2}')
            if [ "${default_cache_policy}" = "${current_cache_policy}" ]; then
                local cache_policy=0
            else
                local cache_policy=1
            fi
            local metric_data='{"endpoint": "'${hostname}'", "metric": "sys.disk.lsiraid.vd.cache_policy", "timestamp": '${timestamp}', "step": 60, "value": '${cache_policy}', "counterType": "GAUGE", "tags": "name=raid,adapter='${adapter}',VD='${virtual_drive_id}'"},'
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
    # chekc if ipmitool installed
    type ipmitool &> /dev/null
    if [ $? -ne 0 ]; then
        yum install -y OpenIPMI ipmitool
        if [ $? -ne 0 ]; then
            local metric_data='{"endpoint": "'${hostname}'", "metric": "sys.ipmitool.status", "timestamp": '${timestamp}', "step": 60, "value": 1, "counterType": "GAUGE", "tags": "name=ipmitool_installed"},'
            echo ${metric_data}
            post_data=${post_data}' '${metric_data}
            return 1
        fi
    else
        local metric_data='{"endpoint": "'${hostname}'", "metric": "sys.ipmitool.status", "timestamp": '${timestamp}', "step": 60, "value": 0, "counterType": "GAUGE", "tags": "name=ipmitool_installed"},'
        echo ${metric_data}
        post_data=${post_data}' '${metric_data}
    fi
    # chekc if ipmi service started
    ipmitool sdr > ipmitool_sensor_info
    local ret_code=$?
    if [ ${ret_code} -ne 0 ]; then
        /etc/init.d/ipmi start
        local ret_code=$?
        if [ ${ret_code} -ne 0 ]; then
            local metric_data='{"endpoint": "'${hostname}'", "metric": "sys.ipmi.status", "timestamp": '${timestamp}', "step": 60, "value": 1, "counterType": "GAUGE", "tags": "name=ipmi_running"},'
            echo ${metric_data}
            post_data=${post_data}' '${metric_data}
            return ${ret_code}
        else
            ipmitool sdr > ipmitool_sensor_info
        fi
    else
        local metric_data='{"endpoint": "'${hostname}'", "metric": "sys.ipmi.status", "timestamp": '${timestamp}', "step": 60, "value": 0, "counterType": "GAUGE", "tags": "name=ipmi_running"},'
        echo ${metric_data}
        post_data=${post_data}' '${metric_data}
    fi

    ipmitool -v sdr | grep -E "Sensor ID"\|"Entity ID" > ipmitool_sensor_entity_info

    local line_num=0
    while read line; do
        line_num=$((line_num+1))
        local sensor=$(echo ${line} | awk -F \| '{print $1}' | awk 'sub(/[ \t\r\n]+$/, "", $0)' | tr ' ''/' '_')
        local status=$(echo ${line} | awk '{print $NF}')
        local entity_line_num=$((line_num*2))
        local entity_id=$(sed -n "${entity_line_num}p" ipmitool_sensor_entity_info | awk '{print $4}')
        local entity_name=$(sed -n "${entity_line_num}p" ipmitool_sensor_entity_info | awk -F: '{print substr($2, index($2, "(")+1, index($2, ")")-index($2, "(")-1)}' | tr ' ' '_')
        if [ $(echo ${line} | grep -c "Fan") -gt 0 ]; then
            local fan_status=$(get_value "${status}")
            local metric_data='{"endpoint": "'${hostname}'", "metric": "sys.ipmi.sensor.status", "timestamp": '${timestamp}', "step": 60, "value": '${fan_status}', "counterType": "GAUGE", "tags": "sensor=Fan,name='${sensor}',id='${entity_id}',entity='${entity_name}'"},'
            echo ${metric_data}
            post_data=${post_data}' '${metric_data}
        elif [ $(echo ${line} | grep -Ec "CPU"\|"P[0-9]+ Status") -gt 0 ]; then
            local cpu_status=$(get_value "${status}")
            local metric_data='{"endpoint": "'${hostname}'", "metric": "sys.ipmi.sensor.status", "timestamp": '${timestamp}', "step": 60, "value": '${cpu_status}', "counterType": "GAUGE", "tags": "sensor=CPU,name='${sensor}',id='${entity_id}',entity='${entity_name}'"},'
            echo ${metric_data}
            post_data=${post_data}' '${metric_data}
        elif [ $(echo ${line} | grep -c "Temp") -gt 0 ]; then
            local temp=$(echo ${line} | awk -F \| '{print $2}' | awk '{print $1}')
            if [ $(echo ${temp} | grep -Ec ^[0-9]+$) -gt 0 ]; then
                local metric_data='{"endpoint": "'${hostname}'", "metric": "sys.ipmi.sensor.temp", "timestamp": '${timestamp}', "step": 60, "value": '${temp}', "counterType": "GAUGE", "tags": "name='${sensor}',id='${entity_id}',entity='${entity_name}'"},'
                echo ${metric_data}
                post_data=${post_data}' '${metric_data}
                local metric_data='{"endpoint": "'${hostname}'", "metric": "sys.ipmi.sensor.Value_Error", "timestamp": '${timestamp}', "step": 60, "value": 0, "counterType": "GAUGE", "tags": "sensor=Temp,name='${sensor}',id='${entity_id}',entity='${entity_name}'"},'
                echo ${metric_data}
                post_data=${post_data}' '${metric_data}
            else
                if [ $(echo ${temp} | grep -c "disabled") -gt 0 ]; then
                    continue
                fi
                local metric_data='{"endpoint": "'${hostname}'", "metric": "sys.ipmi.sensor.Value_Error", "timestamp": '${timestamp}', "step": 60, "value": 1, "counterType": "GAUGE", "tags": "sensor=Temp,name='${sensor}',id='${entity_id}',entity='${entity_name}'"},'
                echo ${metric_data}
                post_data=${post_data}' '${metric_data}
            fi
            local temp_sensor_status=$(get_value "${status}")
            local metric_data='{"endpoint": "'${hostname}'", "metric": "sys.ipmi.sensor.status", "timestamp": '${timestamp}', "step": 60, "value": '${temp_sensor_status}', "counterType": "GAUGE", "tags": "sensor=Temp,name='${sensor}',id='${entity_id}',entity='${entity_name}'"},'
            echo ${metric_data}
            post_data=${post_data}' '${metric_data}
        elif [ $(echo ${line} | grep -Ec "Mem"\|"DIMM") -gt 0 ]; then
            local memory_status=$(get_value "${status}")
            local metric_data='{"endpoint": "'${hostname}'", "metric": "sys.ipmi.sensor.status", "timestamp": '${timestamp}', "step": 60, "value": '${memory_status}', "counterType": "GAUGE", "tags": "sensor=Mem,name='${sensor}',id='${entity_id}',entity='${entity_name}'"},'
            echo ${metric_data}
            post_data=${post_data}' '${metric_data}
        else
            local other_sensor_status=$(get_value "${status}")
            if [ ${other_sensor_status} -ne 0 ]; then
                local metric_data='{"endpoint": "'${hostname}'", "metric": "sys.ipmi.sensor.status", "timestamp": '${timestamp}', "step": 60, "value": '${other_sensor_status}', "counterType": "GAUGE", "tags": "sensor=Others,name='${sensor}',id='${entity_id}',entity='${entity_name}'"},'
                echo ${metric_data}
                post_data=${post_data}' '${metric_data}
            fi
        fi
    done < ipmitool_sensor_info
}

function main() {
    >MegaSAS.log
    disk_check
    sensor_check
    post_data=${post_data%,}
    post_data='['${post_data}']'
    echo ${post_data}
    push_to_falcon "${post_data}"
    return $?
}

main