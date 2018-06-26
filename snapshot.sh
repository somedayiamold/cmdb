#!/bin/bash
export LANG="en_US.UTF-8"
current_dir=$(dirname $0)
cd ${current_dir} || exit 1
hostname=$(hostname)
timestamp=$(date +%s)
post_data=""
trap   'cleanup'  1 2 3 15

function cleanup() {
    rm -f top.lock iotop.lock cpustat.* diskstats.*
    jobs -p | xargs kill -9
    exit
}
function write_history() {
    local history_file=${1}
    local value=${2}
    local latest=""
    if [ ! -f ${history_file} ]; then
        >${history_file}
    else
        latest="$(tail -2 ${history_file}) ${value}"
        >${history_file}
    fi
    for value in ${latest}; do
        echo "${value}" >> ${history_file}
    done
}

function check_io_await() {
    if [ -f diskstats.new ]; then
        mv diskstats.new diskstats.old
    fi
    cat /proc/diskstats > diskstats.new
    if [ -f diskstats.old ] && [ -f diskstats.new ]; then
        date "+%x %T"
        fdisk -l | grep -E "Disk /dev/sd"\|"Disk /dev/vd" | awk '{print substr($2,6,index($2,":")-6)}'  | while read dev; do
            echo "${dev}: "
            local read_request_old=$(awk '{if ($3=="'${dev}'") print $4}' diskstats.old)
            local read_sectors_old=$(awk '{if ($3=="'${dev}'") print $6}' diskstats.old)
            local msec_read_old=$(awk '{if ($3=="'${dev}'") print $7}' diskstats.old)
            local write_request_old=$(awk '{if ($3=="'${dev}'") print $8}' diskstats.old)
            local read_request_new=$(awk '{if ($3=="'${dev}'") print $4}' diskstats.new)
            local read_sectors_new=$(awk '{if ($3=="'${dev}'") print $6}' diskstats.new)
            local msec_read_new=$(awk '{if ($3=="'${dev}'") print $7}' diskstats.new)
            local write_request_new=$(awk '{if ($3=="'${dev}'") print $8}' diskstats.new)
            local write_sectors_old=$(awk '{if ($3=="'${dev}'") print $10}' diskstats.old)
            local msec_write_old=$(awk '{if ($3=="'${dev}'") print $11}' diskstats.old)
            local write_sectors_new=$(awk '{if ($3=="'${dev}'") print $10}' diskstats.new)
            local msec_write_new=$(awk '{if ($3=="'${dev}'") print $11}' diskstats.new)
            local n_io=$((read_request_new-read_request_old+write_request_new-write_request_old))
            local use=$((msec_read_new-msec_read_old+msec_write_new-msec_write_old))
            local read_bytes=$(((read_sectors_new-read_sectors_old)*512))
            local write_bytes=$(((write_sectors_new-write_sectors_old)*512))
            local io_await=0
            if [ ${n_io} -ne 0 ]; then
                io_await=$(echo "scale=2;${use}/${n_io}" | bc)
            fi
            write_history read_bytes_history ${read_bytes}
            write_history write_bytes_history ${write_bytes}
            write_history io_await_history ${io_await}
            echo "read_bytes: ${read_bytes}"
            echo "write_bytes: ${write_bytes}"
            echo "io.await: ${io_await}"
            if [ $(awk 'BEGIN{count=0}{if ($0 > 1800000000) count+=1}END{print count}' write_bytes_history) -eq 3 ] || [ $(awk 'BEGIN{count=0}{if ($0 > 200) count+=1}END{print count}' io_await_history) -eq 3 ]; then
                dump_io_top
            fi
        done
    fi
}

function check_cpu_idle() {
    if [ -f cpustat.new ]; then
        mv cpustat.new cpustat.old
    fi
    cat /proc/stat > cpustat.new
    if [ -f cpustat.old ] && [ -f cpustat.new ]; then
        local total_old=$(cat cpustat.old | head -1 | awk '{print $2+$3+$4+$5+$6+$7+$8+$9+$10+$11}')
        local total_new=$(cat cpustat.new | head -1 | awk '{print $2+$3+$4+$5+$6+$7+$8+$9+$10+$11}')
        local idle_old=$(cat cpustat.old | head -1 | awk '{print $5}')
        local idle_new=$(cat cpustat.new | head -1 | awk '{print $5}')
        local cpu_idle=$(echo "scale=2;(${idle_new}-${idle_old})/(${total_new}-${total_old})" | bc)
        write_history cpu_idle_history ${cpu_idle}
        echo "cpu idle: ${cpu_idle}"
        if [ $(awk 'BEGIN{count=0}{if ($0 < 0.2) count+=1}END{print count}' cpu_idle_history) -eq 3 ]; then
            dump_top
        fi
    fi
}

