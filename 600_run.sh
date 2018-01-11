#!/bin/bash
current_dir=$(dirname $0)
cd ${current_dir} || exit 1

function falcon () {
    ts=$(date +%s)
    curl -X POST -d "[{\"metric\": \"CMDB\", \"endpoint\": \"$(hostname)\", \"timestamp\": ${ts},\"step\": 60,\"value\": $1,\"counterType\": \"GAUGE\",\"tags\": \"project=gaea\"}]" http://127.0.0.1:1988/v1/push
}

sh -x host_info_collection.sh &> host_info_collection.log
if [ $? -eq 0 ]; then
    falcon 0
else
    falcon 1 
fi
