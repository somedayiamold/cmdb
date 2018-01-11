#!/bin/bash
current_dir=$(dirname $0)
cd ${current_dir} || exit 1
sh -x host_info_collection.sh &> host_info_collection.log
if [ $? -eq 0 ]; then
   value=0
else
   value=1
fi
echo   '[{"endpoint": "'$(hostname)'", "tags": "project=gaea", "timestamp": '$(date +%s)', "metric": "CMDB", "value": '${value}', "counterType": "GAUGE", "step": 600}]'