function check_load_avg() {
    local load_avg=$(cat /proc/loadavg  | awk '{print $1}')
    write_history load_avg_history ${load_avg}
    echo "load_avg: ${load_avg}"
    if [ $(awk 'BEGIN{count=0}{if ($0 >= 16) count+=1}END{print count}' load_avg_history) -eq 3 ]; then
        dump_top
    fi
}

function dump_top() {
    echo "dump top"
    local counter=0
    while [ -f top.lock ] && [ ${counter} -lt 5 ]; do
        counter=$((counter+1))
        sleep 1
    done
    if [ -f top.lock ]; then
        echo "unable to get top.lock"
        return 1
    else
        touch top.lock
        top -b -n 1 >> top.$(date '+%Y%m%d')
        rm -f top.lock
    fi
}

function dump_io_top() {
    echo "dump io top"
    local counter=0
    while [ -f iotop.lock ] && [ ${counter} -lt 5 ]; do
        counter=$((counter+1))
        sleep 1
    done
    if [ -f iotop.lock ]; then
        echo "unable to get iotop.lock"
        return 1
    else
        touch iotop.lock
        iotop -b -t -k -n 1 >> iotop.$(date '+%Y%m%d')
        rm -f iotop.lock
    fi
}


function schedule() {
    type bc &> /dev/null
    if [ $? -ne 0 ]; then
        yum install -y bc
        if [ $? -ne 0 ]; then
            local metric_data='{"endpoint": "'${hostname}'", "metric": "load.snapshot", "timestamp": '${timestamp}', "step": 60, "value": 1, "counterType": "GAUGE", "tags": "name=bc_installed"},'
            echo ${metric_data}
            post_data=${post_data}' '${metric_data}
        fi
    else
        local metric_data='{"endpoint": "'${hostname}'", "metric": "load.snapshot", "timestamp": '${timestamp}', "step": 60, "value": 0, "counterType": "GAUGE", "tags": "name=bc_installed"},'
        echo ${metric_data}
        post_data=${post_data}' '${metric_data}
    fi
    type iotop &> /dev/null
    if [ $? -ne 0 ]; then
        yum install -y iotop
        if [ $? -ne 0 ]; then
            local metric_data='{"endpoint": "'${hostname}'", "metric": "load.snapshot", "timestamp": '${timestamp}', "step": 60, "value": 1, "counterType": "GAUGE", "tags": "name=iotop_installed"},'
            echo ${metric_data}
            post_data=${post_data}' '${metric_data}
        fi
    else
        local metric_data='{"endpoint": "'${hostname}'", "metric": "load.snapshot", "timestamp": '${timestamp}', "step": 60, "value": 0, "counterType": "GAUGE", "tags": "name=iotop_installed"},'
        echo ${metric_data}
        post_data=${post_data}' '${metric_data}
        check_io_await &
        check_cpu_idle &
        check_load_avg &
        wait
    fi
}

function push_to_falcon() {
    if [ -z "$1" ]; then
        return 0
    fi
    local ret_code=$(curl -s -m 180 -w %{http_code} -X POST -d "$1" http://127.0.0.1:1988/v1/push -o /dev/null)
    if [ ${ret_code} -eq 200 ]; then
        echo "push to falcon successfully"
        return 0
    else
        echo "push to falcon failed"
        return 1
    fi
}

function purge() {
    find . -name 'top.*' -ctime +7 -exec rm -f {} \;
    find . -name 'iotop.*' -ctime +7 -exec rm -f {} \;
}

function main() {
    schedule
    purge
    post_data=${post_data%,}
    post_data='['${post_data}']'
    echo ${post_data}
    push_to_falcon "${post_data}"
    return $?
}

main